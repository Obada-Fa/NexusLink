import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/monitor/monitor_models.dart';
import 'package:nexuslink/src/monitor/monitor_provider.dart';
import 'package:nexuslink/src/pc/pc_actions.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/screens/launcher_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/launcher.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'package:nexuslink/src/theme/nx_widgets.dart';

// --- fixture: readings sampled from the owner's PC, plus a frozen app ------

Map<String, dynamic> _gpu({
  required String id,
  required String name,
  required bool integrated,
  required num busy,
  required num vramUsed,
  required num vramTotal,
  num? temp,
  num? hotspot,
  num? memTemp,
  num? power,
  num? cap,
  num? fan,
  num? mhz,
}) => {
  'id': id,
  'name': name,
  'vendor': 'amd',
  'integrated': integrated,
  'busyPercent': busy,
  'memBusyPercent': integrated ? null : 3,
  'vramUsedBytes': vramUsed,
  'vramTotalBytes': vramTotal,
  'tempC': temp,
  'hotspotC': hotspot,
  'memTempC': memTemp,
  'powerW': power,
  'powerCapW': cap,
  'fanRpm': fan,
  'coreMHz': mhz,
};

Map<String, dynamic> snapshotJson() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'at': now,
    'vitals': {
      'timestamp': now,
      'hostname': 'obada-PC',
      'uptimeSeconds': 21413,
      'load': [0.27, 0.54, 0.6],
      'cpu': {
        'model': 'AMD Ryzen 7 7800X3D 8-Core Processor',
        'cores': 16,
        'percent': 42.4,
        'perCore': [for (var i = 0; i < 16; i++) (i * 13.0) % 100],
        'tempC': 61.2,
        'mhz': 4712,
      },
      'memory': {
        'totalBytes': 32751071232,
        'usedBytes': 16442429440,
        'cachedBytes': 13058740224,
        'swapTotalBytes': 2147479552,
        'swapUsedBytes': 0,
        'percent': 50.2,
      },
      'gpus': [
        _gpu(
          id: 'card1',
          name: 'AMD Radeon RX 9070 series',
          integrated: false,
          busy: 67,
          vramUsed: 2172596224,
          vramTotal: 17095983104,
          temp: 52,
          hotspot: 71,
          memTemp: 66,
          power: 188,
          cap: 317,
          fan: 1450,
          mhz: 2410,
        ),
        _gpu(
          id: 'card0',
          name: 'AMD Radeon iGPU (Raphael)',
          integrated: true,
          busy: 0,
          vramUsed: 26341376,
          vramTotal: 536870912,
          temp: 32,
          power: 37.2,
          mhz: 600,
        ),
      ],
      'disk': {
        'readBps': 1048576,
        'writeBps': 339945,
        'nvmeTempC': 39.9,
        'root': {'freeBytes': 19551244288, 'totalBytes': 249610866688},
        'home': {'freeBytes': 19551244288, 'totalBytes': 249610866688},
      },
      'net': {
        'rxBps': 11040,
        'txBps': 46504,
        'interfaces': [
          {'name': 'eno1', 'rxBps': 0, 'txBps': 0, 'vpn': false},
          {'name': 'wlp9s0', 'rxBps': 11040, 'txBps': 46504, 'vpn': false},
          {'name': 'tailscale0', 'rxBps': 0, 'txBps': 0, 'vpn': true},
        ],
      },
      'top': [
        {
          'pid': 194463,
          'name': 'claude-desktop (renderer)',
          'cpuPercent': 6.3,
          'rssBytes': 792735744,
        },
        {
          'pid': 17326,
          'name': 'anydesk',
          'cpuPercent': 0.4,
          'rssBytes': 3354353664,
        },
        {
          'pid': 4964,
          'name': 'ChatGPT (renderer)',
          'cpuPercent': 0.2,
          'rssBytes': 784879616,
        },
      ],
      'processCount': 682,
      'batteries': [
        {'name': 'PRO X Wireless', 'percent': 36, 'charging': false},
      ],
    },
    'apps': [
      {
        'id': 'claude-desktop',
        'appId': 'claude-desktop',
        'name': 'Claude',
        'provider': 'claude',
        'kind': 'desktop',
        'pid': 194057,
        'processCount': 31,
        'cpuPercent': 6.3,
        'rssBytes': 3111550976,
        'startedAt': now - 3900000,
        'cwd': null,
        'tty': null,
        'state': 'stuck',
        'windows': [
          {'id': '0x00e00004', 'title': 'Claude'},
        ],
        'cpuHistory': [6.1, 6.3, 6.2, 6.4, 6.3, 6.3],
        'actions': ['focus', 'restart', 'quit', 'kill'],
      },
      {
        'id': 'codex-desktop',
        'appId': 'codex-desktop',
        'name': 'Codex',
        'provider': 'codex',
        'kind': 'desktop',
        'pid': 2527,
        'processCount': 35,
        'cpuPercent': 0.7,
        'rssBytes': 3288477696,
        'startedAt': now - 21000000,
        'cwd': null,
        'tty': null,
        'state': 'active',
        'windows': [
          {'id': '0x03c00004', 'title': 'ChatGPT'},
        ],
        'cpuHistory': [0.2, 1.4, 0.7, 0.9, 0.7],
        'actions': ['focus', 'restart', 'quit', 'kill'],
      },
      {
        'id': 'claude-code:31337',
        'appId': 'claude-code',
        'name': 'Claude Code',
        'provider': 'claude',
        'kind': 'cli',
        'pid': 31337,
        'processCount': 3,
        'cpuPercent': 1.2,
        'rssBytes': 536870912,
        'startedAt': now - 600000,
        'cwd': '/home/obada/projects/mobile/NexusLink',
        'tty': 'pts/3',
        'state': 'active',
        'windows': [],
        'cpuHistory': [0.4, 2.0, 1.2],
        'actions': ['kill'],
      },
    ],
    'launchers': [
      {
        'appId': 'claude-desktop',
        'name': 'Claude',
        'provider': 'claude',
        'kind': 'desktop',
        'running': true,
      },
      {
        'appId': 'cursor',
        'name': 'Cursor',
        'provider': 'cursor',
        'kind': 'desktop',
        'running': false,
      },
    ],
    'remote': [
      {
        'id': 'rustdesk',
        'name': 'RustDesk',
        'installed': true,
        'state': 'degraded',
        'summary':
            'RustDesk is attached to display :1, but your desktop is :0.',
        'issues': [
          'RustDesk is attached to display :1, but your desktop is :0.',
          'A second RustDesk (Flatpak) is installed and can steal the connection. Run packaging/rustdesk/install.sh once.',
        ],
        'details': {
          'service': 'active',
          'display': ':1',
          'expectedDisplay': ':0',
          'directPort': true,
          'passwordlessRestart': false,
        },
        'actions': ['restart', 'repair'],
        'lastRepairAt': now - 180000,
        'lastRepairReason': 'watchdog: RustDesk is not serving this desktop',
      },
      {
        'id': 'tailscale',
        'name': 'Tailscale',
        'installed': true,
        'state': 'healthy',
        'summary': '100.108.139.27 · 2/6 devices online',
        'issues': [],
        'details': {},
        'actions': [],
        'lastRepairAt': null,
        'lastRepairReason': null,
      },
      {
        'id': 'nexuslink',
        'name': 'NexusLink host',
        'installed': true,
        'state': 'healthy',
        'summary': 'Up 2 h 4 min · 54 MB',
        'issues': [],
        'details': {},
        'actions': [],
        'lastRepairAt': null,
        'lastRepairReason': null,
      },
    ],
  };
}

