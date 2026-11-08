// Nexus — one phone app for everything your PC offers. The shell picks a
// target (a PC now), shows one tile per module it can run, and keeps the
// session (pairing, reconnect, reachability) for the modules.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/services/notification_service.dart';
import 'src/shell/home_screen.dart';
import 'src/shell/shell_controller.dart';
import 'src/theme/nexus_theme.dart';
import 'src/widgets/app_error_view.dart';
import 'src/widgets/connection_lifecycle.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  ErrorWidget.builder = AppErrorView.fromDetails;
  appReloadGeneration.addListener(resetAutoConnect);
  runApp(
    ValueListenableBuilder<int>(
      valueListenable: appReloadGeneration,
      builder: (_, generation, _) => ProviderScope(
        key: ValueKey(generation),
        child: const NexusApp(),
      ),
    ),
  );
}

class NexusApp extends StatelessWidget {
  const NexusApp({super.key, this.home = const HomeScreen()});

  /// Overridable so tests can pin timers or start elsewhere.
  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus',
      debugShowCheckedModeBanner: false,
      theme: nexusTheme(),
      navigatorKey: appNavigatorKey,
      builder: (context, child) =>
          ConnectionLifecycle(child: child ?? const SizedBox.shrink()),
      home: home,
    );
  }
}

/// Test hook: lets widget tests start from a fresh "cold start".
@visibleForTesting
void resetAutoConnectForTest() => resetAutoConnect();
