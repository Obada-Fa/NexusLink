// Phone-size (412×915, dark) PNGs of the shell for review. Written to
// build/shell-screens/ (override with --dart-define=SHOT_DIR=/abs/path).
//
// Remote and Audio are the real modules; the Remote session is a fake (no
// sqlite, no network) and the audio engine is fed states directly.

import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_audio/nexus_audio.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/modules/agents/agents_module.dart';
import 'package:nexuslink/src/modules/audio/audio_runtime.dart';
import 'package:nexuslink/src/modules/remote/remote_module.dart';
import 'package:nexuslink/src/pc/app_actions.dart';
import 'package:nexuslink/src/screens/mirror_screen.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_registry.dart';
import 'package:nexuslink/src/shell/reachability.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/shell/shell_navigator.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/wake_config.dart';
import 'package:nexuslink/src/workspace/platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/launcher.dart';
import 'package:nexuslink/src/state/connection.dart' as conn;

import '../pc_tab_test.dart' show FixedApps, FixedWindows, NoSessions;
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

/// Stores the Remote and Audio tokens the real modules read from the vault.
Future<void> _storeSecrets(String targetId) async {
  await CredentialVault.write(targetId, UtilityIds.remote, 'remote-token');
  await CredentialVault.write(targetId, UtilityIds.audio, 'audio-token');
}

AudioEngineState _engine({
  StreamPhase mic = StreamPhase.off,
  String? micDetail,
  StreamPhase playHere = StreamPhase.off,
  String? playHereDetail,
  StreamPhase sendDevice = StreamPhase.off,
  String? sendDeviceDetail,
  double level = 0,
}) => AudioEngineState(
  streams: {
    AudioStream.mic: AudioStreamStatus(phase: mic, detail: micDetail),
    AudioStream.playHere: AudioStreamStatus(
      phase: playHere,
      detail: playHereDetail,
    ),
    AudioStream.sendDevice: AudioStreamStatus(
      phase: sendDevice,
      detail: sendDeviceDetail,
    ),
  },
  micLevel: level,
);

// A paired host with a media session and installed applications for the
// phone previews. All three modules still go through their normal entry points.
class _PreviewRemote extends FakeRemoteSession {
  _PreviewRemote(super.endpoint, {required super.onUnauthorized});
  bool playing = true;

  @override
  Future<void> initialize() async {
    mediaSupported = true;
    await super.initialize();
  }

  @override
  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'media.action') {
      if (params['action'] == 'play_pause') playing = !playing;
      return {};
    }
    if (method == 'volume.state') return {'percent': 50, 'muted': false};
    return method == 'media.list'
        ? {
            'players': [
              {
                'id': 'Music',
                'title': 'Teardrop',
                'status': playing ? 'Playing' : 'Paused',
              },
            ],
          }
        : {};
  }
}

class _PreviewConnection extends FakeConnection {
  @override
  Future<void> connect(String wsUrl, {String? pairingCode}) async {
    await super.connect(wsUrl, pairingCode: pairingCode);
    final client = RpcClient(wsUrl)
      ..capabilities = {
        'methods': ['apps.list'],
      };
    state = conn.ConnectionState(
      client: client,
      status: RpcStatus.connected,
      hostUrl: wsUrl,
    );
    ref.onDispose(client.dispose);
  }
}

