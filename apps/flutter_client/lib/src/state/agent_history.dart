import '../rpc/models.dart';

AgentEvent _copyEvent(AgentEvent e, {required int seq}) => AgentEvent(
      seq: seq,
      ts: e.ts,
      kind: e.kind,
      text: e.text,
      toolName: e.toolName,
      toolInput: e.toolInput,
      toolOutput: e.toolOutput,
      refId: e.refId,
      images: e.images,
    );

/// Host snapshots occasionally arrive without stable seq numbers (legacy imports,
/// host-chat seed). Collapsing them in a seq-keyed map would leave one row.
List<AgentEvent> normalizeTranscriptSeqs(List<AgentEvent> events) {
  if (events.isEmpty) return events;
  final seen = <int>{};
  var needsRenumber = false;
  for (final e in events) {
    if (e.seq <= 0 || !seen.add(e.seq)) {
      needsRenumber = true;
      break;
    }
  }
  if (!needsRenumber) return events;
  var seq = 0;
  return [for (final e in events) _copyEvent(e, seq: ++seq)];
}

/// Replace the on-screen transcript with a host snapshot, unioned with any live
/// events the phone already has. Uses seq as the key so gaps in either list do
/// not drop messages (the old maxSeq filter could erase in-flight replies).
List<AgentEvent> mergeAgentHistory(
  List<AgentEvent> history,
  List<AgentEvent> live,
) {
  final host = normalizeTranscriptSeqs(history);
  final phone = normalizeTranscriptSeqs(live);
  if (host.isEmpty) return List<AgentEvent>.from(phone);
  if (phone.isEmpty) return List<AgentEvent>.from(host);

  final bySeq = <int, AgentEvent>{};
  for (final e in host) {
    bySeq[e.seq] = e;
  }
  for (final e in phone) {
    bySeq.putIfAbsent(e.seq, () => e);
  }
  return bySeq.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
}

/// Apply a host snapshot without wiping a transcript we already rendered.
List<AgentEvent> applyAgentHistorySnapshot(
  List<AgentEvent> history,
  List<AgentEvent> current, {
  required bool busy,
}) {
  final merged = mergeAgentHistory(history, current);
  if (merged.isEmpty && current.isNotEmpty) return current;
  if (busy && merged.length < current.length) return current;
  if (!busy && transcriptHasOpenTools(merged)) {
    return closeOpenTools(merged, output: 'Interrupted — host restarted.');
  }
  return merged;
}
