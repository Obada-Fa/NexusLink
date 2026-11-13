// Sub-agent state for a Code Agent chat, rebuilt from the event list.
//
// Contract: docs/AGENT-SUBAGENT-EVENTS.md. Main-chat events and sub-agent
// events are told apart by `agentId`: every `agent-*` event carries the full
// current record of one sub-agent, and the latest one per `agentId` is that
// agent's record. Pure Dart, no widgets, so it is unit-tested directly.

import '../rpc/models.dart';

enum SubagentStatus { running, completed, failed, stopped }

SubagentStatus _status(AgentEvent e) {
  if (e.kind != 'agent-end') return SubagentStatus.running;
  return switch (e.agentStatus) {
    'failed' => SubagentStatus.failed,
    'stopped' => SubagentStatus.stopped,
    // `running` is never valid on an end; treat anything unknown as done.
    _ => SubagentStatus.completed,
  };
}

/// One sub-agent as the phone knows it.
class SubagentRecord {
  const SubagentRecord({
    required this.id,
    required this.status,
    required this.depth,
    required this.background,
    required this.startSeq,
    required this.updatedSeq,
    required this.startedTs,
    required this.updatedTs,
    this.refId,
    this.name,
    this.type,
    this.parentId,
    this.progress,
    this.lastTool,
    this.prompt,
    this.summary,
    this.runs = 1,
    this.events = const [],
  });

  final String id;

  /// `tool_use` id of the spawning `Agent` call in the parent's timeline.
  final String? refId;
  final String? name;
  final String? type;
  final int depth;
  final String? parentId;
  final bool background;
  final SubagentStatus status;

  /// Latest progress line from an `agent-update` ("Running Sleep 5 seconds").
  final String? progress;

  /// Last tool the agent used, from `agent-update.toolName`.
  final String? lastTool;

  /// Task prompt, from the latest `agent-start` (kept across updates).
  final String? prompt;

  /// `agent-end.text`: the final summary or the stop reason.
  final String? summary;

  /// How many times this id started (a continued agent starts again).
  final int runs;
  final int startSeq;
  final int updatedSeq;
  final int startedTs;
  final int updatedTs;

  /// The agent's own streamed events (`text`, `thinking`, `tool-*`,
  /// `permission-request` with this `agentId`), in arrival order.
  final List<AgentEvent> events;

  bool get running => status == SubagentStatus.running;

  /// Name for UI text; the CLI almost always gives one.
  String get label {
    final n = (name ?? '').trim();
    if (n.isNotEmpty) return n;
    final t = (type ?? '').trim();
    return t.isNotEmpty ? t : 'Agent';
  }

  /// One line for a chip or card: what it is doing, or how it ended.
  String get activity {
    if (running) {
      final p = (progress ?? '').trim();
      if (p.isNotEmpty) return _firstLine(p);
      if ((lastTool ?? '').isNotEmpty) return 'Using $lastTool';
      return background ? 'Working in the background' : 'Starting…';
    }
    final s = (summary ?? '').trim();
    return switch (status) {
      SubagentStatus.failed => s.isEmpty ? 'Failed' : _firstLine(s),
      SubagentStatus.stopped => s.isEmpty ? 'Stopped' : _firstLine(s),
      _ => s.isEmpty ? 'Done' : _firstLine(s),
    };
  }

  /// The status as a word, so state never depends on colour alone.
  String get statusLabel => switch (status) {
    SubagentStatus.running => 'Running',
    SubagentStatus.completed => 'Done',
    SubagentStatus.failed => 'Failed',
    SubagentStatus.stopped => 'Stopped',
  };

  /// True when the agent's own messages streamed (depth-1 agents usually
  /// stream some; depth ≥ 2 agents never do).
  bool get hasOwnEvents => events.isNotEmpty;

  SubagentRecord _withEvents(List<AgentEvent> events) => SubagentRecord(
    id: id,
    refId: refId,
    name: name,
    type: type,
    depth: depth,
    parentId: parentId,
    background: background,
    status: status,
    progress: progress,
    lastTool: lastTool,
    prompt: prompt,
    summary: summary,
    runs: runs,
    startSeq: startSeq,
    updatedSeq: updatedSeq,
    startedTs: startedTs,
    updatedTs: updatedTs,
    events: events,
  );
}

