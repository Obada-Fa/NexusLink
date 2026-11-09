import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_audio/nexus_audio.dart';
import 'package:nexuslink/src/modules/audio/audio_messages.dart';
import 'package:nexuslink/src/modules/audio/audio_module.dart';
import 'package:nexuslink/src/modules/audio/audio_pairing.dart';
import 'package:nexuslink/src/modules/audio/audio_permissions.dart';
import 'package:nexuslink/src/modules/audio/audio_runtime.dart';
import 'package:nexuslink/src/modules/audio/audio_screen.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/capabilities.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_signals.dart';
import 'package:nexuslink/src/shell/tiles.dart';

import '../shell/fakes.dart';

class FakePermissions implements AudioPermissions {
  PermissionOutcome mic = PermissionOutcome.granted;
  PermissionOutcome notes = PermissionOutcome.granted;
  final asked = <String>[];

  @override
  Future<PermissionOutcome> microphone() async {
    asked.add('mic');
    return mic;
  }

  @override
  Future<PermissionOutcome> notifications() async {
    asked.add('notifications');
    return notes;
  }

  @override
  Future<bool> openSettings() async {
    asked.add('settings');
    return true;
  }
}

ModuleContext ctxOf(SavedTarget t) => ModuleContext(
  target: t,
  capabilities: capabilitiesOf(t),
  reachable: const {UtilityIds.audio},
);

