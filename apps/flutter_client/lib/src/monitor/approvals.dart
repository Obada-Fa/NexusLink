// Approvals for Claude sessions started outside NexusLink (host `approvals.*`, see
// packages/rpc-types/src/approvals.ts). The host only relays: with no answer from the
// phone, Claude shows its normal prompt on the PC.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';

class ExternalApproval {
  ExternalApproval(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get chatId => json['chatId'] as String? ?? '';

  /// approval | question | plan
  String get kind => json['kind'] as String? ?? 'approval';
  String get title => json['title'] as String? ?? 'Approve the next step';
  String? get detail => json['detail'] as String?;
  String? get subagent => json['subagent'] as String?;

  /// The PC shows the same prompt; whichever side answers first wins.
  bool get mirrored => json['mirrored'] == true;
  List<ApprovalQuestion> get questions => [
    for (final q in (json['questions'] as List? ?? const []))
      if (q is Map && q['question'] is String)
        ApprovalQuestion(Map<String, dynamic>.from(q)),
  ];
}

class ApprovalQuestion {
  ApprovalQuestion(this.json);
  final Map<String, dynamic> json;
  String get question => json['question'] as String;
  String? get header => json['header'] as String?;
  bool get multiSelect => json['multiSelect'] == true;
  List<({String label, String? description})> get options => [
    for (final o in (json['options'] as List? ?? const []))
      if (o is Map && o['label'] is String)
        (label: o['label'] as String, description: o['description'] as String?),
  ];
}

class ApprovalsState {
  const ApprovalsState({this.items = const [], this.status});
  final List<ExternalApproval> items;

  /// Host `ApprovalBridgeStatus`; null until fetched or on hosts without approvals.v1.
  final Map<String, dynamic>? status;
  List<ExternalApproval> forChat(String chatId) =>
      items.where((a) => a.chatId == chatId).toList();
  Set<String> get chatIds => {for (final a in items) a.chatId};
}

bool hostSupportsApprovals(RpcClient? client) =>
    client?.supports('approvals.v1') == true;

class ApprovalsNotifier extends Notifier<ApprovalsState> {
  RpcClient? _client;

  @override
  ApprovalsState build() {
    final client = ref.watch(activeClientProvider);
    final connected =
        ref.watch(connectionStatusProvider) == RpcStatus.connected;
    _client = client;
    if (client == null || !connected || !hostSupportsApprovals(client)) {
      return const ApprovalsState();
    }
    final unsub = client.subscribe('approvals-changed', (msg) {
      state = ApprovalsState(items: _parse(msg['items']), status: state.status);
    });
    ref.onDispose(unsub);
    scheduleMicrotask(refresh);
    return const ApprovalsState();
  }

  static List<ExternalApproval> _parse(Object? items) => [
    for (final item in (items as List? ?? const []))
      if (item is Map && item['id'] is String)
        ExternalApproval(Map<String, dynamic>.from(item)),
  ];

  Future<void> refresh() async {
    final client = _client;
    if (client == null || !hostSupportsApprovals(client)) return;
    try {
      final list = await client.requestMap('approvals.list');
      final status = await client.requestMap('approvals.status');
      state = ApprovalsState(items: _parse(list['items']), status: status);
    } catch (_) {
      // Keep what we have; the next push or reconnect refreshes it.
    }
  }

  /// Returns null on success, or why it did not go through.
  Future<String?> resolve(
    ExternalApproval approval, {
    required bool allow,
    Map<String, String>? answers,
    String? message,
  }) async {
    final client = _client;
    if (client == null) return 'Not connected to the PC.';
    try {
      final result = await client.requestMap('approvals.resolve', {
        'id': approval.id,
        'decision': allow ? 'allow' : 'deny',
        'answers': ?answers,
        if (message != null && message.trim().isNotEmpty)
          'message': message.trim(),
      });
      if (result['ok'] == true) {
        state = ApprovalsState(
          items: state.items.where((a) => a.id != approval.id).toList(),
          status: state.status,
        );
        return null;
      }
      unawaited(refresh());
      return result['message'] as String? ?? 'That didn’t go through.';
    } catch (e) {
      return 'That didn’t go through: $e';
    }
  }