MonitorHistory historyFixture() => MonitorHistory({
  'cpu': [for (var i = 0; i < 40; i++) 20 + (i * 7 % 30).toDouble()],
  'gpu': [for (var i = 0; i < 40; i++) 40 + (i * 11 % 35).toDouble()],
  'ram': [for (var i = 0; i < 40; i++) 49 + (i % 3).toDouble()],
  'vram': [for (var i = 0; i < 40; i++) 12 + (i % 4).toDouble()],
  'cpuTemp': [for (var i = 0; i < 40; i++) 55 + (i % 9).toDouble()],
  'gpuTemp': [for (var i = 0; i < 40; i++) 60 + (i % 12).toDouble()],
  'netRx': [for (var i = 0; i < 40; i++) 1000.0 * (i % 7)],
  'netTx': [for (var i = 0; i < 40; i++) 4000.0 * (i % 5)],
  'diskRead': [for (var i = 0; i < 40; i++) 50000.0 * (i % 4)],
  'diskWrite': [for (var i = 0; i < 40; i++) 30000.0 * (i % 6)],
  'gpuPower': [for (var i = 0; i < 40; i++) 120 + (i * 5 % 70).toDouble()],
});

// --- fakes --------------------------------------------------------------------

class FakeMonitor extends MonitorNotifier {
  FakeMonitor({this.remoteReply = 'RustDesk restarted.'});
  final String remoteReply;
  final calls = <String>[];
  Completer<String>? pendingApp;

