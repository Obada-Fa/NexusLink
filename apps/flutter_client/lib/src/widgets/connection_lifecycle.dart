// Reconnect the PC session when the phone comes back to the foreground.
// Android/iOS freeze timers in the background, so ping/heartbeat stop and
// the WebSocket is often dead by the time the user reopens the app.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(connectionProvider.notifier).ensureConnected();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
