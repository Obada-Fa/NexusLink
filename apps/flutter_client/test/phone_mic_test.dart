import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/pc/phone_mic.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';

Widget _host(RpcClient client) => ProviderScope(
  overrides: [
    activeClientProvider.overrideWithValue(client),
    connectionStatusProvider.overrideWithValue(RpcStatus.connected),
  ],
  child: const MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: PhoneMicSection())),
  ),
);

void main() {
  test('frames carry the NXMC magic the PC routes on', () {
    final frame = micFrame(Uint8List.fromList([1, 2, 3, 4]));
    expect(frame, [0x4e, 0x58, 0x4d, 0x43, 1, 2, 3, 4]);
  });

  test('peak level reads little-endian s16 samples', () {
    final pcm = ByteData(6)
      ..setInt16(0, 100, Endian.little)
      ..setInt16(2, -32767, Endian.little)
      ..setInt16(4, 5, Endian.little);
    expect(pcmPeak(pcm.buffer.asUint8List()), closeTo(1, 1e-6));
    expect(pcmPeak(Uint8List(4)), 0);
  });

  test('transmitting follows mute and hold-to-talk', () {
    const live = PhoneMicState(phase: MicPhase.live);
    expect(live.transmitting, isTrue);
    expect(live.copyWith(muted: true).transmitting, isFalse);
    expect(live.copyWith(holdToTalk: true).transmitting, isFalse);
    expect(live.copyWith(holdToTalk: true, holding: true).transmitting, isTrue);
    expect(const PhoneMicState().transmitting, isFalse);
  });

  testWidgets('hidden on hosts without mic.v1', (tester) async {
    final client = RpcClient('ws://127.0.0.1:1/rpc')
      ..capabilities = {'features': <String>['monitor.v1']};
    await tester.pumpWidget(_host(client));
    expect(find.text('PHONE MIC'), findsNothing);
  });

  testWidgets('shown with its controls on hosts with mic.v1', (tester) async {
    final client = RpcClient('ws://127.0.0.1:1/rpc')
      ..capabilities = {'features': <String>['monitor.v1', 'mic.v1']};
    await tester.pumpWidget(_host(client));
    expect(find.text('PHONE MIC'), findsOneWidget);
    expect(find.text('Use this phone as a PC mic'), findsOneWidget);
    expect(find.byKey(const ValueKey('mic-hold')), findsOneWidget);
    expect(find.byKey(const ValueKey('mic-default')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mic-hold')));
    await tester.pump();
    final hold = tester.widget<SwitchListTile>(
      find.descendant(
        of: find.byKey(const ValueKey('mic-hold')),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(hold.value, isTrue);
  });
}
