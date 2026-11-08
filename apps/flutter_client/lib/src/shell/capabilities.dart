// Phase 1 capabilities: derived statically from which utilities a target has
// paired (spec §3.3). P2's gateway will advertise them from the PC instead.

import '../session/target.dart';

class Capability {
  const Capability(this.id, {this.version = 1, required this.utility});
  final String id; // e.g. 'screen'
  final int version;
  final String utility; // provider: UtilityIds.*

  @override
  bool operator ==(Object other) =>
      other is Capability &&
      other.id == id &&
      other.version == version &&
      other.utility == utility;

  @override
  int get hashCode => Object.hash(id, version, utility);

  @override
  String toString() => 'Capability($id v$version via $utility)';
}

const phase1Capabilities = <String, List<String>>{
  UtilityIds.nexuslink: ['screen', 'apps', 'terminal', 'agents'],
  UtilityIds.remote: ['input', 'dictation'],
  UtilityIds.audio: ['audio.source', 'audio.sink', 'mic'],
  // audio.source = PC speakers can stream to the phone
  // audio.sink   = PC can play phone audio
  // mic          = PC accepts the phone as its microphone (ABP_Phone_Mic)
};

/// Default TCP port per utility, used when a link has no explicit port.
const utilityDefaultPorts = <String, int>{
  UtilityIds.nexuslink: 45678,
  UtilityIds.remote: 45679,
  UtilityIds.audio: 8010,
};

/// The capabilities [target] provides through its paired utilities.
List<Capability> capabilitiesOf(SavedTarget target) => [
  for (final utility in target.utilities.keys)
    for (final id in phase1Capabilities[utility] ?? const <String>[])
      Capability(id, utility: utility),
];
