import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_audio/nexus_audio.dart';
import 'package:nexus_remote/nexus_remote.dart';
import 'package:nexuslink/src/modules/audio/audio_runtime.dart';
import 'package:nexuslink/src/modules/remote/remote_module.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/capabilities.dart';
import 'package:nexuslink/src/shell/home_media.dart';
import 'package:nexuslink/src/shell/module.dart';

import 'fakes.dart';

class MediaSession extends FakeRemoteSession {
  MediaSession(super.endpoint);
  final calls = <String>[];
  bool playing = true;
  bool stopped = false;
  Completer<Map<String, dynamic>>? heldPoll;

  @override
  Future<void> initialize() async {
    connected = true;
    mediaSupported = true;
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add(method);
    if (method == 'media.action') {
      if (params['action'] == 'play_pause') playing = !playing;
      return {};
    }
    if (method == 'volume.state') return {'percent': 50, 'muted': false};
    if (heldPoll != null) return heldPoll!.future;
    return {
      'players': [
        {
          'id': 'Player',
          'title': 'A song',
          'status': stopped ? 'Stopped' : (playing ? 'Playing' : 'Paused'),
        },
        if (!playing)
          {'id': 'Other', 'title': 'Another song', 'status': 'Playing'},
      ],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final target = hubTarget();
  late MediaSession session;
  setUp(() async {
    RemoteRuntime.debugReset();
    RemoteRuntime.debugSessionFactory = (endpoint, _) =>
        session = MediaSession(endpoint);
    await CredentialVault.write(target.id, UtilityIds.remote, 'token');
    await RemoteRuntime.switchTo(
      ModuleContext(
        target: target,
        capabilities: capabilitiesOf(target),
        reachable: const {UtilityIds.remote},
      ),
    );
  });
  tearDown(() async {
    AudioRuntime.view.value = const AudioView();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NexusAudio.methods, null);
    RemoteRuntime.debugReset();
    RemoteRuntime.debugSessionFactory = null;
    await CredentialVault.delete(target.id, UtilityIds.remote);
  });

  testWidgets(
    'shows the player, controls playback and polls only while visible',
    (tester) async {
      Widget app(bool visible) => MaterialApp(
        home: Scaffold(
          body: HomeMedia(
            targetId: target.id,
            visible: visible,
            onOpenMedia: () {},
          ),
        ),
      );
      await tester.pumpWidget(app(true));
      await tester.pump();
      expect(find.text('A song'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause playback'));
      await tester.pump();
      expect(session.calls, contains('media.action'));
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.text('A song'), findsOneWidget);
      expect(find.text('Another song'), findsNothing);
      final count = session.calls.length;
      await tester.pumpWidget(app(false));
      await tester.pump(const Duration(seconds: 10));
      expect(session.calls.length, count);
      expect(find.text('A song'), findsNothing);
    },
  );

  testWidgets('switching PCs discards the previous pending media response', (
    tester,
  ) async {
    Widget app(String targetId) => MaterialApp(
      home: Scaffold(
        body: HomeMedia(targetId: targetId, visible: true, onOpenMedia: () {}),
      ),
    );
    final held = Completer<Map<String, dynamic>>();
    session.heldPoll = held;
    await tester.pumpWidget(app(target.id));
    await tester.pumpWidget(app('other-pc'));
    held.complete({
      'players': [
        {'id': 'old', 'status': 'Playing', 'title': 'Previous PC'},
      ],
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('home-media')), findsNothing);
  });

  testWidgets('ignores stopped players', (tester) async {
    session.stopped = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeMedia(
            targetId: target.id,
            visible: true,
            onOpenMedia: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('home-media')), findsNothing);
  });

  testWidgets('refreshes after an action while a poll is in flight', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeMedia(
            targetId: target.id,
            visible: true,
            onOpenMedia: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    final held = Completer<Map<String, dynamic>>();
    session.heldPoll = held;
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byTooltip('Pause playback'));
    await tester.pump();
    session.heldPoll = null;
    held.complete({
      'players': [
        {'id': 'Player', 'title': 'A song', 'status': 'Playing'},
      ],
    });
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Play'), findsOneWidget);
  });

  testWidgets('stream stop works without a media session', (tester) async {
    await RemoteRuntime.switchTo(null);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NexusAudio.methods, (call) async {
          calls.add('${call.method}:${call.arguments['stream']}');
          return null;
        });
    AudioRuntime.view.value = AudioView(
      targetId: target.id,
      engine: const AudioEngineState(
        streams: {
          AudioStream.playHere: AudioStreamStatus(phase: StreamPhase.retrying),
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeMedia(
            targetId: target.id,
            visible: true,
            onOpenMedia: () {},
          ),
        ),
      ),
    );
    expect(find.text('PC audio here · Retrying…'), findsOneWidget);
    await tester.tap(find.text('Stop stream'));
    await tester.pump();
    expect(calls, contains('stop:playHere'));
  });

  testWidgets(
    'a media request opens the Media tab of an existing Remote screen',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteHomeScreen(
            session: session,
            mediaRequests: RemoteRuntime.mediaRequests,
          ),
        ),
      );
      expect(find.text('Controlling computer'), findsNothing);
      RemoteRuntime.openMedia();
      await tester.pump();
      await tester.pump();
      expect(find.text('Media player'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
