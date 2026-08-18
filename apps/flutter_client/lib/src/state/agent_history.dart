import '../rpc/models.dart';

/// Replace the on-screen transcript with a host snapshot, unioned with any live
/// events the phone already has. Uses seq as the key so gaps in either list do
/// not drop messages (the old maxSeq filter could erase in-flight replies).
List<AgentEvent> mergeAgentHistory(
  List<AgentEvent> history,
  List<AgentEvent> live,
) {
  if (history.isEmpty) return List<AgentEvent>.from(live);
  if (live.isEmpty) return List<AgentEvent>.from(history);

  final bySeq = <int, AgentEvent>{};
  for (final e in history) {
    bySeq[e.seq] = e;
  }
  for (final e in live) {
    bySeq.putIfAbsent(e.seq, () => e);
  }
  return bySeq.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
}