Map<String, Object?> streamsEvent({
  String mic = 'off',
  String? micDetail,
  String playHere = 'off',
  String? playHereDetail,
  String sendDevice = 'off',
  String? sendDeviceDetail,
}) => {
  'type': 'streams',
  'streams': {
    'mic': {'phase': mic, 'detail': micDetail},
    'playHere': {'phase': playHere, 'detail': playHereDetail},
    'sendDevice': {'phase': sendDevice, 'detail': sendDeviceDetail},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late StreamController<Object?> platform;
  late FakePermissions perms;
  Object? Function(MethodCall call)? failWith;

  final office = hubTarget();
  const token = 'audio-token';

  setUp(() async {
    calls.clear();
    failWith = null;
    AudioRuntime.debugReset();
    NexusAudio.debugReset();
    AudioRuntime.debugEngineAvailable = true;
    perms = FakePermissions();
    AudioRuntime.permissions = perms;
    platform = StreamController<Object?>.broadcast();
    messenger.setMockMethodCallHandler(NexusAudio.methods, (call) async {
      calls.add(call);
      final fail = failWith?.call(call);
      if (fail is PlatformException) throw fail;
      return switch (call.method) {
        'state' => {'streams': <String, Object?>{}, 'micLevel': 0.0},
        'restore' => false,
        _ => null,
      };
    });
    messenger.setMockStreamHandler(
      NexusAudio.events,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          platform.stream.listen(sink.success);
        },
      ),
    );
    await CredentialVault.write(office.id, UtilityIds.audio, token);
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  tearDown(() async {
    AudioRuntime.debugReset();
    AudioRuntime.debugEngineAvailable = null;
    NexusAudio.debugReset();
    messenger.setMockMethodCallHandler(NexusAudio.methods, null);
    messenger.setMockStreamHandler(NexusAudio.events, null);
    await platform.close();
    await CredentialVault.delete(office.id, UtilityIds.audio);
  });

  List<String> methods() => [for (final c in calls) c.method];

  group('pairing from a saved target', () {
    test('hosts: preferred first, then Tailscale and LAN, de-duplicated', () {
      final t = office.copyWith(
        addresses: const TargetAddresses(
          tailscale: '100.64.0.5',
          lan: ['192.168.1.20', '100.64.0.5', ' '],
        ),
        utilities: {
          UtilityIds.audio: UtilityLink(
            utility: UtilityIds.audio,
            port: 8010,
            preferredHost: '192.168.1.20',
            fingerprint: testFingerprint,
            deviceId: 'phone-1',
            pairedAt: DateTime.utc(2026, 11, 8),
          ),
        },
      );
      final r = resolveAudioPairing(t, token);
      expect(r.problem, isNull);
      final p = r.pairing!;
      expect(p.hosts, ['192.168.1.20', '100.64.0.5']);
      expect(p.toMap(), {
        'pcName': 'Office PC',
        'hosts': ['192.168.1.20', '100.64.0.5'],
        'port': 8010,
        'fingerprint': testFingerprint,
        'deviceId': 'phone-1',
        'token': token,
      });
    });

    test('missing pieces give a plain-words problem', () {
      expect(
        resolveAudioPairing(office, null).problem,
        'This phone has lost its Audio key for Office PC. Pair again.',
      );
      expect(resolveAudioPairing(office, '').pairing, isNull);
      final noDevice = office.copyWith(
        utilities: {
          UtilityIds.audio: UtilityLink(
            utility: UtilityIds.audio,
            port: 8010,
            fingerprint: testFingerprint,
            pairedAt: DateTime.utc(2026, 11, 8),
          ),
        },
      );
      expect(
        resolveAudioPairing(noDevice, token).problem,
        contains('incomplete'),
      );
      final noAddress = office.copyWith(
        addresses: const TargetAddresses(),
        utilities: {
          UtilityIds.audio: UtilityLink(
            utility: UtilityIds.audio,
            port: 8010,
            fingerprint: testFingerprint,
            deviceId: 'phone-1',
            pairedAt: DateTime.utc(2026, 11, 8),
          ),
        },
      );
      expect(
        resolveAudioPairing(noAddress, token).problem,
        contains('No address'),
      );
      expect(
        resolveAudioPairing(hubTarget(utilities: {UtilityIds.nexuslink}), token)
            .problem,
        contains('isn’t paired'),
      );
    });

    testWidgets('missing secret: tile offline with the reason, no engine call', (
      tester,
    ) async {
      await CredentialVault.delete(office.id, UtilityIds.audio);
      const module = AudioModule();
      final ctx = ctxOf(office);
      await module.onTargetChanged(ctx);
      expect(module.blockedReason(ctx), contains('lost its Audio key'));
      expect(methods(), isNot(contains('restore')));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 156,
              child: ModuleTile(
                tile: const HomeTile(module, TileStatus.ready),
                ctx: ctx,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byKey(const ValueKey('tile-blocked-audio')), findsOneWidget);
    });
  });

  group('target lifecycle', () {
    test('entering restores with the pairing; leaving stops all', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      final restore = calls.firstWhere((c) => c.method == 'restore');
      final pairing = (restore.arguments as Map)['pairing'] as Map;
      expect(pairing['token'], token);
      expect(pairing['hosts'], ['100.64.0.5', '192.168.1.20']);
      expect(pairing['deviceId'], 'phone-1');
      calls.clear();
      await AudioRuntime.switchTo(null);
      expect(methods(), ['stopAll']);
    });

    test('in the background, restore waits for the app to be visible', () async {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await AudioRuntime.switchTo(ctxOf(office));
      expect(methods(), isNot(contains('restore')));
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await Future<void>.delayed(Duration.zero);
      expect(methods().where((m) => m == 'restore'), hasLength(1));
      // Only once: a later resume doesn't restart streams the user stopped.
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await Future<void>.delayed(Duration.zero);
      expect(methods().where((m) => m == 'restore'), hasLength(1));
    });

    test('removing the bound target stops its streams and forgets them', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      calls.clear();
      await const AudioModule().onTargetRemoved(office);
      expect(methods(), containsAllInOrder(['stopAll', 'forgetWanted']));
      expect(AudioRuntime.view.value.targetId, isNull);
    });

    test('removing another target leaves the running one alone', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      calls.clear();
      await AudioRuntime.targetRemoved(hubTarget(id: 'hub-tv', name: 'TV'));
      expect(calls, isEmpty);
      await AudioRuntime.targetRemoved(
        hubTarget(id: 'hub-x', utilities: {UtilityIds.nexuslink}),
      );
      expect(calls, isEmpty);
    });
  });

  group('toggles', () {
    test('mic on asks permissions then starts; off stops', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      calls.clear();
      await AudioRuntime.setStream(AudioStream.mic, true);
      expect(perms.asked, ['mic', 'notifications']);
      final start = calls.singleWhere((c) => c.method == 'start');
      expect((start.arguments as Map)['stream'], 'mic');
      expect(((start.arguments as Map)['pairing'] as Map)['token'], token);
      expect(AudioRuntime.view.value.isOn(AudioStream.mic), isTrue);
      calls.clear();
      await AudioRuntime.setStream(AudioStream.mic, false);
      expect(calls.single.method, 'stop');
      expect((calls.single.arguments as Map)['stream'], 'mic');
    });

    test('PC audio here needs no microphone permission', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      await AudioRuntime.setStream(AudioStream.playHere, true);
      expect(perms.asked, ['notifications']);
      expect(methods(), contains('start'));
    });

    test('a refused microphone explains itself and starts nothing', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      perms.mic = PermissionOutcome.denied;
      await AudioRuntime.setStream(AudioStream.sendDevice, true);
      expect(methods(), isNot(contains('start')));
      var p = AudioRuntime.view.value.problem!;
      expect(p.message, micRefusedMessage(AudioStream.sendDevice, permanently: false));
      expect(p.openSettings, isFalse);
      expect(AudioRuntime.view.value.isOn(AudioStream.sendDevice), isFalse);

      perms.mic = PermissionOutcome.permanentlyDenied;
      await AudioRuntime.setStream(AudioStream.mic, true);
      p = AudioRuntime.view.value.problem!;
      expect(p.openSettings, isTrue);
      expect(p.message, contains('Settings'));
      await AudioRuntime.openSettings();
      expect(perms.asked.last, 'settings');
    });

    test('refused notifications are explained once, the stream still starts', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      perms.notes = PermissionOutcome.denied;
      final messages = <String>[];
      final sub = AudioRuntime.messages.listen(messages.add);
      await AudioRuntime.setStream(AudioStream.playHere, true);
      await AudioRuntime.setStream(AudioStream.mic, true);
      await Future<void>.delayed(Duration.zero);
      expect(messages, [notificationsRefusedMessage]);
      expect(methods().where((m) => m == 'start'), hasLength(2));
      await sub.cancel();
    });

    for (final code in [
      AudioErrors.micPermission,
      AudioErrors.consentDenied,
      AudioErrors.unsupported,
      AudioErrors.badArgs,
    ]) {
      test('start error $code becomes a clear message', () async {
        await AudioRuntime.switchTo(ctxOf(office));
        failWith = (call) => call.method == 'start'
            ? PlatformException(code: code, message: 'raw')
            : null;
        await AudioRuntime.setStream(AudioStream.sendDevice, true);
        final p = AudioRuntime.view.value.problem!;
        final expected = audioStartError(
          AudioStream.sendDevice,
          PlatformException(code: code),
        );
        expect(p.message, expected.message);
        expect(p.message, isNot(contains('raw')));
        expect(p.openSettings, code == AudioErrors.micPermission);
        expect(p.pairAgain, code == AudioErrors.badArgs);
        expect(AudioRuntime.view.value.isOn(AudioStream.sendDevice), isFalse);
      });
    }

    test('error messages say what to do', () {
      String m(String code) => audioStartError(
        AudioStream.sendDevice,
        PlatformException(code: code),
      ).message;
      expect(m(AudioErrors.micPermission), contains('Allow Microphone'));
      expect(m(AudioErrors.consentDenied), contains('Start now'));
      expect(m(AudioErrors.unsupported), contains('Android 10'));
      expect(m(AudioErrors.badArgs), contains('pair again'));
      expect(m('WHATEVER'), contains('Couldn’t start'));
    });
  });

  group('engine events', () {
    test('sticky details: a null detail while retrying keeps the last one', () {
      final retrying = AudioEngineState.fromMap({
        'streams': {
          'playHere': {'phase': 'retrying', 'detail': null},
          'mic': {'phase': 'live', 'detail': null},
        },
      });
      final kept = mergeDetails({
        AudioStream.playHere: 'Lost Office PC. Retrying…',
        AudioStream.mic: 'Connecting…',
      }, retrying);
      expect(kept[AudioStream.playHere], 'Lost Office PC. Retrying…');
      expect(kept.containsKey(AudioStream.mic), isFalse, reason: 'live clears');
    });

    testWidgets('state events drive the phases on screen', (tester) async {
      await tester.runAsync(() => AudioRuntime.switchTo(ctxOf(office)));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: AudioScreen(ctx: ctxOf(office))),
        ),
      );
      expect(find.text('Live'), findsNothing);
      Future<void> send(Object? e) => tester.runAsync(() async {
        platform.add(e);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      });
      await send(
        streamsEvent(
          mic: 'live',
          micDetail: '44.1 kHz · mono',
          playHere: 'retrying',
          playHereDetail: 'Lost Office PC. Retrying…',
          sendDevice: 'connecting',
        ),
      );
      await send({'type': 'micLevel', 'level': 0.5});
      await tester.pump();
      await tester.pump();
      Text pill(String s) => tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('audio-phase-$s')),
          matching: find.byType(Text),
        ),
      );
      expect(pill('mic').data, 'Live');
      expect(pill('playHere').data, 'Retrying');
      expect(pill('sendDevice').data, 'Connecting');
      expect(find.text('Lost Office PC. Retrying…'), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-mic-meter')), findsOneWidget);
      expect(AudioRuntime.view.value.engine.micLevel, 0.5);
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('audio-switch-mic')))
            .value,
        isTrue,
      );

      // Between retries the detail is null: the text stays.
      await send(streamsEvent(mic: 'live', playHere: 'retrying'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Lost Office PC. Retrying…'), findsOneWidget);

      // Everything off: no meter, switches off.
      await send(streamsEvent());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('audio-mic-meter')), findsNothing);
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('audio-switch-mic')))
            .value,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping a switch starts the stream', (tester) async {
      await tester.runAsync(() => AudioRuntime.switchTo(ctxOf(office)));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: AudioScreen(ctx: ctxOf(office))),
        ),
      );
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('audio-switch-playHere')));
      await tester.pump();
      await tester.pump();
      expect(methods(), contains('start'));
      // Pending start reads as connecting until the engine answers.
      expect(find.text('Connecting'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused permission shows an Open settings action', (
      tester,
    ) async {
      await tester.runAsync(() => AudioRuntime.switchTo(ctxOf(office)));
      perms.mic = PermissionOutcome.permanentlyDenied;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: AudioScreen(ctx: ctxOf(office))),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('audio-switch-mic')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('audio-problem')), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pump();
      expect(perms.asked.last, 'settings');
      await tester.pumpWidget(const SizedBox());
    });

    test('a pair-again notice reaches the shell', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      final requests = <PairAgainRequest>[];
      final messages = <String>[];
      final s1 = ModuleSignals.pairAgain.listen(requests.add);
      final s2 = AudioRuntime.messages.listen(messages.add);
      platform.add({
        'type': 'notice',
        'stream': 'mic',
        'message': 'Office PC no longer accepts this phone. Pair again.',
        'pairAgain': true,
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(requests.single.targetId, office.id);
      expect(requests.single.utility, UtilityIds.audio);
      expect(AudioRuntime.view.value.pairAgain, isTrue);
      expect(messages.single, contains('Pair again'));
      await s1.cancel();
      await s2.cancel();
    });

    test('live activities: one per stream that is on, each with stop', () async {
      await AudioRuntime.switchTo(ctxOf(office));
      final seen = <List<LiveActivity>>[];
      final sub = const AudioModule()
          .liveActivities(ctxOf(office))!
          .listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      expect(seen.single, isEmpty, reason: 'current list on listen');
      platform.add(streamsEvent(mic: 'live', playHere: 'retrying'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final last = seen.last;
      expect(last.map((a) => a.label), [
        'Phone mic to Office PC',
        'Office PC audio here · reconnecting',
      ]);
      expect(last.every((a) => a.moduleId == 'audio'), isTrue);
      calls.clear();
      last.first.onStop!();
      await Future<void>.delayed(Duration.zero);
      expect(calls.single.method, 'stop');
      expect((calls.single.arguments as Map)['stream'], 'mic');
      await sub.cancel();
    });

    testWidgets('tile dots show running streams', (tester) async {
      AudioRuntime.debugEngine(
        AudioEngineState.fromMap({
          'streams': {
            'mic': {'phase': 'live'},
            'sendDevice': {'phase': 'connecting'},
          },
        }),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AudioTileDots())),
      );
      expect(find.text('Mic'), findsOneWidget);
      expect(find.text('Phone audio'), findsOneWidget);
      expect(find.text('PC audio'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
