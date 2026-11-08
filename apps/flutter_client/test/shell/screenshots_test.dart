// Phone-size (412×915, dark) PNGs of the shell for review. Written to
// build/shell-screens/ (override with --dart-define=SHOT_DIR=/abs/path).
//
// The "Remote" tile here is a stand-in FakeModule: the real Remote module is
// added to the registry in wave 2.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/modules/agents/agents_module.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_registry.dart';
import 'package:nexuslink/src/shell/reachability.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/wake_config.dart';
import 'package:nexuslink/src/workspace/platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_connection.dart';
import 'fakes.dart';

const shotDir = String.fromEnvironment(
  'SHOT_DIR',
  defaultValue: 'build/shell-screens',
);
final _boundary = GlobalKey();

String? _materialFonts() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final candidates = [
    if (root != null) '$root/bin/cache/artifacts/material_fonts',
  ];
  // flutter_tester lives in <root>/bin/cache/artifacts/engine/<platform>/.
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 4; i++) {
    dir = dir.parent;
    candidates.add('${dir.path}/material_fonts');
    candidates.add('${dir.path}/artifacts/material_fonts');
  }
  for (final c in candidates) {
    if (File('$c/Roboto-Regular.ttf').existsSync()) return c;
  }
  return null;
}

Future<void> _loadFonts() async {
  final dir = _materialFonts();
  if (dir != null) {
    final roboto = FontLoader('Roboto');
    for (final w in ['Regular', 'Medium', 'Bold', 'Black']) {
      final bytes = File('$dir/Roboto-$w.ttf').readAsBytesSync();
      roboto.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await roboto.load();
  }
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  final render =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => render.toImage(pixelRatio: 2));
  final bytes = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  await tester.runAsync(() async {
    final file = File('$shotDir/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final standInRemote = FakeModule(
  id: 'remote',
  title: 'Remote',
  subtitle: 'Trackpad · Keyboard · Dictation',
  icon: Icons.touch_app_outlined,
  orderValue: 25,
);

Future<void> _pumpApp(
  WidgetTester tester, {
  required List<NexusModule> modules,
  required Set<int> openPorts,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        moduleListProvider.overrideWithValue(modules),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(
            connect: (_, port, _) async => openPorts.contains(port),
          ),
        ),
      ],
      child: RepaintBoundary(key: _boundary, child: const NexusApp()),
    ),
  );
  await _settle(tester);
}

void main() {
  const office = 'ws://100.64.0.5:45678/rpc';

  setUpAll(_loadFonts);

  setUp(() async {
    resetAutoConnect();
    FakeConnection.connects.clear();
    SharedPreferences.setMockInitialValues({});
    await PlatformBridge.saveCredential(office, 'secret');
  });

  tearDown(() {
    AgentsModule.liveStatusReader = null;
    PlatformBridge.removeCredential(office);
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412 * 2, 915 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  testWidgets('device picker', (tester) async {
    phone(tester);
    await TargetStore.save([
      hubTarget(),
      SavedTarget(
        id: 'legacy:ws://192.168.1.44:45678/rpc',
        name: 'Gaming rig',
        icon: 'gaming',
        wake: const WakeConfig(
          mac: 'AA:BB:CC:DD:EE:FF',
          broadcast: '192.168.1.255',
        ),
        utilities: {
          UtilityIds.nexuslink: link(
            UtilityIds.nexuslink,
            wsUrl: 'ws://192.168.1.44:45678/rpc',
          ),
        },
      ),
    ]);
    await _pumpApp(tester, modules: moduleRegistry, openPorts: {});
    expect(find.text('YOUR DEVICES'), findsOneWidget);
    await _shot(tester, '1-device-picker');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home grid, all tiles live', (tester) async {
    phone(tester);
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    await _pumpApp(
      tester,
      modules: moduleRegistry,
      openPorts: {45678, 45679, 8010},
    );
    expect(find.text('Offline'), findsNothing);
    expect(find.textContaining('Connected'), findsOneWidget);
    await _shot(tester, '2-home-all-live');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home grid, one utility offline', (tester) async {
    phone(tester);
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    await _pumpApp(
      tester,
      modules: [...moduleRegistry, standInRemote],
      openPorts: {45678, 8010},
    );
    expect(find.text('Offline'), findsOneWidget);
    await _shot(tester, '3-home-remote-offline');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live bar with two activities', (tester) async {
    phone(tester);
    AgentsModule.liveStatusReader = () async => {
      'monitoringRequested': true,
      'connectionState': 'connected',
      'bubbleRequested': true,
    };
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    final remote = FakeModule(
      id: 'remote',
      title: 'Remote',
      subtitle: 'Trackpad · Keyboard · Dictation',
      orderValue: 25,
      activities: liveOnce([
        LiveActivity(
          moduleId: 'remote',
          label: 'Trackpad connected · Office PC',
          icon: Icons.touch_app_outlined,
          onStop: () {},
        ),
      ]),
    );
    await _pumpApp(
      tester,
      modules: [...moduleRegistry, remote],
      openPorts: {45678, 45679, 8010},
    );
    expect(find.text('LIVE NOW · 2'), findsOneWidget);
    await _shot(tester, '4-live-bar-two');
    await tester.pumpWidget(const SizedBox());
  });
}