  Future<String?> configure({bool? claude, bool? holdTerminal}) async {
    final client = _client;
    if (client == null) return 'Not connected to the PC.';
    try {
      final status = await client.requestMap('approvals.configure', {
        'claude': ?claude,
        'holdTerminal': ?holdTerminal,
      });
      state = ApprovalsState(items: state.items, status: status);
      return (status['claude'] as Map?)?['error'] as String?;
    } catch (e) {
      return 'That didn’t go through: $e';
    }
  }
}

final approvalsProvider = NotifierProvider<ApprovalsNotifier, ApprovalsState>(
  ApprovalsNotifier.new,
);

/// Allow/deny, answer or approve-the-plan controls for one pending prompt.
class ApprovalPanel extends ConsumerStatefulWidget {
  const ApprovalPanel({super.key, required this.approval});
  final ExternalApproval approval;
  @override
  ConsumerState<ApprovalPanel> createState() => _ApprovalPanelState();
}

class _ApprovalPanelState extends ConsumerState<ApprovalPanel> {
  bool _busy = false;
  bool _expanded = false;
  bool _feedback = false;
  final _picked = <String, Set<String>>{};
  final _other = <String, TextEditingController>{};
  final _note = TextEditingController();

  @override
  void dispose() {
    for (final c in _other.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  ExternalApproval get a => widget.approval;

  String? _answer(ApprovalQuestion q) {
    final other = _other[q.question]?.text.trim() ?? '';
    final picked = [...?_picked[q.question], if (other.isNotEmpty) other];
    return picked.isEmpty ? null : picked.join(', ');
  }

  Future<void> _send({
    required bool allow,
    Map<String, String>? answers,
    String? message,
  }) async {
    setState(() => _busy = true);
    final error = await ref
        .read(approvalsProvider.notifier)
        .resolve(a, allow: allow, answers: answers, message: message);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = a.kind == 'question' ? NX.accent : NX.waiting;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(NX.radiusSm),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                switch (a.kind) {
                  'question' => Icons.help_outline_rounded,
                  'plan' => Icons.map_outlined,
                  _ => Icons.shield_outlined,
                },
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [
                    switch (a.kind) {
                      'question' => 'Question',
                      'plan' => 'Plan to approve',
                      _ => 'Needs approval',
                    },
                    if (a.subagent != null) 'sub-agent ${a.subagent}',
                  ].join(' · '),
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            a.title,
            style: const TextStyle(
              color: NX.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          if (a.detail != null && a.detail != a.title) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: NX.bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  a.detail!,
                  maxLines: _expanded ? 60 : 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NX.textDim,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ],
          if (a.kind == 'question')
            ..._questionControls()
          else
            ..._decisionControls(),
          if (a.mirrored) ...[
            const SizedBox(height: 8),
            const Text(
              'Also open on your PC. Whichever you answer first wins.',
              style: TextStyle(color: NX.textFaint, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _decisionControls() {
    final plan = a.kind == 'plan';
    return [
      if (_feedback) ...[
        const SizedBox(height: 10),
        TextField(
          controller: _note,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: plan
                ? 'What should change in the plan?'
                : 'Why not? (optional)',
            isDense: true,
            filled: true,
          ),
        ),
      ],
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () {
                      if (plan && !_feedback) {
                        setState(() => _feedback = true);
                      } else {
                        _send(allow: false, message: _note.text);
                      }
                    },
              child: Text(
                plan
                    ? (_feedback ? 'Send feedback' : 'Keep planning')
                    : (_feedback ? 'Send deny' : 'Deny'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : () => _send(allow: true),
              child: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(plan ? 'Approve plan' : 'Allow'),
            ),
          ),
        ],
      ),
      if (!plan && !_feedback)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : () => setState(() => _feedback = true),
            child: const Text('Deny with a note'),
          ),
        ),
    ];
  }

  List<Widget> _questionControls() {
    final questions = a.questions;
    final complete =
        questions.isNotEmpty && questions.every((q) => _answer(q) != null);
    return [
      for (final q in questions) ...[
        const SizedBox(height: 10),
        if (questions.length > 1 || q.header != null)
          Text(
            questions.length > 1 ? q.question : q.header!,
            style: const TextStyle(
              color: NX.textDim,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in q.options)
              ChoiceChip(
                label: Text(o.label),
                tooltip: o.description,
                selected: _picked[q.question]?.contains(o.label) ?? false,
                onSelected: _busy
                    ? null
                    : (on) => setState(() {
                        final set = _picked.putIfAbsent(q.question, () => {});
                        if (!q.multiSelect) set.clear();
                        if (on) {
                          set.add(o.label);
                        } else {
                          set.remove(o.label);
                        }
                      }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _other.putIfAbsent(q.question, TextEditingController.new),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Or type your own answer',
            isDense: true,
            filled: true,
          ),
        ),
      ],
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _send(
                      allow: false,
                      message: 'The owner declined to answer from the phone.',
                    ),
              child: const Text('Decline'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: _busy || !complete
                  ? null
                  : () => _send(
                      allow: true,
                      answers: {
                        for (final q in questions) q.question: _answer(q)!,
                      },
                    ),
              child: const Text('Send answer'),
            ),
          ),
        ],
      ),
    ];
  }
}
