// App info drops its commands when what it shows goes away while open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/monitor/monitor_models.dart';
import 'package:nexuslink/src/monitor/monitor_provider.dart';
import 'package:nexuslink/src/pc/app_actions.dart';
import 'package:nexuslink/src/pc/app_info.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/launcher.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pc_tab_test.dart' as pc;

const agentId = 'claude-code:31337';

/// The fixture PC, whose terminal agent can exit and come back.
class ExitingMonitor extends pc.FakeMonitor {
  void setAgentRunning(bool running) {
    final json = pc.snapshotJson();
    if (!running) {
      json['apps'] = [
        for (final a in json['apps'] as List)
          if ((a as Map)['id'] != agentId) a,
      ];
    }
    state = MonitorState(
      snapshot: MonitorSnapshot(json),
      history: pc.historyFixture(),
    );
  }
}

/// Windows that can close while App info is open.
class ClosingWindows extends WindowsNotifier {
  ClosingWindows(this.first);
  final List<WindowInfo> first;
  @override
  AsyncValue<List<WindowInfo>> build() => AsyncData(first);
  void close() => state = const AsyncData([]);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a terminal agent that exits loses its commands', (
    tester,
  ) async {
    final monitor = ExitingMonitor();
    await pc.pumpPcTab(
      tester,
      monitor,
      tab: const AppInfoScreen(entryKey: 'terminal:$agentId'),
    );
    expect(find.byKey(const ValueKey('app-info-kill')), findsOneWidget);

    monitor.setAgentRunning(false);
    await pc.settle(tester);
    expect(find.byKey(const ValueKey('app-info-kill')), findsNothing);
    expect(find.byKey(const ValueKey('app-info')), findsNothing);
    expect(find.byKey(const ValueKey('app-info-gone')), findsOneWidget);
    expect(find.text('Claude Code is no longer open.'), findsOneWidget);
    for (final c in ['restart', 'quit', 'kill']) {
      expect(find.byKey(ValueKey('app-info-$c')), findsNothing);
    }

    // It comes back (same id): live again, with its commands.
    monitor.setAgentRunning(true);
    await pc.settle(tester);
    expect(find.byKey(const ValueKey('app-info-kill')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-gone')), findsNothing);
    expect(monitor.calls.where((c) => c.startsWith('app:')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unidentified window that closes loses Quit', (tester) async {
    final windows = ClosingWindows([
      WindowInfo(
        windowId: '0xdead',
        title: 'Scratch terminal',
        wmClass: 'xterm',
        desktop: 0,
      ),
    ]);
    appProgress.value = const {};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monitorProvider.overrideWith(pc.FakeMonitor.new),
          connectionProvider.overrideWith(pc.FakeConnection.new),
          appsProvider.overrideWith(pc.NoApps.new),
          windowsProvider.overrideWith(() => windows),
          appSessionsProvider.overrideWith(pc.NoSessions.new),
        ],
        child: MaterialApp(
          theme: nexusTheme(),
          home: const AppInfoScreen(entryKey: 'window:0xdead'),
        ),
      ),
    );
    await pc.settle(tester);
    expect(find.byKey(const ValueKey('app-info-quit')), findsOneWidget);

    windows.close();
    await pc.settle(tester);
    expect(find.byKey(const ValueKey('app-info-quit')), findsNothing);
    expect(find.text('Scratch terminal is no longer open.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
