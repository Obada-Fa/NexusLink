import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../services/notification_service.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';

/// Root navigator, so app-wide UI (this lifecycle wrapper) can return to the
/// connect screen.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Only catch up on missed alerts after a real trip to the background.
const _catchUpAfter = Duration(seconds: 30);

class ConnectionLifecycle extends ConsumerStatefulWidget {
  final Widget child;
  const ConnectionLifecycle({super.key, required this.child});

  @override
  ConsumerState<ConnectionLifecycle> createState() =>
      _ConnectionLifecycleState();
}

class _ConnectionLifecycleState extends ConsumerState<ConnectionLifecycle>
    with WidgetsBindingObserver {
  void Function()? _unsubAgentEvent;
  RpcClient? _subscribedClient;
  int? _backgroundedAtMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _unsubAgentEvent?.call();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
      return;
    }
    // `inactive` alone (notification shade, app switcher peek, permission
    // dialogs) does not touch the socket, so it must not trigger resync work.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _backgroundedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    }
  }

  Future<void> _onResumed() async {
    final since = _backgroundedAtMs;
    _backgroundedAtMs = null;
    if (since == null) return;
    await ref.read(connectionProvider.notifier).ensureConnected();
    if (!mounted) return;
    final away = DateTime.now().millisecondsSinceEpoch - since;
    // On Android the native live activity owns task alerts, so there is
    // nothing to catch up here.
    if (NotificationService.instance.showsAgentAlerts &&
        away >= _catchUpAfter.inMilliseconds) {
      await _catchUpAgentEvents(since);
    }
  }

  /// Replays alerts for sessions that changed while the app was away. Bounded:
  /// only recently updated sessions, newest page only.
  Future<void> _catchUpAgentEvents(int sinceMs) async {
    final client = ref.read(activeClientProvider);
    if (client == null || client.status != RpcStatus.connected) return;
    try {
      final sessionsRaw = await client.requestList(
        'agent.listSessions',
        const {},
        const Duration(seconds: 8),
      );
      final changed = sessionsRaw
          .whereType<Map>()
          .map(
            (row) => AgentSessionInfo.fromJson(Map<String, dynamic>.from(row)),
          )
          .where((s) => !s.archived && s.updatedAt >= sinceMs)
          .take(5);
      for (final session in changed) {
        final List<dynamic> events;
        if (client.supports('agent.historyPage')) {
          final page = await client.requestMap('agent.historyPage', {
            'agentSessionId': session.agentSessionId,
            'limit': 30,
          }, const Duration(seconds: 8));
          events = page['events'] as List? ?? const [];
        } else {
          events = await client.requestList('agent.history', {
            'agentSessionId': session.agentSessionId,
          }, const Duration(seconds: 8));
        }
        for (final ev in events.whereType<Map>()) {
          final parsed = AgentEvent.fromJson(Map<String, dynamic>.from(ev));
          if (parsed.ts < sinceMs) continue;
          NotificationService.instance.handleAgentEvent(
            session.agentSessionId,
            parsed,
            sessionTitle: session.title,
          );
        }
      }
    } catch (_) {
      // Best effort: resume should still proceed even if catch-up fails.
    }
  }

  void _bindClient(RpcClient? client) {
    if (identical(client, _subscribedClient)) return;
    _unsubAgentEvent?.call();
    _unsubAgentEvent = null;
    _subscribedClient = client;

    if (client != null) {
      unawaited(NotificationService.instance.registerWithHost(client));
      if (NotificationService.instance.showsAgentAlerts) {
        _unsubAgentEvent = client.subscribe('agent-event', (msg) {
          final sessionId = msg['agentSessionId'] as String?;
          final ev = msg['event'];
          if (ev is! Map<String, dynamic>) return;
          final parsed = AgentEvent.fromJson(ev);
          NotificationService.instance.handleAgentEvent(sessionId, parsed);
        });
      }
    }
  }

  void _pairAgain() {
    // Drop the refused connection; the connect screen already holds the
    // PC's address and opens its pairing form.
    ref.read(connectionProvider.notifier).disconnect();
    appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeClientProvider);
    _bindClient(client);
    final authRequired = ref.watch(connectionAuthRequiredProvider);
    // Failed connects from the connect screen explain themselves there; this
    // banner covers a pairing that was revoked while the app was in use.
    if (!authRequired || client == null) return widget.child;
    return Column(
      children: [
        Material(
          color: NX.surface3,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.link_off, color: NX.waiting, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'This phone is no longer paired with your PC.',
                      style: TextStyle(color: NX.text, fontSize: 13.5),
                    ),
                  ),
                  TextButton(
                    onPressed: _pairAgain,
                    child: const Text('Pair again'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