  @override
  MonitorState build() => MonitorState(
    snapshot: MonitorSnapshot(snapshotJson()),
    history: historyFixture(),
  );

  @override
  Future<void> refresh() async {}

  @override
  Future<String> appAction(AgentApp app, String action) {
    calls.add('app:${app.id}:$action');
    final pending = pendingApp;
    return pending != null ? pending.future : Future.value('${app.name} done.');
  }

  @override
  Future<String> launch(String appId) async {
    calls.add('launch:$appId');
    return 'Starting $appId…';
  }

  @override
  Future<String> remoteAction(String service, String action) async {
    calls.add('remote:$service:$action');
    return remoteReply;
  }
}

class FakeConnection extends ConnectionNotifier {
  bool disconnected = false;
  @override
  ConnectionState build() => const ConnectionState(
    status: RpcStatus.connected,
    hostUrl: 'ws://192.168.2.30:45678',
  );
  @override
  void disconnect() {
    disconnected = true;
    state = const ConnectionState();
  }
}

class NoApps extends AppsNotifier {
  @override
  AsyncValue<List<AppInfo>> build() => const AsyncData([]);
}

class NoWindows extends WindowsNotifier {
  @override
  AsyncValue<List<WindowInfo>> build() => const AsyncData([]);
}

class NoSessions extends AppSessionsNotifier {
  @override
  AsyncValue<List<AppSessionInfo>> build() => const AsyncData([]);
}

// --- harness -----------------------------------------------------------------

Future<void> pumpPcTab(
  WidgetTester tester,
  FakeMonitor monitor, {
  Size size = const Size(412, 915),
  double textScale = 1,
  FakeConnection? connection,
  Widget Function(Widget tab)? wrap,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        monitorProvider.overrideWith(() => monitor),
        connectionProvider.overrideWith(() => connection ?? FakeConnection()),
        appsProvider.overrideWith(NoApps.new),
        windowsProvider.overrideWith(NoWindows.new),
        appSessionsProvider.overrideWith(NoSessions.new),
      ],
      child: MaterialApp(
        theme: nexusTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: wrap == null
            ? const LauncherScreen()
            : wrap(const LauncherScreen()),
      ),
    ),
  );
  await settle(tester);
}

