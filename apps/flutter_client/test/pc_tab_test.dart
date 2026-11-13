import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/monitor/monitor_models.dart';
import 'package:nexuslink/src/monitor/monitor_provider.dart';
import 'package:nexuslink/src/pc/app_actions.dart';
import 'package:nexuslink/src/pc/pc_actions.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/screens/launcher_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/launcher.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'package:nexuslink/src/workspace/workspace_shell.dart';

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

MonitorHistory historyFixture() => MonitorHistory.values({
  'cpu': [for (var i = 0; i < 40; i++) 20 + (i * 7 % 30).toDouble(), 42.4],
  'gpu': [for (var i = 0; i < 40; i++) 40 + (i * 11 % 35).toDouble(), 67],
  'ram': [for (var i = 0; i < 40; i++) 49 + (i % 3).toDouble(), 50.2],
  'vram': [for (var i = 0; i < 40; i++) 12 + (i % 4).toDouble()],
  'cpuTemp': [for (var i = 0; i < 40; i++) 55 + (i % 9).toDouble(), 61.2],
  'gpuTemp': [for (var i = 0; i < 40; i++) 60 + (i % 12).toDouble(), 71],
  'netRx': [for (var i = 0; i < 40; i++) 1000.0 * (i % 7), 11040],
  'netTx': [for (var i = 0; i < 40; i++) 4000.0 * (i % 5), 46504],
  'diskRead': [for (var i = 0; i < 40; i++) 50000.0 * (i % 4), 1048576],
  'diskWrite': [for (var i = 0; i < 40; i++) 30000.0 * (i % 6), 339945],
  'gpuPower': [for (var i = 0; i < 40; i++) 120 + (i * 5 % 70).toDouble(), 188],
});

// --- fakes --------------------------------------------------------------------

class FakeMonitor extends MonitorNotifier {
  FakeMonitor({
    this.remoteReply = 'RustDesk restarted.',
    this.json,
    this.empty = false,
    this.history,
  });
  final String remoteReply;

  /// History override (captures with a crafted spike).
  final MonitorHistory? history;

  /// Snapshot override (e.g. a PC without GPU telemetry).
  final Map<String, dynamic>? json;

  /// No snapshot at all, like an older host without monitor.v1.
  final bool empty;
  final calls = <String>[];
  Completer<String>? pendingApp;