String _firstLine(String s) {
  for (final line in s.split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) return t;
  }
  return s.trim();
}

/// Main timeline = events without `agentId`, except permission requests,
/// which stay answerable in the main chat. `agent-*` events are strip input
/// only and never render as bubbles.
bool isMainTimelineEvent(AgentEvent e) {
  if (e.isAgentRecord) return false;
  if (e.agentId == null) return true;
  return e.kind == 'permission-request';
}

/// All sub-agents of one chat.
class SubagentState {
  SubagentState._(this._byId, this._bySpawnRef, this.lastUserSeq);

  static final empty = SubagentState._(const {}, const {}, 0);

  final Map<String, SubagentRecord> _byId;
  final Map<String, String> _bySpawnRef;

  /// Seq of the last main `user` event: the start of the current turn.
  final int lastUserSeq;

  bool get isEmpty => _byId.isEmpty;
  Iterable<SubagentRecord> get all => _byId.values;
  SubagentRecord? operator [](String? id) => id == null ? null : _byId[id];

  /// The agent spawned by the `Agent` tool call with this `refId`.
  SubagentRecord? bySpawnRef(String? refId) =>
      refId == null ? null : _byId[_bySpawnRef[refId]];

  int get runningCount => _byId.values.where((a) => a.running).length;

  List<SubagentRecord> childrenOf(String id) => [
    for (final a in _byId.values)
      if (a.parentId == id) a,
  ]..sort((a, b) => a.startSeq.compareTo(b.startSeq));

  /// Agents for the strip: those still running, plus those that started or
  /// ended in the current turn. Running roots first, each followed by its
  /// descendants (a running child always has a running parent: the host
  /// ends the deepest agents first).
  List<SubagentRecord> stripAgents() {
    bool relevant(SubagentRecord a) =>
        a.running || a.startSeq > lastUserSeq || a.updatedSeq > lastUserSeq;
    final shown = {
      for (final a in _byId.values)
        if (relevant(a)) a.id: a,
    };
    // Keep a shown child's ancestors so it never appears orphaned.
    for (final a in shown.values.toList()) {
      var parent = _byId[a.parentId];
      while (parent != null && !shown.containsKey(parent.id)) {
        shown[parent.id] = parent;
        parent = _byId[parent.parentId];
      }
    }
    final roots =
        shown.values
            .where((a) => a.parentId == null || !shown.containsKey(a.parentId))
            .toList()
          ..sort((a, b) {
            if (a.running != b.running) return a.running ? -1 : 1;
            return a.startSeq.compareTo(b.startSeq);
          });
    final out = <SubagentRecord>[];
    void visit(SubagentRecord a) {
      out.add(a);
      final kids = shown.values.where((c) => c.parentId == a.id).toList()
        ..sort((x, y) {
          if (x.running != y.running) return x.running ? -1 : 1;
          return x.startSeq.compareTo(y.startSeq);
        });
      kids.forEach(visit);
    }

    roots.forEach(visit);
    return out;
  }

  /// Name for a permission request or similar label.
  String? nameOf(String? agentId) => this[agentId]?.label;
}

