// Walking-skeleton smoke test: the app builds and shows the connect screen.

import 'package:flutter/material.dart';
import 'package:nexuslink/src/state/saved_devices.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexuslink/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Connect screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: NexusLinkApp()));
    await tester.pumpAndSettle();
    expect(find.text('NexusLink'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('Connect screen suggests last connection', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'nexuslink-last-host-url': 'ws://192.168.2.30:45678/rpc',
    });
    await tester.pumpWidget(const ProviderScope(child: NexusLinkApp()));
    await tester.pumpAndSettle();
    expect(find.text('YOUR DEVICES'), findsOneWidget);
    expect(find.text('My PC'), findsOneWidget);
    expect(find.text('Tap to connect'), findsOneWidget);
    expect(find.text('Device address'), findsNothing);
    expect(find.text('Pairing code (first connection)'), findsNothing);
  });

  testWidgets('saved device name and icon can be edited and removed', (
    tester,
  ) async {
    await SavedDevices.save([
      const SavedDevice(url: 'ws://pc:45678/rpc', name: 'Office PC'),
    ]);
    await tester.pumpWidget(const ProviderScope(child: NexusLinkApp()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Office PC'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Work laptop');
    await tester.tap(find.byTooltip('laptop'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Work laptop'), findsOneWidget);
    final saved = await SavedDevices.load();
    expect(saved.single.name, 'Work laptop');
    expect(saved.single.icon, 'laptop');
    await tester.longPress(find.text('Work laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove saved device'));
    await tester.pumpAndSettle();
    expect(find.text('Work laptop'), findsNothing);
    expect(await SavedDevices.load(), isEmpty);
    expect(find.text('Device address'), findsOneWidget);
  });
}
