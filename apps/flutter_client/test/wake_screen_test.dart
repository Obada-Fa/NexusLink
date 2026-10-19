import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/services/wake_service.dart';
import 'package:nexuslink/src/state/saved_devices.dart';
import 'package:nexuslink/src/state/wake_config.dart';

class FakeWake extends WakeService {
  String? secret;
  int calls = 0;
  final ready = Completer<bool>();
  @override
  Future<String?> token(String host) async => secret;
  @override
  Future<void> saveToken(String host, String value) async {
    secret = value;
  }

  @override
  Future<void> removeToken(String host) async {
    secret = null;
  }

  @override
  Future<void> wake(String host, WakeConfig config) async {
    calls++;
  }

  @override
  Future<bool> reachable(String host) => ready.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'saved offline PC can configure wake and cancel waiting without resending',
    (tester) async {
      await SavedDevices.save([
        const SavedDevice(url: 'ws://pc:45678/rpc', name: 'Office PC'),
      ]);
      final wake = FakeWake();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [wakeServiceProvider.overrideWithValue(wake)],
          child: const NexusLinkApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up wake'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API key / token (if required)'),
        'private-key',
      );
      await tester.ensureVisible(find.text('Save wake settings'));
      await tester.tap(find.text('Save wake settings'));
      await tester.pumpAndSettle();
      expect(wake.secret, 'private-key');
      expect(
        (await SavedDevices.load()).single.wake!.endpoint,
        'http://100.101.246.19:3050/wake',
      );
      await tester.tap(find.text('Wake PC'));
      await tester.pump();
      expect(wake.calls, 1);
      expect(find.textContaining('Wake sent'), findsOneWidget);
      await tester.tap(find.text('Stop waiting'));
      await tester.pump();
      expect(find.text('Wake PC'), findsOneWidget);
      wake.ready.complete(false);
      await tester.pump();
      expect(wake.calls, 1);
      expect(find.text('Tap to connect'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
