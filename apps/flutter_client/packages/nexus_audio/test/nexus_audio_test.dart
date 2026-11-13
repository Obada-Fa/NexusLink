import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_audio/nexus_audio.dart';

const pairing = AudioPairing(
  pcName: 'Desk',
  hosts: ['192.168.1.5', 'desk.local'],
  port: 8010,
  fingerprint: 'AB:CD',
  deviceId: 'dev1',
  token: 'secret',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    NexusAudio.debugReset();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(NexusAudio.methods, null);
    messenger.setMockStreamHandler(NexusAudio.events, null);
  });

  void mockMethods(Object? Function(MethodCall call) reply) {
    messenger.setMockMethodCallHandler(NexusAudio.methods, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  group('wire values', () {
    test('stream and phase names', () {
      expect(AudioStream.values.map((s) => s.wire), ['mic', 'playHere', 'sendDevice']);
      expect(StreamPhase.values.map((p) => p.wire), ['off', 'connecting', 'live', 'retrying']);
      expect(StreamPhase.fromWire('nonsense'), StreamPhase.off);
      expect(StreamPhase.fromWire(null), StreamPhase.off);
      expect(AudioStream.fromWire('speakers'), isNull);
    });

    test('pairing map has every field and toString hides the token', () {
      expect(pairing.toMap(), {
        'pcName': 'Desk',
        'hosts': ['192.168.1.5', 'desk.local'],
        'port': 8010,
        'fingerprint': 'AB:CD',
        'deviceId': 'dev1',
        'token': 'secret',
      });
      expect(pairing.toString(), isNot(contains('secret')));
    });
  });

  group('parsing tolerates missing fields', () {
    test('full state', () {
      final s = AudioEngineState.fromMap({
        'streams': {
          'mic': {'phase': 'live', 'detail': null},
          'playHere': {'phase': 'retrying', 'detail': 'Lost Desk (no answer). Retrying…'},
          'sendDevice': {'phase': 'off', 'detail': 'Phone audio sharing was not allowed.'},
        },
        'micLevel': 0.25,
      });
      expect(s[AudioStream.mic].phase, StreamPhase.live);
      expect(s[AudioStream.mic].on, isTrue);
      expect(s[AudioStream.playHere], const AudioStreamStatus(phase: StreamPhase.retrying, detail: 'Lost Desk (no answer). Retrying…'));
      expect(s[AudioStream.sendDevice].on, isFalse);
      expect(s[AudioStream.sendDevice].detail, 'Phone audio sharing was not allowed.');
      expect(s.micLevel, 0.25);
      expect(s.anyOn, isTrue);
    });

    test('missing and odd fields', () {
      for (final raw in <Object?>[null, 'x', 3, {}, {'streams': 'x', 'micLevel': 'loud'}]) {
        final s = AudioEngineState.fromMap(raw);
        for (final k in AudioStream.values) {
          expect(s[k].phase, StreamPhase.off, reason: '$raw');
        }
        expect(s.micLevel, 0.0);
      }
      final partial = AudioEngineState.fromMap({
        'streams': {
          'mic': {'phase': 'connecting'},
          'playHere': 'garbage',
        },
        'micLevel': 4,
      });
      expect(partial[AudioStream.mic], const AudioStreamStatus(phase: StreamPhase.connecting));
      expect(partial[AudioStream.playHere].phase, StreamPhase.off);
      expect(partial[AudioStream.sendDevice].phase, StreamPhase.off);
      expect(partial.micLevel, 1.0, reason: 'clamped');
    });

    test('notice', () {
      final n = AudioNotice.fromMap({'type': 'notice', 'stream': 'mic', 'message': 'Pair again.', 'pairAgain': true})!;
      expect(n.stream, AudioStream.mic);
      expect(n.message, 'Pair again.');
      expect(n.pairAgain, isTrue);
      expect(AudioNotice.fromMap({'stream': 'mic', 'message': 'x'})!.pairAgain, isFalse);
      expect(AudioNotice.fromMap({'stream': 'nope', 'message': 'x'}), isNull);
      expect(AudioNotice.fromMap({'stream': 'mic'}), isNull);
      expect(AudioNotice.fromMap(null), isNull);
    });
  });

  group('methods', () {
    test('start sends stream and pairing', () async {
      mockMethods((_) => null);
      await NexusAudio.start(AudioStream.playHere, pairing);
      expect(calls.single.method, 'start');
      expect(calls.single.arguments, {'stream': 'playHere', 'pairing': pairing.toMap()});
    });

    test('start errors surface as PlatformException with the plugin code', () async {
      for (final code in [AudioErrors.micPermission, AudioErrors.consentDenied, AudioErrors.unsupported, AudioErrors.badArgs]) {
        mockMethods((_) => throw PlatformException(code: code, message: 'nope'));
        await expectLater(
          NexusAudio.start(AudioStream.sendDevice, pairing),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
        );
      }
      expect(AudioErrors.micPermission, 'MIC_PERMISSION');
      expect(AudioErrors.consentDenied, 'CONSENT_DENIED');
      expect(AudioErrors.unsupported, 'UNSUPPORTED');
      expect(AudioErrors.badArgs, 'BAD_ARGS');
    });

    test('stop, stopAll, forgetWanted', () async {
      mockMethods((_) => null);
      await NexusAudio.stop(AudioStream.mic);
      await NexusAudio.stopAll();
      await NexusAudio.forgetWanted();
      expect(calls.map((c) => c.method), ['stop', 'stopAll', 'forgetWanted']);
      expect(calls.first.arguments, {'stream': 'mic'});
      expect(calls[1].arguments, isNull);
    });

    test('state parses the reply', () async {
      mockMethods((_) => {
            'streams': {
              'mic': {'phase': 'live', 'detail': null},
              'playHere': {'phase': 'off', 'detail': null},
              'sendDevice': {'phase': 'connecting', 'detail': 'Connecting to Desk…'},
            },
            'micLevel': 0.5,
          });
      final s = await NexusAudio.state();
      expect(calls.single.method, 'state');
      expect(s[AudioStream.mic].phase, StreamPhase.live);
      expect(s[AudioStream.sendDevice].detail, 'Connecting to Desk…');
      expect(s.micLevel, 0.5);
    });

    test('state tolerates a null reply', () async {
      mockMethods((_) => null);
      final s = await NexusAudio.state();
      expect(s.anyOn, isFalse);
    });

    test('restore returns the bool and defaults to false', () async {
      mockMethods((_) => true);
      expect(await NexusAudio.restore(pairing), isTrue);
      expect(calls.single.arguments, {'pairing': pairing.toMap()});
      mockMethods((_) => null);
      expect(await NexusAudio.restore(pairing), isFalse);
    });
  });

  group('events', () {
    late StreamController<Object?> platform;
    var listens = 0;

    setUp(() {
      listens = 0;
      platform = StreamController<Object?>.broadcast();
      messenger.setMockStreamHandler(
        NexusAudio.events,
        MockStreamHandler.inline(onListen: (args, sink) {
          listens++;
          platform.stream.listen(sink.success);
        }),
      );
    });

    tearDown(() => platform.close());

    Map<String, Object?> streamsEvent({String mic = 'off', String playHere = 'off', String? detail}) => {
          'type': 'streams',
          'streams': {
            'mic': {'phase': mic, 'detail': null},
            'playHere': {'phase': playHere, 'detail': detail},
            'sendDevice': {'phase': 'off', 'detail': null},
          },
        };

    test('stateStream folds streams and micLevel events', () async {
      final got = <AudioEngineState>[];
      final sub = NexusAudio.stateStream.listen(got.add);
      await pumpEventQueue();
      platform.add(streamsEvent(mic: 'live'));
      platform.add({'type': 'micLevel', 'level': 0.75});
      platform.add({'type': 'notice', 'stream': 'mic', 'message': 'ignored here', 'pairAgain': false});
      platform.add(streamsEvent(mic: 'live', playHere: 'retrying', detail: 'Lost Desk'));
      platform.add(streamsEvent()); // mic off: level resets
      await pumpEventQueue();
      await sub.cancel();

      expect(got, hasLength(4));
      expect(got[0][AudioStream.mic].phase, StreamPhase.live);
      expect(got[0].micLevel, 0.0);
      expect(got[1].micLevel, 0.75);
      expect(got[2][AudioStream.playHere], const AudioStreamStatus(phase: StreamPhase.retrying, detail: 'Lost Desk'));
      expect(got[2].micLevel, 0.75, reason: 'kept across a streams event while the mic is on');
      expect(got[3].anyOn, isFalse);
      expect(got[3].micLevel, 0.0);
    });

    test('notices only carries notice events; bad ones are dropped', () async {
      final got = <AudioNotice>[];
      final sub = NexusAudio.notices.listen(got.add);
      await pumpEventQueue();
      platform.add(streamsEvent(mic: 'live'));
      platform.add({'type': 'notice', 'stream': 'bogus', 'message': 'x'});
      platform.add({'type': 'notice', 'stream': 'playHere', 'message': 'Desk no longer accepts this phone. Pair again.', 'pairAgain': true});
      await pumpEventQueue();
      await sub.cancel();

      expect(got, hasLength(1));
      expect(got.single.stream, AudioStream.playHere);
      expect(got.single.pairAgain, isTrue);
    });

    test('stateStream and notices share one platform subscription', () async {
      final states = <AudioEngineState>[];
      final notices = <AudioNotice>[];
      final a = NexusAudio.stateStream.listen(states.add);
      final b = NexusAudio.notices.listen(notices.add);
      await pumpEventQueue();
      platform.add(streamsEvent(playHere: 'live'));
      platform.add({'type': 'notice', 'stream': 'mic', 'message': 'hi'});
      await pumpEventQueue();
      expect(listens, 1);
      expect(states.single[AudioStream.playHere].phase, StreamPhase.live);
      expect(notices.single.message, 'hi');
      await a.cancel();
      await b.cancel();
    });
  });
}
