import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/state/wake_config.dart';
import 'package:nexuslink/src/workspace/platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

SavedTarget sample() => SavedTarget(
  id: 'hub-1',
  name: 'Office PC',
  icon: 'laptop',
  addresses: const TargetAddresses(
    tailscale: '100.64.0.5',
    lan: ['192.168.2.10'],
  ),
  wake: const WakeConfig(mac: 'AA:BB:CC:DD:EE:FF'),
  utilities: {
    UtilityIds.nexuslink: UtilityLink(
      utility: UtilityIds.nexuslink,
      port: 45678,
      wsUrl: 'ws://100.64.0.5:45678/rpc',
      hostId: 'h1',
      preferredHost: '100.64.0.5',
      pairedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    ),
    UtilityIds.audio: UtilityLink(
      utility: UtilityIds.audio,
      port: 8010,
      fingerprint: 'AB' * 32,
      deviceId: 'dev-1',
      pairedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    ),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('target JSON round trip', () {
    final t = sample();
    final back = SavedTarget.fromJson(
      jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
    );
    expect(jsonEncode(back.toJson()), jsonEncode(t.toJson()));
    expect(back.has(UtilityIds.audio), isTrue);
    expect(back.has(UtilityIds.remote), isFalse);
    expect(back.utilities[UtilityIds.audio]!.deviceId, 'dev-1');
    expect(back.wake!.mac, 'AA:BB:CC:DD:EE:FF');
  });

  test('addresses: tailscale first, then lan, de-duplicated', () {
    const a = TargetAddresses(
      tailscale: '1.1.1.1',
      lan: ['2.2.2.2', '1.1.1.1', '3.3.3.3'],
    );
    expect(a.ordered, ['1.1.1.1', '2.2.2.2', '3.3.3.3']);
    expect(const TargetAddresses(lan: ['2.2.2.2']).ordered, ['2.2.2.2']);
  });

  test('vault key format', () {
    expect(CredentialVault.keyFor('hub-1', 'audio'), 'nxu/hub-1/audio');
  });

  test('vault round trip and delete', () async {
    await CredentialVault.write('t', 'remote', 'secret');
    expect(await CredentialVault.read('t', 'remote'), 'secret');
    await CredentialVault.delete('t', 'remote');
    expect(await CredentialVault.read('t', 'remote'), isNull);
  });

  test('migrates legacy saved devices once, current from last host', () async {
    SharedPreferences.setMockInitialValues({
      'nexuslink-saved-devices': jsonEncode([
        {'url': 'ws://100.64.0.5:45678/rpc', 'name': 'Desk', 'icon': 'server'},
        {
          'url': 'ws://192.168.1.9:45678/rpc',
          'name': 'Laptop',
          'wake': {'method': 'lan', 'mac': '11:22:33:44:55:66'},
        },
      ]),
      'nexuslink-last-host-url': 'ws://192.168.1.9:45678/rpc',
    });
    final targets = await TargetStore.load();
    expect(targets.map((t) => t.id), [
      'legacy:ws://100.64.0.5:45678/rpc',
      'legacy:ws://192.168.1.9:45678/rpc',
    ]);
    expect(targets[0].name, 'Desk');
    expect(targets[0].icon, 'server');
    final link = targets[0].utilities[UtilityIds.nexuslink]!;
    expect(link.wsUrl, 'ws://100.64.0.5:45678/rpc');
    expect(link.port, 45678);
    expect(targets[1].wake!.mac, '11:22:33:44:55:66');
    expect(await TargetStore.currentId(), 'legacy:ws://192.168.1.9:45678/rpc');

    // Second load reads the new key; the old key is untouched.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('nexuslink-saved-devices'), isNotNull);
    expect((await TargetStore.load()).length, 2);
  });

  test('upsert merges a legacy target into the hub target', () async {
    await TargetStore.upsert(
      SavedTarget(
        id: 'legacy:ws://100.64.0.5:45678/rpc',
        name: 'Desk',
        icon: 'server',
        wake: const WakeConfig(mac: 'AA'),
        utilities: {
          UtilityIds.nexuslink: UtilityLink(
            utility: UtilityIds.nexuslink,
            port: 45678,
            wsUrl: 'ws://100.64.0.5:45678/rpc',
            pairedAt: DateTime.now(),
          ),
        },
      ),
    );
    await TargetStore.setCurrent('legacy:ws://100.64.0.5:45678/rpc');
    final merged = await TargetStore.upsert(sample());
    final all = await TargetStore.load();
    expect(all.length, 1);
    expect(all.single.id, 'hub-1');
    expect(merged.icon, 'laptop');
    expect(merged.has(UtilityIds.audio), isTrue);
    expect(merged.has(UtilityIds.nexuslink), isTrue);
    expect(merged.wake!.mac, 'AA:BB:CC:DD:EE:FF'); // hub's own wake wins
    expect(await TargetStore.currentId(), 'hub-1');
  });

  test('upsert merges utilities of the same id', () async {
    await TargetStore.upsert(sample());
    final more = SavedTarget(
      id: 'hub-1',
      name: 'Office PC',
      utilities: {
        UtilityIds.remote: UtilityLink(
          utility: UtilityIds.remote,
          port: 45679,
          pairedAt: DateTime.now(),
        ),
      },
    );
    final merged = await TargetStore.upsert(more);
    expect(merged.utilities.keys.toSet(), {'nexuslink', 'audio', 'remote'});
    expect((await TargetStore.load()).length, 1);
  });

  test('remove wipes secrets and the nexuslink credential', () async {
    await TargetStore.upsert(sample());
    await TargetStore.setCurrent('hub-1');
    await CredentialVault.write('hub-1', 'audio', 'a');
    await CredentialVault.write('hub-1', 'remote', 'r');
    await PlatformBridge.saveCredential('ws://100.64.0.5:45678/rpc', 'nl');
    await TargetStore.remove('hub-1');
    expect(await TargetStore.load(), isEmpty);
    expect(await CredentialVault.read('hub-1', 'audio'), isNull);
    expect(await CredentialVault.read('hub-1', 'remote'), isNull);
    expect(
      await PlatformBridge.credential('ws://100.64.0.5:45678/rpc'),
      isNull,
    );
    expect(await TargetStore.currentId(), isNull);
  });
}
