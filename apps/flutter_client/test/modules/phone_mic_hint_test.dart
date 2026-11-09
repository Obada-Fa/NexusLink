// NexusLink's own phone mic stays in the PC tab; with Audio paired it points
// to the Audio tile.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/pc/phone_mic.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/state/connection.dart';

import '../shell/fakes.dart';

class _FixedShell extends ShellController {
  _FixedShell(this.target);
  final SavedTarget target;

  @override
  ShellState build() =>
      ShellState(loaded: true, targets: [target], currentId: target.id);
}

Widget _host(SavedTarget target) => ProviderScope(
  overrides: [
    activeClientProvider.overrideWithValue(
      RpcClient('ws://127.0.0.1:1/rpc')
        ..capabilities = {'features': <String>['mic.v1']},
    ),
    connectionStatusProvider.overrideWithValue(RpcStatus.connected),
    shellProvider.overrideWith(() => _FixedShell(target)),
  ],
  child: const MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: PhoneMicSection())),
  ),
);

void main() {
  testWidgets('hint to the Audio tile when the PC has Audio', (tester) async {
    await tester.pumpWidget(_host(hubTarget()));
    expect(find.text('PHONE MIC'), findsOneWidget);
    expect(find.byKey(const ValueKey('mic-audio-hint')), findsOneWidget);
  });

  testWidgets('no hint without Audio', (tester) async {
    await tester.pumpWidget(
      _host(hubTarget(utilities: {UtilityIds.nexuslink})),
    );
    expect(find.text('PHONE MIC'), findsOneWidget);
    expect(find.byKey(const ValueKey('mic-audio-hint')), findsNothing);
  });
}
