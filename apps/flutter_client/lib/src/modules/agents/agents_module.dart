// Agents: monitor, arena, chats and the agent screen over NexusLink. Also
// surfaces the existing Android monitor live activity in the live bar.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../shell/module.dart';
import '../../shell/module_extras.dart';
import '../../shell/shell_navigator.dart';
import '../../theme/nexus_theme.dart';
import '../../workspace/platform_bridge.dart';
import '../../workspace/workspace_shell.dart';

/// Reads the native live-activity status (`live.status`). Null when the
/// platform has none.
typedef LiveStatusReader = Future<Map<String, dynamic>?> Function();

class AgentsModule extends NexusModule implements DescribedModule {
  const AgentsModule();

  /// Test hook; defaults to the Android platform bridge.
  @visibleForTesting
  static LiveStatusReader? liveStatusReader;

  /// Test hook for stopping the monitor from the live bar.
  @visibleForTesting
  static Future<void> Function()? liveStopper;

  static const pollInterval = Duration(seconds: 5);

  @override
  String get id => 'agents';
  @override
  String get title => 'Agents';
  @override
  String get subtitle => 'Monitor · Arena · Chats';
  @override
  Color get accent => NX.accent2;
  @override
  IconData get icon => Icons.smart_toy_outlined;
  @override
  CapabilityRequirement get requires =>
      const CapabilityRequirement.anyOf(['agents']);
  @override
  int get order => 20;

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) =>
      WorkspaceShell(
        key: const ValueKey('module-agents'),
        tabs: const [WorkspaceTabs.monitor],
        onForeignTab: ShellNavigator.instance.openWorkspaceTab,
      );

  static LiveStatusReader? get _reader =>
      liveStatusReader ??
      (Platform.isAndroid
          ? () async {
              final raw = await PlatformBridge.call('live.status');
              return raw is Map ? Map<String, dynamic>.from(raw) : null;
            }
          : null);

  static Future<void> _stop() =>
      (liveStopper ?? () => PlatformBridge.call('live.stop'))();

  /// The monitor's foreground service, as one live activity while it runs.
  @override
  Stream<List<LiveActivity>>? liveActivities(ModuleContext ctx) {
    final read = _reader;
    if (read == null) return null;
    late StreamController<List<LiveActivity>> controller;
    Timer? timer;
    var stopped = false;
    Future<void> poll() async {
      Map<String, dynamic>? status;
      try {
        status = await read();
      } catch (_) {
        status = null;
      }
      if (stopped) return;
      controller.add(monitorActivities(status, onStop: () async {
        await _stop();
        await poll();
      }));
    }

    controller = StreamController<List<LiveActivity>>(
      onListen: () {
        poll();
        timer = Timer.periodic(pollInterval, (_) => poll());
      },
      onCancel: () {
        stopped = true;
        timer?.cancel();
      },
    );
    return controller.stream;
  }

  /// Pure mapping from `live.status` to live-bar entries.
  static List<LiveActivity> monitorActivities(
    Map<String, dynamic>? status, {
    VoidCallback? onStop,
  }) {
    if (status == null || status['monitoringRequested'] != true) {
      return const [];
    }
    final state = status['connectionState'];
    final label = switch (state) {
      'connecting' || 'reconnecting' => 'Agent monitor · reconnecting',
      _ when status['bubbleRequested'] == true => 'Agent monitor · pet on',
      _ => 'Agent monitor',
    };
    return [
      LiveActivity(
        moduleId: 'agents',
        label: label,
        icon: Icons.radar,
        onTap: () => ShellNavigator.instance.openModule('agents'),
        onStop: onStop,
      ),
    ];
  }
}
