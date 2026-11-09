import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/capabilities.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_registry.dart';

import 'fakes.dart';

void main() {
  test('capabilities come from paired utilities only', () {
    final nexusOnly = hubTarget(utilities: {UtilityIds.nexuslink});
    expect(capabilitiesOf(nexusOnly).map((c) => c.id), [
      'screen',
      'apps',
      'files',
      'terminal',
      'agents',
      'phone_mic',
    ]);
    expect(
      capabilitiesOf(nexusOnly).every((c) => c.utility == UtilityIds.nexuslink),
      isTrue,
    );
    final all = capabilitiesOf(hubTarget());
    expect(
      all.map((c) => c.id),
      containsAll(['input', 'dictation', 'audio.source', 'audio.sink', 'mic']),
    );
    expect(capabilitiesOf(hubTarget(utilities: {})), isEmpty);
  });

  test('requirement: any of the ids, at a minimum version', () {
    const req = CapabilityRequirement.anyOf(['screen', 'apps']);
    expect(
      req.isMetBy([const Capability('apps', utility: UtilityIds.nexuslink)]),
      isTrue,
    );
    expect(
      req.isMetBy([const Capability('input', utility: UtilityIds.remote)]),
      isFalse,
    );
    const v2 = CapabilityRequirement.anyOf(['screen'], minVersion: 2);
    expect(
      v2.isMetBy([const Capability('screen', utility: UtilityIds.nexuslink)]),
      isFalse,
    );
    expect(
      v2.isMetBy([
        const Capability('screen', version: 2, utility: UtilityIds.nexuslink),
      ]),
      isTrue,
    );
  });

  test('registry lists all six modules in grid order', () {
    expect(moduleRegistry.map((m) => m.id), [
      'desktop',
      'files',
      'agents',
      'terminal',
      'remote',
      'audio',
    ]);
    // A fully paired target shows all six on Android.
    expect(
      modulesFor(
        moduleRegistry,
        capabilities: capabilitiesOf(hubTarget()),
        platform: TargetPlatform.android,
      ).map((m) => m.id),
      ['desktop', 'files', 'agents', 'terminal', 'remote', 'audio'],
    );
    // Audio is Android-only.
    expect(
      modulesFor(
        moduleRegistry,
        capabilities: capabilitiesOf(hubTarget()),
        platform: TargetPlatform.iOS,
      ).map((m) => m.id),
      isNot(contains('audio')),
    );
    expect(
      moduleRegistry.firstWhere((m) => m.id == 'audio').platforms,
      {TargetPlatform.android},
    );
    final shown = modulesFor(
      moduleRegistry,
      capabilities: capabilitiesOf(hubTarget(utilities: {UtilityIds.nexuslink})),
      platform: TargetPlatform.android,
    );
    // Audio stays reachable for NexusLink's older phone mic.
    expect(shown.map((m) => m.id), [
      'desktop',
      'files',
      'agents',
      'terminal',
      'audio',
    ]);
  });

  test('NexusLink modules hide when only Remote/Audio are paired', () {
    final shown = modulesFor(
      moduleRegistry,
      capabilities: capabilitiesOf(
        hubTarget(utilities: {UtilityIds.remote, UtilityIds.audio}),
      ),
      platform: TargetPlatform.android,
    );
    expect(shown.map((m) => m.id), ['remote', 'audio']);
  });

  test('filters by capability and platform, sorts by order', () {
    final remote = FakeModule(id: 'remote', orderValue: 5);
    final audio = FakeModule(
      id: 'audio',
      requiredCaps: ['audio.source', 'audio.sink', 'mic'],
      orderValue: 50,
    );
    final iosOnly = FakeModule(
      id: 'ios',
      requiredCaps: ['screen'],
      platformSet: {TargetPlatform.iOS},
    );
    final modules = [...nexusLinkModules, audio, iosOnly, remote];
    final caps = capabilitiesOf(hubTarget());
    expect(
      modulesFor(
        modules,
        capabilities: caps,
        platform: TargetPlatform.android,
      ).map((m) => m.id),
      ['remote', 'desktop', 'files', 'agents', 'terminal', 'audio'],
    );
    // On iOS the Android-only modules disappear and the iOS one shows.
    expect(
      modulesFor(
        modules,
        capabilities: caps,
        platform: TargetPlatform.iOS,
      ).map((m) => m.id),
      ['ios'],
    );
    // Without Audio paired, the audio module is hidden.
    expect(
      modulesFor(
        modules,
        capabilities: capabilitiesOf(
          hubTarget(utilities: {UtilityIds.nexuslink, UtilityIds.remote}),
        ),
        platform: TargetPlatform.android,
      ).map((m) => m.id),
      isNot(contains('audio')),
    );
  });

  test('utilitiesFor maps required capabilities to their providers', () {
    final ctx = ModuleContext(
      target: hubTarget(),
      capabilities: capabilitiesOf(hubTarget()),
      reachable: const {},
    );
    expect(moduleRegistry.first.utilitiesFor(ctx), {UtilityIds.nexuslink});
    expect(FakeModule(id: 'remote').utilitiesFor(ctx), {UtilityIds.remote});
  });
}