  @override
  MonitorState build() => empty
      ? const MonitorState()
      : MonitorState(
          snapshot: MonitorSnapshot(json ?? snapshotJson()),
          history: history ?? historyFixture(),
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
  FakeConnection({this.status = RpcStatus.connected});
  final RpcStatus status;
  bool disconnected = false;
  @override
  ConnectionState build() =>
      ConnectionState(status: status, hostUrl: 'ws://192.168.2.30:45678');
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

class FixedApps extends AppsNotifier {
  FixedApps(this.list);
  final List<AppInfo> list;
  @override
  AsyncValue<List<AppInfo>> build() => AsyncData(list);
}

class FixedWindows extends WindowsNotifier {
  FixedWindows(this.list);
  final List<WindowInfo> list;
  @override
  AsyncValue<List<WindowInfo>> build() => AsyncData(list);
}

class FixedSessions extends AppSessionsNotifier {
  FixedSessions(this.list);
  final List<AppSessionInfo> list;
  @override
  AsyncValue<List<AppSessionInfo>> build() => AsyncData(list);
}

// --- harness -----------------------------------------------------------------

Future<void> pumpPcTab(
  WidgetTester tester,
  FakeMonitor monitor, {
  Size size = const Size(412, 915),
  double textScale = 1,
  FakeConnection? connection,
  Widget Function(Widget tab)? wrap,
  Widget tab = const LauncherScreen(),
  RpcClient? client,
  List<AppInfo>? apps,
  List<WindowInfo>? windows,
  List<AppSessionInfo>? sessions,
  Key? boundary,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  appProgress.value = const {};
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        monitorProvider.overrideWith(() => monitor),
        connectionProvider.overrideWith(() => connection ?? FakeConnection()),
        apps == null
            ? appsProvider.overrideWith(NoApps.new)
            : appsProvider.overrideWith(() => FixedApps(apps)),
        windows == null
            ? windowsProvider.overrideWith(NoWindows.new)
            : windowsProvider.overrideWith(() => FixedWindows(windows)),
        sessions == null
            ? appSessionsProvider.overrideWith(NoSessions.new)
            : appSessionsProvider.overrideWith(() => FixedSessions(sessions)),
        if (client != null) activeClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp(
        theme: nexusTheme(),
        builder: (context, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        home: wrap == null ? tab : wrap(tab),
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

Future<void> scrollTo(
  WidgetTester tester,
  Finder finder, {
  Finder? within,
}) async {
  await tester.scrollUntilVisible(finder, 250, scrollable: within ?? mainList);
  await settle(tester, 4);
}

Finder visibleList(String key) => find
    .descendant(
      of: find.byKey(PageStorageKey(key)),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('desktop-nav')),
      matching: find.text(label),
    ),
  );
  await settle(tester, 4);
}

Future<void> openMenu(WidgetTester tester, String name) async {
  final menu = find.byTooltip('Actions for $name').hitTestable();
  await tester.tap(menu.first);
  await settle(tester, 4);
}

Future<void> confirm(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text(label)),
  );
  await settle(tester, 4);
}

/// Like expect(takeException(), isNull), but says which widget overflowed.
void expectClean(WidgetTester tester, {String? reason}) {
  final e = tester.takeException();
  if (e != null) {
    fail('${e is FlutterError ? e.toStringDeep() : e}\n${reason ?? ''}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Desktop answers how the PC is doing, what to open and where '
      'you left off; readings open the system monitor', (tester) async {
    await pumpPcTab(tester, FakeMonitor());

    expect(find.text('obada-PC'), findsOneWidget);
    expect(find.text('Connected · up 5h 56m'), findsOneWidget);
    for (final text in [
      '42%', '61 °C', '4.7 GHz', // CPU
      '67%', '71 °C', '188 W', // GPU (hotspot, as charted)
      '50%', '15.3 / 30.5 GiB', // Memory
      '↓ 10.8 KiB/s', '↑ 45.4 KiB/s', // Network
      'R  1.0 MiB/s', 'W  332 KiB/s', // Disk
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    for (final label in ['Desktop', 'Apps', 'Running']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-nav')),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('Favourites'), findsOneWidget);
    // Opening the desktop needs no scrolling at the default text size.
    final open = tester.getRect(find.text('Open desktop'));
    final nav = tester.getRect(find.byKey(const ValueKey('desktop-nav')));
    expect(open.bottom, lessThan(nav.top));
    expect(find.text('View only'), findsOneWidget);
    expect(find.text('PC details'), findsNothing);
    // Agent apps the monitor reports are open apps to resume.
    await scrollTo(tester, find.text('Open apps'));
    expect(
      find.byKey(const ValueKey('resume-agent:claude-desktop')),
      findsOneWidget,
    );

    // CPU → System monitor: name and load once, above the main plot.
    await tester.drag(mainList, const Offset(0, 2000));
    await settle(tester, 4);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^CPU 42 percent, 61')));
    await settle(tester);
    expect(find.text('System monitor'), findsOneWidget);
    expect(find.text('Ryzen 7 7800X3D'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.byKey(const ValueKey('cpu-load-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('cpu-temp-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('processes-cpu')), findsOneWidget);
    // Peak includes the latest reading.
    expect(
      find.bySemanticsLabel(RegExp('CPU load history.*peak 49%')),
      findsOneWidget,
    );
    // Load and temperature plots share edges.
    final load = tester.getRect(find.byKey(const ValueKey('cpu-load-chart')));
    final temp = tester.getRect(find.byKey(const ValueKey('cpu-temp-chart')));
    expect(load.left, temp.left);
    expect(load.right, temp.right);
    expect(temp.top, greaterThan(load.bottom - 1));

    await tester.tap(find.text('GPU'));
    await settle(tester);
    expect(find.text('Radeon RX 9070'), findsOneWidget);
    expect(find.text('188 W of 317 W'), findsOneWidget);
    expect(find.text('HOTSPOT'), findsOneWidget);
    expect(find.text('Edge 52 °C · Memory 66 °C'), findsOneWidget);
    await scrollTo(
      tester,
      find.text('2.0 GB of 15.9 GB'),
      within: visibleList('monitor-gpu'),
    );
    expect(find.text('Used · 13%'), findsOneWidget);

    await tester.tap(find.text('Memory'));
    await settle(tester);
    expect(find.text('BREAKDOWN'), findsOneWidget);

    await tester.tap(find.text('Network & disk'));
    await settle(tester);
    for (final t in ['Download', 'Upload', 'Read', 'Write']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await scrollTo(
      tester,
      find.text('18.2 GB free of 232 GB'),
      within: visibleList('monitor-io'),
    );
    expect(find.text('Used'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);
    expect(find.text('Under 10 % free'), findsOneWidget);
    expect(find.text('NVMe 40 °C'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'thread grid on Desktop and CPU details selects and clears a logical CPU',
    (tester) async {
      await pumpPcTab(tester, FakeMonitor());
      expect(find.byKey(const ValueKey('cpu-thread-0')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('toggle-cpu-threads')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('cpu-thread-7')));
      await settle(tester);
      expect(
        find.bySemanticsLabel(
          RegExp('CPU load history, CPU 7, current 91 percent'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('cpu-thread-7')));
      await settle(tester);
      expect(
        find.bySemanticsLabel(RegExp('CPU load history, Total,')),
        findsOneWidget,
      );
      await tester.tap(find.bySemanticsLabel(RegExp('^CPU 42 percent,')));
      await settle(tester);
      expect(find.byKey(const ValueKey('cpu-thread-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('cpu-thread-15')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('cpu-thread-15')));
      await tester.tap(find.byKey(const ValueKey('cpu-thread-15')));
      await settle(tester);
      expect(
        find.bySemanticsLabel(
          RegExp('CPU load history, CPU 15, current 95 percent'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('from a CPU spike to the busiest process, inspected and ended '
      'behind the existing confirmation', (tester) async {
    final client = RpcClient('ws://127.0.0.1:1/rpc')
      ..capabilities = {
        'features': <String>['process.kill', 'monitor.v1'],
      };
    await pumpPcTab(tester, FakeMonitor(), client: client);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^CPU 42 percent')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('processes-cpu')));
    await settle(tester);
    expect(find.text('Processes by CPU'), findsOneWidget);
    final rows = find.byKey(const ValueKey('process-194463'));
    expect(rows, findsOneWidget);
    // Busiest first.
    expect(
      tester.getTopLeft(rows).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('process-17326'))).dy,
      ),
    );
    await tester.tap(find.text('claude-desktop (renderer)'));
    await settle(tester);
    expect(find.text('Process 194463 · busiest right now'), findsOneWidget);
    await tester.tap(find.text('End process'));
    await settle(tester);
    expect(find.text('End claude-desktop (renderer)?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a PC without GPU telemetry shows dashes and unavailable '
      'sensors', (tester) async {
    final json = snapshotJson();
    (json['vitals'] as Map)['gpus'] = <Object>[];
    ((json['vitals'] as Map)['cpu'] as Map).remove('tempC');
    await pumpPcTab(tester, FakeMonitor(json: json));
    expect(find.text('not reported'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2)); // GPU load, CPU temperature
    await tester.tap(find.bySemanticsLabel(RegExp(r'^GPU, not reported')));
    await settle(tester);
    expect(find.text('This PC doesn’t report GPU readings.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a GPU without power or temperature sensors keeps its load '
      'usable', (tester) async {
    final json = snapshotJson();
    final gpu = ((json['vitals'] as Map)['gpus'] as List).first as Map;
    for (final k in ['tempC', 'hotspotC', 'memTempC', 'powerW', 'powerCapW']) {
      gpu[k] = null;
    }
    final monitor = FakeMonitor(json: json);
    await pumpPcTab(tester, monitor);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^GPU 67 percent')));
    await settle(tester);
    expect(find.byKey(const ValueKey('gpu-load-chart')), findsOneWidget);
    // History still has temperature and power samples from earlier, so the
    // charts stay; the current readings say so.
    expect(find.text('Radeon RX 9070'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dropped connection keeps the readings and says when they '
      'were last updated', (tester) async {
    await pumpPcTab(
      tester,
      FakeMonitor(),
      connection: FakeConnection(status: RpcStatus.disconnected),
    );
    expect(find.text('Disconnected · updated just now'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('Open desktop'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^CPU 42 percent')));
    await settle(tester);
    expect(find.text('Disconnected · updated just now'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an older host gets the same destinations with the readings '
      'it has', (tester) async {
    await pumpPcTab(tester, FakeMonitor(empty: true));
    expect(find.text('Desktop'), findsOneWidget);
    expect(find.text('Apps'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('CPU'), findsOneWidget);
    expect(find.textContaining('Update NexusLink on the PC'), findsOneWidget);
    expect(find.text('Open desktop'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stuck app says so in Running and restarts from its own '
      'menu with confirmation and progress', (tester) async {
    final monitor = FakeMonitor()..pendingApp = Completer<String>();
    await pumpPcTab(tester, monitor);
    await openTab(tester, 'Running');

    final claude = find.byKey(const ValueKey('running-agent:claude-desktop'));
    expect(
      find.descendant(of: claude, matching: find.text('Not responding')),
      findsOneWidget,
    );
    await openMenu(tester, 'Claude');
    expect(find.text('App info'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('Quit'), findsOneWidget);
    expect(find.text('Force stop'), findsOneWidget);

    // Cancel does nothing.
    await tester.tap(find.text('Restart'));
    await settle(tester, 4);
    expect(find.text('Restart Claude?'), findsOneWidget);
    expect(find.textContaining('6 seconds'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester, 4);
    expect(monitor.calls, isEmpty);

    await openMenu(tester, 'Claude');
    await tester.tap(find.text('Restart'));
    await settle(tester, 4);
    await confirm(tester, 'Restart');
    expect(monitor.calls, ['app:claude-desktop:restart']);
    expect(
      find.descendant(of: claude, matching: find.text('Restarting Claude…')),
      findsOneWidget,
    );
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

  testWidgets('App info shows the frozen app\'s resource usage and restarts '
      'it', (tester) async {
    final monitor = FakeMonitor();
    await pumpPcTab(tester, monitor);
    await openTab(tester, 'Running');
    await openMenu(tester, 'Claude');
    await tester.tap(find.text('App info'));
    await settle(tester);
    expect(find.byKey(const ValueKey('app-info')), findsOneWidget);
    expect(find.text('Not responding'), findsOneWidget);
    expect(find.text('6.3%'), findsOneWidget);
    expect(find.text('2.9 GiB'), findsOneWidget);
    expect(find.text('31'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-info-restart')));
    await settle(tester, 4);
    await confirm(tester, 'Restart');
    expect(monitor.calls, ['app:claude-desktop:restart']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('force stop, terminal agents and starting an agent app from '
      'Apps', (tester) async {
    final monitor = FakeMonitor();
    await pumpPcTab(tester, monitor);
    await openTab(tester, 'Running');

    await openMenu(tester, 'Codex');
    await tester.tap(find.text('Force stop'));
    await settle(tester, 4);
    expect(find.text('Force stop Codex?'), findsOneWidget);
    await confirm(tester, 'Force stop');

    expect(find.text('In terminals'), findsOneWidget);
    final cli = find.byKey(const ValueKey('terminal-claude-code:31337'));
    expect(
      find.descendant(of: cli, matching: find.textContaining('pts/3')),
      findsOneWidget,
    );
    await openMenu(tester, 'Claude Code');
    await tester.tap(find.text('Stop'));
    await settle(tester, 4);
    expect(find.text('Stop Claude Code?'), findsOneWidget);
    await confirm(tester, 'Stop');

    await openTab(tester, 'Apps');
    await tester.enterText(find.byType(TextField), 'Curs');
    await settle(tester, 4);
    await tester.tap(find.text('Cursor'));
    await settle(tester, 4);

    expect(monitor.calls, [
      'app:codex-desktop:kill',
      'app:claude-code:31337:kill',
      'launch:cursor',
    ]);
  });

  testWidgets('Settings → This PC holds approvals and remote access; '
      'Restart RustDesk offers the one-time setup command', (tester) async {
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
    await tester.tap(find.byTooltip('More options'));
    await settle(tester, 4);
    await tester.tap(find.text('Settings'));
    await settle(tester);
    expect(find.byType(PcScreen), findsOneWidget);
    expect(find.text('THIS PC'), findsOneWidget);
    expect(find.byKey(const ValueKey('pc-approvals')), findsOneWidget);

    await scrollTo(
      tester,
      find.text('Restart RustDesk'),
      within: find
          .descendant(
            of: find.byType(PcScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('Auto-repaired 3 min ago'), findsOneWidget);
    await tester.tap(find.text('Restart RustDesk'));
    await settle(tester, 4);
    expect(find.text('Restart RustDesk?'), findsOneWidget);
    await confirm(tester, 'Restart');
    await settle(tester, 4);
    expect(monitor.calls, ['remote:rustdesk:restart']);
    expect(find.text('One-time RustDesk setup'), findsOneWidget);
    expect(find.text(rustdeskSetupCommand), findsOneWidget);
    await tester.tap(find.byTooltip('Copy command'));
    await settle(tester, 4);
    expect(copied, 'sudo bash packaging/rustdesk/install.sh');
  });

  testWidgets('destinations keep search and scroll', (tester) async {
    await pumpPcTab(tester, FakeMonitor());
    expect(find.byType(TextField), findsNothing);
    await openTab(tester, 'Apps');
    await tester.enterText(find.byType(TextField), 'Edi');
    await settle(tester, 4);
    expect(find.text('No matching apps on this PC.'), findsOneWidget);
    await openTab(tester, 'Running');
    expect(find.text('Claude'), findsOneWidget);
    await openTab(tester, 'Apps');
    expect(find.text('Edi'), findsOneWidget);
    await openTab(tester, 'Desktop');
    expect(find.text('obada-PC'), findsOneWidget);
    for (final label in ['Desktop', 'Apps', 'Running']) {
      final dest = find.ancestor(
        of: find.descendant(
          of: find.byKey(const ValueKey('desktop-nav')),
          matching: find.text(label),
        ),
        matching: find.byType(NavigationDestination),
      );
      expect(tester.getSize(dest).height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  for (final (size, scale) in const [
    (Size(320, 640), 1.3),
    (Size(360, 780), 2.0),
    (Size(412, 915), 2.0),
  ]) {
    testWidgets('no overflow at ${size.width.round()}×${size.height.round()} '
        'with $scale× text', (tester) async {
      await pumpPcTab(tester, FakeMonitor(), size: size, textScale: scale);
      expectClean(tester);
      // Secondary readings wrap under their metric at this size.
      expect(find.text('4.7 GHz'), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        await tester.drag(mainList, const Offset(0, -300));
        await settle(tester, 2);
        expectClean(tester);
      }
      await tester.fling(mainList, const Offset(0, 6000), 3000);
      await settle(tester, 8);
      await tester.tap(find.bySemanticsLabel(RegExp('^CPU 42 percent')));
      await settle(tester);
      for (final tab in ['CPU', 'GPU', 'Memory', 'Network & disk']) {
        final tabLabel = find.text(tab).last;
        await tester.ensureVisible(tabLabel);
        await settle(tester);
        await tester.tap(tabLabel);
        await settle(tester, 8);
        final list = find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .first;
        for (var i = 0; i < 6; i++) {
          await tester.drag(list, const Offset(0, -400));
          await settle(tester, 2);
          expectClean(tester, reason: tab);
        }
      }
      await tester.pageBack();
      await settle(tester, 8);
      for (final tab in ['Apps', 'Running']) {
        await openTab(tester, tab);
        expectClean(tester);
      }
      await openMenu(tester, 'Claude');
      expectClean(tester);
      await tester.tap(find.text('App info'));
      await settle(tester);
      expectClean(tester);
    });
  }

  testWidgets(
    'Disconnect in the header menu confirms, disconnects and returns to the '
    'connect screen',
    (tester) async {
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

      Future<void> menuDisconnect() async {
        await tester.tap(find.byTooltip('More options'));
        await settle(tester, 4);
        await tester.tap(find.text('Disconnect from PC'));
        await settle(tester, 4);
      }

      await menuDisconnect();
      expect(find.text('Disconnect from this PC?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester, 4);
      expect(connection.disconnected, isFalse);
      expect(find.byType(LauncherScreen), findsOneWidget);

      await menuDisconnect();
      await confirm(tester, 'Disconnect');
      await settle(tester);
      expect(connection.disconnected, isTrue);
      expect(find.byType(LauncherScreen), findsNothing);
      expect(find.text('Connect screen'), findsOneWidget);
    },
  );
}