AppInfo _previewApp(String id, String name) {
  final dir = Platform.environment['CAPTURE_ICON_DIR'];
  final icon = File('$dir/$id.png');
  return AppInfo(
    appId: id,
    name: name,
    icon: dir != null && icon.existsSync()
        ? 'data:image/png;base64,${base64Encode(icon.readAsBytesSync())}'
        : null,
  );
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required List<NexusModule> modules,
  required Set<int> openPorts,
  bool withDock = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (withDock) ...[
          connectionProvider.overrideWith(_PreviewConnection.new),
          appsProvider.overrideWith(
            () => FixedApps([
              _previewApp('firefox', 'Firefox'),
              _previewApp('code', 'Code'),
            ]),
          ),
          windowsProvider.overrideWith(
            () => FixedWindows([
              WindowInfo(
                windowId: 'firefox-window',
                title: 'Firefox window',
                wmClass: 'firefox',
                desktop: 0,
                appId: 'firefox',
              ),
            ]),
          ),
          appSessionsProvider.overrideWith(NoSessions.new),
        ] else
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

  tearDown(() async {
    AgentsModule.liveStatusReader = null;
    PlatformBridge.removeCredential(office);
    RemoteRuntime.debugReset();
    RemoteRuntime.debugSessionFactory = null;
    AudioRuntime.debugReset();
    debugViewerBuilder = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NexusAudio.methods, null);
    await CredentialVault.delete('hub-office', UtilityIds.remote);
    await CredentialVault.delete('hub-office', UtilityIds.audio);
  });

  void fakeRemote({bool connect = false}) {
    RemoteRuntime.debugSessionFactory = (endpoint, onUnauthorized) =>
        FakeRemoteSession(
          endpoint,
          onUnauthorized: onUnauthorized,
          connectOnInit: connect,
        );
  }

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

  for (final playing in [false, true]) {
    testWidgets(
      'pocket launcher preview, media ${playing ? "playing" : "idle"}',
      (tester) async {
        phone(tester);
        if (playing) {
          RemoteRuntime.debugSessionFactory = (endpoint, onUnauthorized) =>
              _PreviewRemote(endpoint, onUnauthorized: onUnauthorized);
        } else {
          fakeRemote();
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'nexuslink-launcher:$office',
          jsonEncode({
            'favourites': ['firefox', 'code'],
            'usage': {},
          }),
        );
        await _storeSecrets('hub-office');
        await TargetStore.save([hubTarget(name: 'Studio PC')]);
        await TargetStore.setCurrent('hub-office');
        await _pumpApp(
          tester,
          modules: moduleRegistry,
          openPorts: {45678, 45679, 8010},
          withDock: true,
        );
        final viewed = <MirrorTarget>[];
        final audioCalls = <String>[];
        if (playing) {
          debugViewerBuilder = (target) {
            viewed.add(target);
            return Scaffold(appBar: AppBar(title: const Text('Viewer stub')));
          };
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(NexusAudio.methods, (call) async {
                audioCalls.add(call.method);
                if (call.method == 'stop') AudioRuntime.debugEngine(_engine());
                return null;
              });
          AudioRuntime.debugEngine(_engine(playHere: StreamPhase.live));
          await tester.pump();
        }
        expect(find.byKey(const ValueKey('dock-app-firefox')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('home-favourite-code')),
          findsOneWidget,
        );
        final images = tester.widgetList<Image>(find.byType(Image)).toList();
        final context = tester.element(find.byType(Scaffold).first);
        await tester.runAsync(
          () => Future.wait([
            for (final image in images) precacheImage(image.image, context),
          ]),
        );
        await tester.pump();
        expect(find.text('Teardrop'), playing ? findsOneWidget : findsNothing);
        final first = tester.getCenter(
          find.byKey(const ValueKey('tile-desktop')),
        );
        final audio = tester.getCenter(
          find.byKey(const ValueKey('tile-audio')),
        );
        final files = tester.getCenter(
          find.byKey(const ValueKey('tile-files')),
        );
        expect(first.dy, audio.dy);
        expect(files.dx, audio.dx);
        expect(files.dy, greaterThan(audio.dy));
        await _shot(tester, playing ? 'home-media' : 'home-idle');
        if (playing) {
          expect(find.text('Stop stream'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('dock-app-firefox')));
          await _settle(tester);
          expect(find.text('Viewer stub'), findsOneWidget);
          expect(viewed.last.windowId, 'firefox-window');
          await tester.binding.handlePopRoute();
          await _settle(tester);

          await tester.tap(find.byTooltip('Pause playback'));
          await tester.pump();
          expect(find.byTooltip('Play'), findsOneWidget);
          await tester.tap(find.byTooltip('Play'));
          await tester.pump();
          expect(find.byTooltip('Pause playback'), findsOneWidget);
          await tester.tap(find.text('Stop stream'));
          await tester.pump();
          expect(audioCalls, contains('stop'));
          expect(find.text('Stop stream'), findsNothing);

          await tester.tap(find.byKey(const ValueKey('dock-app-firefox')));
          await _settle(tester);
          expect(find.text('Viewer stub'), findsOneWidget);
          expect(viewed.last.windowId, 'firefox-window');
          await tester.binding.handlePopRoute();
          await _settle(tester);
          // Dismiss Running if it remains underneath the viewer.
          if (find.text('Running').evaluate().isNotEmpty) {
            await tester.binding.handlePopRoute();
            await _settle(tester);
          }
          await tester.ensureVisible(find.text('Teardrop'));
          await tester.tap(find.text('Teardrop'));
          await _settle(tester);
          expect(find.text('Media player'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('home grid, all six tools ready', (tester) async {
    phone(tester);
    fakeRemote();
    await _storeSecrets('hub-office');
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    await _pumpApp(
      tester,
      modules: moduleRegistry,
      openPorts: {45678, 45679, 8010},
    );
    expect(find.text('Offline'), findsNothing);
    expect(find.textContaining('Connected'), findsOneWidget);
    for (final id in [
      'desktop',
      'files',
      'agents',
      'terminal',
      'remote',
      'audio',
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('tile-$id')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await _settle(tester);
    await _shot(tester, '2-home-all-live');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home grid, one utility offline', (tester) async {
    phone(tester);
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    fakeRemote();
    await _storeSecrets('hub-office');
    await _pumpApp(tester, modules: moduleRegistry, openPorts: {45678, 8010});
    expect(find.text('Offline'), findsOneWidget);
    await _shot(tester, '3-home-remote-offline');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live bar with audio and remote', (tester) async {
    phone(tester);
    AgentsModule.liveStatusReader = () async => {
      'monitoringRequested': true,
      'connectionState': 'connected',
      'bubbleRequested': true,
    };
    fakeRemote(connect: true);
    await _storeSecrets('hub-office');
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    await _pumpApp(
      tester,
      modules: moduleRegistry,
      openPorts: {45678, 45679, 8010},
    );
    AudioRuntime.debugEngine(
      _engine(
        mic: StreamPhase.live,
        micDetail: '44.1 kHz · mono',
        playHere: StreamPhase.retrying,
        playHereDetail: 'Lost Office PC. Retrying…',
        level: .4,
      ),
    );
    await _settle(tester);
    expect(find.text('Remote: Office PC'), findsOneWidget);
    expect(find.text('Phone mic to Office PC'), findsOneWidget);
    expect(find.text('LIVE NOW · 3'), findsOneWidget);
    expect(find.text('PC audio here · Retrying…'), findsOneWidget);
    await _shot(tester, '4-live-bar-audio-remote');
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> openAudio(WidgetTester tester) async {
    fakeRemote();
    await _storeSecrets('hub-office');
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    await _pumpApp(
      tester,
      modules: moduleRegistry,
      openPorts: {45678, 45679, 8010},
    );
    ShellNavigator.instance.openModule('audio');
    await _settle(tester);
    expect(find.byKey(const ValueKey('audio-screen')), findsOneWidget);
  }

  testWidgets('audio screen, mic live with the meter moving', (tester) async {
    phone(tester);
    await openAudio(tester);
    for (final level in [.1, .5, .3, .62]) {
      AudioRuntime.debugEngine(
        _engine(
          mic: StreamPhase.live,
          micDetail: 'Live on Office PC · 44.1 kHz mono',
          playHere: StreamPhase.live,
          playHereDetail: '48 kHz · stereo',
          level: level,
        ),
      );
      await tester.pump(const Duration(milliseconds: 70));
    }
    await _settle(tester);
    expect(find.byKey(const ValueKey('audio-mic-meter')), findsOneWidget);
    await _shot(tester, '5-audio-mic-live');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('audio screen, a stream retrying', (tester) async {
    phone(tester);
    await openAudio(tester);
    AudioRuntime.debugEngine(
      _engine(
        mic: StreamPhase.live,
        micDetail: 'Live on Office PC · 44.1 kHz mono',
        playHere: StreamPhase.retrying,
        playHereDetail: 'Lost Office PC (no answer). Retrying in 4 s…',
        sendDevice: StreamPhase.off,
        sendDeviceDetail: 'Phone audio sharing was not allowed.',
        level: .22,
      ),
    );
    await tester.pump();
    // Between retries the engine sends a null detail: the text must stay.
    AudioRuntime.debugEngine(
      _engine(
        mic: StreamPhase.live,
        micDetail: 'Live on Office PC · 44.1 kHz mono',
        playHere: StreamPhase.retrying,
        sendDevice: StreamPhase.off,
        sendDeviceDetail: 'Phone audio sharing was not allowed.',
        level: .22,
      ),
    );
    await _settle(tester);
    expect(
      find.text('Lost Office PC (no answer). Retrying in 4 s…'),
      findsOneWidget,
    );
    await _shot(tester, '6-audio-retrying');
    await tester.pumpWidget(const SizedBox());
  });
}
