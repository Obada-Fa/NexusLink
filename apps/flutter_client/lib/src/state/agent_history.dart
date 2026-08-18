import '../rpc/models.dart';

/// Replace the on-screen transcript with a host snapshot, keeping any live
/// events that arrived after the snapshot was taken (higher `seq`).
List<AgentEvent> mergeAgentHistory(
  List<AgentEvent> history,
  List<AgentEvent> live,
) {
  if (history.isEmpty) return List<AgentEvent>.from(live);
  var maxSeq = -1;
  for (final e in history) {
    if (e.seq > maxSeq) maxSeq = e.seq;
  }
  return [...history, ...live.where((e) => e.seq > maxSeq)];
}
