import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../services/notification_service.dart';
import '../state/connection.dart';

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
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _backgroundedAtMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  Future<void> _onResumed() async {
    final since = _backgroundedAtMs;
    _backgroundedAtMs = null;
    await ref.read(connectionProvider.notifier).ensureConnected();
    if (!mounted || since == null) return;
    await _catchUpAgentEvents(since);
  }

  Future<void> _catchUpAgentEvents(int sinceMs) async {
    final client = ref.read(activeClientProvider);
    if (client == null || client.status != RpcStatus.connected) return;
    try {
      final sessionsRaw = await client.requestList(
        'agent.listSessions',
        const {},
        const Duration(seconds: 8),
      );
      for (final row in sessionsRaw) {
        if (row is! Map<String, dynamic>) continue;
        final session = AgentSessionInfo.fromJson(row);
        final historyRaw = await client.requestList(
          'agent.history',
          {'agentSessionId': session.agentSessionId},
          const Duration(seconds: 8),
        );
        for (final ev in historyRaw) {
          if (ev is! Map<String, dynamic>) continue;
          final parsed = AgentEvent.fromJson(ev);
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
      _unsubAgentEvent = client.subscribe('agent-event', (msg) {
        final sessionId = msg['agentSessionId'] as String?;
        final ev = msg['event'];
        if (ev is! Map<String, dynamic>) return;
        final parsed = AgentEvent.fromJson(ev);
        NotificationService.instance.handleAgentEvent(sessionId, parsed);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeClientProvider);
    _bindClient(client);
    return widget.child;
  }
}

