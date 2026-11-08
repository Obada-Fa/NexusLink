import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/scan_pair_screen.dart';

const _channel = MethodChannel('flutter.baseflow.com/permissions/methods');
const _camera = 1; // Permission.camera.value
const _denied = 0, _permanentlyDenied = 4;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];

  void mockPermission(int status) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'checkPermissionStatus' => status,
            'requestPermissions' => {_camera: status},
            'openAppSettings' => true,
            _ => null,
          };
        });
  }

  setUp(calls.clear);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ScanPairScreen())),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('asks for the camera and explains a refusal', (tester) async {
    mockPermission(_denied);
    await open(tester);
    expect(
      calls,
      containsAllInOrder(['checkPermissionStatus', 'requestPermissions']),
    );
    expect(find.text('Allow the camera to scan'), findsOneWidget);
    calls.clear();
    await tester.tap(find.text('Allow camera'));
    await tester.pumpAndSettle();
    expect(calls, contains('requestPermissions'));
  });

  testWidgets('sends a blocked camera to Settings', (tester) async {
    mockPermission(_permanentlyDenied);
    await open(tester);
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(calls, contains('openAppSettings'));
  });

  testWidgets('"Type it instead" closes the scanner', (tester) async {
    mockPermission(_denied);
    await open(tester);
    await tester.tap(find.text('Type it instead'));
    await tester.pumpAndSettle();
    expect(find.byType(ScanPairScreen), findsNothing);
    expect(find.text('go'), findsOneWidget);
  });
}
