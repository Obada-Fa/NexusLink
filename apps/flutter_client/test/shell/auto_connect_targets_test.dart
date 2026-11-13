import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/auto_connect.dart';

import 'fakes.dart';

final office = hubTarget();
final laptop = SavedTarget(
  id: 'legacy:ws://laptop:45678/rpc',
  name: 'Laptop',
  utilities: {
    UtilityIds.nexuslink: link(
      UtilityIds.nexuslink,
      wsUrl: 'ws://laptop:45678/rpc',
    ),
  },
);
final remoteOnly = hubTarget(id: 'hub-tv', utilities: {UtilityIds.remote});

Future<({SavedTarget? target, AutoConnectReason reason})> decide({
  List<SavedTarget>? targets,
  String? currentId = 'hub-office',
  bool userDisconnected = false,
  bool alreadyAttempted = false,
  Set<String> paired = const {
    'ws://100.64.0.5:45678/rpc',
    'ws://laptop:45678/rpc',
  },
}) => decideTargetAutoConnect(
  targets: targets ?? [office, laptop, remoteOnly],
  currentId: currentId,
  userDisconnected: userDisconnected,
  alreadyAttempted: alreadyAttempted,
  hasCredential: (url) async => paired.contains(url),
);

void main() {
  test('connects to the current target when paired', () async {
    final d = await decide();
    expect(d.reason, AutoConnectReason.connect);
    expect(d.target?.id, 'hub-office');
    final l = await decide(currentId: laptop.id);
    expect(l.target?.name, 'Laptop');
  });

  test('never after an explicit disconnect, and only once', () async {
    expect(
      (await decide(userDisconnected: true)).reason,
      AutoConnectReason.userDisconnected,
    );
    expect(
      (await decide(alreadyAttempted: true)).reason,
      AutoConnectReason.alreadyTried,
    );
  });

  test('no current target, unknown current, or nothing saved', () async {
    expect((await decide(currentId: null)).reason, AutoConnectReason.noSavedPc);
    expect(
      (await decide(targets: const [])).reason,
      AutoConnectReason.noSavedPc,
    );
    expect(
      (await decide(currentId: 'gone')).reason,
      AutoConnectReason.lastPcNotSaved,
    );
  });

  test('needs a stored NexusLink pairing', () async {
    expect((await decide(paired: const {})).reason, AutoConnectReason.notPaired);
    expect(
      (await decide(currentId: 'hub-tv')).reason,
      AutoConnectReason.notPaired,
      reason: 'a target without NexusLink has nothing to dial',
    );
    final failing = await decideTargetAutoConnect(
      targets: [office],
      currentId: office.id,
      userDisconnected: false,
      alreadyAttempted: false,
      hasCredential: (_) async => throw Exception('keystore'),
    );
    expect(failing.reason, AutoConnectReason.notPaired);
  });

  test('nexusLinkUrlOf normalizes', () {
    final t = SavedTarget(
      id: 'x',
      name: 'x',
      utilities: {
        UtilityIds.nexuslink: link(UtilityIds.nexuslink, wsUrl: '10.0.0.2'),
      },
    );
    expect(nexusLinkUrlOf(t), 'ws://10.0.0.2:45678/rpc');
    expect(nexusLinkUrlOf(remoteOnly), isNull);
  });
}