/// Builds every sub-agent record from a chat's events (live or replayed from
/// history, in seq order). Events for an `agentId` that never had an
/// `agent-start` in the list (an older page not loaded yet) still get a
/// record from whatever `agent-*` event is present.
SubagentState buildSubagents(Iterable<AgentEvent> events) {
  final byId = <String, SubagentRecord>{};
  final own = <String, List<AgentEvent>>{};
  final bySpawnRef = <String, String>{};
  var lastUserSeq = 0;

  for (final e in events) {
    if (e.kind == 'user' && e.agentId == null && e.seq > lastUserSeq) {
      lastUserSeq = e.seq;
    }
    final id = e.agentId;
    if (id == null) continue;
    if (!e.isAgentRecord) {
      own.putIfAbsent(id, () => []).add(e);
      continue;
    }
    final prev = byId[id];
    // A new start for a known id is a restart ("running again"): the record
    // is replaced, its earlier messages stay attached.
    final starting = e.kind == 'agent-start';
    final status = _status(e);
    final record = SubagentRecord(
      id: id,
      refId: e.refId ?? prev?.refId,
      name: e.agentName ?? prev?.name,
      type: e.agentType ?? prev?.type,
      depth: e.agentDepth ?? prev?.depth ?? 1,
      parentId: e.agentParentId ?? prev?.parentId,
      background: e.agentBackground ?? prev?.background ?? false,
      status: status,
      progress: e.kind == 'agent-update'
          ? (e.text ?? prev?.progress)
          : (starting ? null : prev?.progress),
      lastTool: e.kind == 'agent-update'
          ? (e.toolName ?? prev?.lastTool)
          : (starting ? null : prev?.lastTool),
      prompt: e.agentPrompt ?? prev?.prompt,
      summary: e.kind == 'agent-end' ? e.text : null,
      runs: prev == null ? 1 : prev.runs + (starting ? 1 : 0),
      startSeq: starting || prev == null ? e.seq : prev.startSeq,
      updatedSeq: e.seq,
      startedTs: starting || prev == null ? e.ts : prev.startedTs,
      updatedTs: e.ts,
    );
    byId[id] = record;
    if (record.refId != null) bySpawnRef[record.refId!] = id;
  }

  for (final entry in own.entries) {
    final record = byId[entry.key];
    if (record != null) {
      byId[entry.key] = record._withEvents(List.unmodifiable(entry.value));
    } else {
      // Messages for an agent whose records were all on an older page.
      final first = entry.value.first;
      final last = entry.value.last;
      byId[entry.key] = SubagentRecord(
        id: entry.key,
        status: SubagentStatus.completed,
        depth: 1,
        background: false,
        startSeq: first.seq,
        updatedSeq: last.seq,
        startedTs: first.ts,
        updatedTs: last.ts,
        events: List.unmodifiable(entry.value),
      );
    }
  }
  return SubagentState._(byId, bySpawnRef, lastUserSeq);
}

/// The main chat's events, ready for display:
/// - sub-agent events and `agent-*` records removed ([isMainTimelineEvent]);
/// - a `result` whose text repeats what the same round already streamed is
///   blanked, so a background flow's second `result` never shows the answer
///   twice.
List<AgentEvent> mainTimeline(Iterable<AgentEvent> events) {
  final out = <AgentEvent>[];
  final round = StringBuffer();
  for (final e in events) {
    if (!isMainTimelineEvent(e)) continue;
    if (e.kind == 'user') round.clear();
    if (e.kind == 'text' || e.kind == 'text-delta') round.write(e.text ?? '');
    if (e.kind == 'result') {
      final text = (e.text ?? '').trim();
      final streamed = round.toString().trim();
      round.clear();
      if (text.isNotEmpty &&
          streamed.isNotEmpty &&
          (streamed == text || streamed.endsWith(text))) {
        out.add(e.copyWith(text: ''));
        continue;
      }
    }
    out.add(e);
  }
  return out;
}

/// Splits tool groups so every `Agent` spawn call is its own item: the
/// spawn renders as an agent card with the agent's true state instead of a
/// row inside a "Finished N steps" group.
List<AgentDisplayItem> splitSpawnCalls(
  List<AgentDisplayItem> items,
  bool Function(String? refId) isSpawn,
) {
  if (!items.any((i) => i.tools?.any((t) => isSpawn(t.refId)) == true)) {
    return items;
  }
  final out = <AgentDisplayItem>[];
  for (final item in items) {
    final tools = item.tools;
    if (tools == null) {
      out.add(item);
      continue;
    }
    var run = <AgentEvent>[];
    for (final t in tools) {
      if (isSpawn(t.refId)) {
        if (run.isNotEmpty) out.add(AgentDisplayItem.tools(run));
        run = <AgentEvent>[];
        out.add(AgentDisplayItem.event(t));
      } else {
        run.add(t);
      }
    }
    if (run.isNotEmpty) out.add(AgentDisplayItem.tools(run));
  }
  return out;
}