/// Live dots pulse forever, so settle with fixed pumps instead of pumpAndSettle.
Future<void> settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get mainList => find.byType(Scrollable).first;

Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 250, scrollable: mainList);
  await settle(tester, 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('hero gauges render live values and open the detail sheet', (
    tester,
  ) async {
    await pumpPcTab(tester, FakeMonitor());

    expect(find.text('obada-PC'), findsOneWidget);
    Finder gauge(String value) =>
        find.descendant(of: find.byType(RingGauge), matching: find.text(value));
    expect(gauge('42%'), findsOneWidget); // CPU
    expect(gauge('67%'), findsOneWidget); // GPU
    expect(gauge('50%'), findsOneWidget); // RAM
    expect(gauge('61°C'), findsOneWidget); // CPU temperature caption
    expect(gauge('71°C'), findsOneWidget); // GPU hotspot caption
    expect(
      find.bySemanticsLabel(RegExp(r'^CPU 42 percent, 61 degrees')),
      findsOneWidget,
    );
    // The frozen app wins the verdict line.
    expect(find.textContaining('Claude may be frozen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp(r'^CPU 42 percent')));
    await settle(tester);
    expect(find.text('THREADS'), findsOneWidget);
    expect(find.text('LOAD AVERAGE'), findsOneWidget);
    await tester.tap(find.text('GPU').last);
    await settle(tester);
    expect(find.text('Radeon RX 9070'), findsOneWidget);
    expect(find.text('188/317 W'), findsOneWidget);
    expect(find.text('2.0/15.9 GB'), findsOneWidget);
    expect(find.text('HOTSPOT'), findsOneWidget);
    await tester.tap(find.text('Memory').last);
    await settle(tester);
    expect(find.text('BREAKDOWN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flow strip warns about the nearly full disk', (tester) async {
    await pumpPcTab(tester, FakeMonitor());
    await scrollTo(tester, find.text('PRO X Wireless'));
    expect(find.text('18.2 GB free'), findsOneWidget);
    expect(find.text('LOW'), findsOneWidget);
    expect(find.text('Under 10 % free — clean up soon'), findsOneWidget);
    expect(find.text('NVMe 40°C'), findsOneWidget);
    expect(find.text('36%'), findsOneWidget);
  });

  testWidgets('a stuck app shows Frozen? and Restart confirms, shows '
      'progress, then calls appAction', (tester) async {
    final monitor = FakeMonitor()..pendingApp = Completer<String>();
    await pumpPcTab(tester, monitor);

    final claude = find.byKey(const ValueKey('agent-app-claude-desktop'));
    await scrollTo(tester, claude);
    expect(
      find.descendant(of: claude, matching: find.text('Frozen?')),
      findsOneWidget,
    );
    final restart = find.descendant(of: claude, matching: find.text('Restart'));
    await scrollTo(tester, restart);

    // Cancel does nothing.
    await tester.tap(restart);
    await settle(tester, 4);
    expect(find.text('Restart Claude?'), findsOneWidget);
    expect(find.textContaining('6 seconds'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester, 4);
    expect(monitor.calls, isEmpty);

    await tester.tap(restart);
    await settle(tester, 4);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Restart'),
      ),
    );
    await settle(tester, 3);
    expect(monitor.calls, ['app:claude-desktop:restart']);
    expect(find.text('Restarting Claude…'), findsOneWidget);
    expect(
      find.descendant(
        of: claude,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    monitor.pendingApp!.complete(
      'Claude restarted (it had to be force-stopped).',
    );
    await settle(tester, 4);
    expect(find.text('Restarting Claude…'), findsNothing);
    expect(
      find.text('Claude restarted (it had to be force-stopped).'),
      findsOneWidget,
    );
  });

  testWidgets('overflow menu force-stops, CLI agents stop, launchers start', (
    tester,
  ) async {
    final monitor = FakeMonitor();
    await pumpPcTab(tester, monitor);

    await scrollTo(tester, find.byTooltip('More actions for Codex'));
    await tester.tap(find.byTooltip('More actions for Codex'));
    await settle(tester, 4);
    await tester.tap(find.text('Force stop').last);
    await settle(tester, 4);
    expect(find.text('Force stop Codex?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Force stop'),
      ),
    );
    await settle(tester, 4);

    final cli = find.byKey(const ValueKey('agent-cli-claude-code:31337'));
    await scrollTo(tester, cli);
    expect(
      find.descendant(of: cli, matching: find.textContaining('pts/3')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: cli, matching: find.text('Stop')));
    await settle(tester, 4);
    expect(find.text('Stop Claude Code?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Stop'),
      ),
    );
    await settle(tester, 4);

    await scrollTo(tester, find.text('Start Cursor'));
    await tester.tap(find.text('Start Cursor'));
    await settle(tester, 4);

    expect(monitor.calls, [
      'app:codex-desktop:kill',
      'app:claude-code:31337:kill',
      'launch:cursor',
    ]);
  });

  testWidgets('Restart RustDesk calls remoteAction and offers the one-time '
      'setup command', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final monitor = FakeMonitor(
      remoteReply:
          'This PC needs a one-time setup to let NexusLink restart RustDesk: run `sudo bash packaging/rustdesk/install.sh` in the NexusLink folder.',
    );
    await pumpPcTab(tester, monitor);

    await scrollTo(tester, find.text('Restart RustDesk'));
    expect(find.textContaining('Auto-repaired 3 min ago'), findsOneWidget);
    expect(find.textContaining('Flatpak'), findsOneWidget);
    await tester.tap(find.text('Restart RustDesk'));
    await settle(tester, 4);
    expect(find.text('Restart RustDesk?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Restart'),
      ),
    );
    await settle(tester, 8);
    expect(monitor.calls, ['remote:rustdesk:restart']);
    expect(find.text('One-time RustDesk setup'), findsOneWidget);
    expect(find.text(rustdeskSetupCommand), findsOneWidget);
    await tester.tap(find.byTooltip('Copy command'));
    await settle(tester, 4);
    expect(copied, 'sudo bash packaging/rustdesk/install.sh');
  });

  testWidgets('no overflow at 320×640 with 1.3× text', (tester) async {
    await pumpPcTab(
      tester,
      FakeMonitor(),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    // Walk the whole tab so every section lays out at this size.
    for (var i = 0; i < 30; i++) {
      await tester.drag(mainList, const Offset(0, -300));
      await settle(tester, 2);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Your desktop'), findsOneWidget);
    // And each detail page, opened from its gauge and scrolled to the end.
    await tester.fling(mainList, const Offset(0, 6000), 3000);
    await settle(tester, 8);
    for (final gauge in ['CPU 42 percent', 'GPU 67 percent', 'Memory 50']) {
      await tester.tap(find.bySemanticsLabel(RegExp('^$gauge')));
      await settle(tester);
      final sheet = find.byType(DraggableScrollableSheet);
      expect(sheet, findsOneWidget);
      await tester.fling(
        find.descendant(of: sheet, matching: find.byType(Scrollable)).first,
        const Offset(0, -2000),
        2000,
      );
      await settle(tester, 6);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(sheet)).pop();
      await settle(tester, 6);
    }
  });

  testWidgets('power button confirms, disconnects and returns to the '
      'connect screen', (tester) async {
    final connection = FakeConnection();
    await pumpPcTab(
      tester,
      FakeMonitor(),
      connection: connection,
      // Like the app: connect screen → workspace route → nested tab navigator.
      wrap: (tab) => Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Navigator(
                    onGenerateRoute: (_) =>
                        MaterialPageRoute(builder: (_) => tab),
                  ),
                ),
              ),
              child: const Text('Connect screen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Connect screen'));
    await settle(tester);
    expect(find.byType(LauncherScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Disconnect from PC'));
    await settle(tester, 4);
    expect(find.text('Disconnect from this PC?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester, 4);
    expect(connection.disconnected, isFalse);
    expect(find.byType(LauncherScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Disconnect from PC'));
    await settle(tester, 4);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Disconnect'),
      ),
    );
    await settle(tester);
    expect(connection.disconnected, isTrue);
    expect(find.byType(LauncherScreen), findsNothing);
    expect(find.text('Connect screen'), findsOneWidget);
  });
}
