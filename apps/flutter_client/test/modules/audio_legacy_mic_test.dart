// The older NexusLink phone mic lives under Audio: the only mic control on
// PCs without Nexus Audio, a collapsed fallback on PCs that have it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/modules/audio/audio_module.dart';
import 'package:nexuslink/src/modules/audio/audio_screen.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/capabilities.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_registry.dart';
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

Widget _audio(SavedTarget target, {bool mic = true}) => ProviderScope(
  overrides: [
    activeClientProvider.overrideWithValue(
      RpcClient('ws://127.0.0.1:1/rpc')
        ..capabilities = {
          'features': <String>[if (mic) 'mic.v1'],
        },
    ),
    connectionStatusProvider.overrideWithValue(RpcStatus.connected),
    shellProvider.overrideWith(() => _FixedShell(target)),
  ],
  child: MaterialApp(
    home: AudioScreen(
      ctx: ModuleContext(
        target: target,
        capabilities: capabilitiesOf(target),
        reachable: const {UtilityIds.nexuslink},
      ),
    ),
  ),
);

void main() {
  testWidgets('a PC without Nexus Audio shows Audio with the older mic', (
    tester,
  ) async {
    final target = hubTarget(utilities: {UtilityIds.nexuslink});
    expect(
      modulesFor(
        moduleRegistry,
        capabilities: capabilitiesOf(target),
        platform: TargetPlatform.android,
      ).any((m) => m is AudioModule),
      isTrue,
    );
    await tester.pumpWidget(_audio(target));
    expect(find.byKey(const ValueKey('legacy-mic')), findsOneWidget);
    expect(find.text('PHONE MIC'), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-switch-mic')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an older host without mic.v1 says what to do', (tester) async {
    await tester.pumpWidget(
      _audio(hubTarget(utilities: {UtilityIds.nexuslink}), mic: false),
    );
    expect(find.text('PHONE MIC'), findsNothing);
    expect(
      find.textContaining('doesn’t support the phone mic'),
      findsOneWidget,
    );
  });

  testWidgets('with Nexus Audio, the older mic is a collapsed fallback', (
    tester,
  ) async {
    await tester.pumpWidget(_audio(hubTarget()));
    final legacy = find.byKey(const ValueKey('legacy-mic'));
    await tester.scrollUntilVisible(legacy, 200);
    expect(find.text('Use as PC mic (older method)'), findsOneWidget);
    expect(find.text('PHONE MIC'), findsNothing);
    await tester.tap(find.text('Use as PC mic (older method)'));
    await tester.pumpAndSettle();
    expect(find.text('PHONE MIC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
