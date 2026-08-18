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
      ref.read(connectionProvider.notifier).ensureConnected();
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

