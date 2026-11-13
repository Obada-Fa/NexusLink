import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/nexus_remote.dart';
import 'package:nexus_remote/src/remote_pages.dart';

import 'test_endpoint.dart';

class _FakeSession extends RemoteSession {
  _FakeSession() : super(testEndpoint());
  final moves = <Offset>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> move(int dx, int dy) async => moves.add(Offset(dx.toDouble(), dy.toDouble()));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.record/messages'), (call) async => null);
  });
  testWidgets('RemoteHomeScreen renders disconnected inside a host theme', (tester) async {
    final session = _FakeSession();
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: RepaintBoundary(key: key, child: RemoteHomeScreen(session: session)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Test PC'), findsOneWidget);
    expect(find.text('Connect to control the computer'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Change IP / Host'), findsNothing);

    final out = Platform.environment['NEXUS_SHOT_DIR'];
    if (out != null) {
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/remote_home_disconnected.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
    session.dispose();
  });

  testWidgets('trackpad moves reach the session', (tester) async {
    final session = _FakeSession()..touchpadSensitivity = 2.0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Touchpad(session: session))));
    final g = await tester.startGesture(tester.getCenter(find.byType(Touchpad)));
    await tester.pump(const Duration(milliseconds: 10));
    await g.moveBy(const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await g.up();
    await tester.pumpAndSettle();
    expect(session.moves.map((m) => m.dx).reduce((a, b) => a + b), 20.0);
  });
}
