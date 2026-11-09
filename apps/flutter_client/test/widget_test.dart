// Smoke tests for the shell: first run shows the device picker, a migrated
// PC opens on the home grid, and saved devices can be edited and removed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/state/saved_devices.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetAutoConnectForTest();
  });

  testWidgets('first run shows the device picker', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: NexusApp()));
    await tester.pumpAndSettle();
    expect(find.text('Nexus'), findsOneWidget);
    expect(find.text('Connect your computer'), findsOneWidget);
    expect(find.text('Scan QR code'), findsOneWidget);
    // Wi-Fi discovery and the typed address wait under "Other ways".
    expect(find.text('PC address'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('other-ways')));
    await tester.pumpAndSettle();
    expect(find.text('Find a PC on this Wi-Fi'), findsOneWidget);
    expect(find.text('PC address'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Connect'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('last connection opens straight on the home grid', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'nexuslink-last-host-url': 'ws://192.168.2.30:45678/rpc',
    });
    await tester.pumpWidget(const ProviderScope(child: NexusApp()));
    await tester.pumpAndSettle();
    expect(find.text('My PC'), findsOneWidget);
    expect(find.text('WORKSPACE'), findsOneWidget);
    expect(find.text('Agents'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    // Not paired on this phone, so no auto-connect: the PC reads offline and
    // Home offers to reconnect.
    expect(find.text('My PC is offline'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Desktop'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PC TOOLS'), findsOneWidget);
    expect(find.text('Offline'), findsWidgets);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pc-selector')));
    await tester.pumpAndSettle();
    expect(find.text('YOUR DEVICES'), findsOneWidget);
    expect(find.text('Tap to open'), findsOneWidget);
    expect(find.text('PC address'), findsNothing);
  });

  testWidgets('saved device name and icon can be edited and removed', (
    tester,
  ) async {
    await SavedDevices.save([
      const SavedDevice(url: 'ws://pc:45678/rpc', name: 'Office PC'),
    ]);
    await tester.pumpWidget(const ProviderScope(child: NexusApp()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Office PC'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Work laptop');
    await tester.tap(find.byTooltip('laptop'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Work laptop'), findsOneWidget);
    final saved = await TargetStore.load();
    expect(saved.single.name, 'Work laptop');
    expect(saved.single.icon, 'laptop');
    await tester.longPress(find.text('Work laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove saved device'));
    await tester.pumpAndSettle();
    // Removing asks first; "Keep" leaves the device alone.
    expect(find.text('Remove Work laptop?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.text('Work laptop'), findsOneWidget);
    await tester.longPress(find.text('Work laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove saved device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Work laptop'), findsNothing);
    expect(await TargetStore.load(), isEmpty);
    expect(find.text('Connect your computer'), findsOneWidget);
  });
}
