class ChatSummary {
  final Map<String, dynamic> json;
  ChatSummary(this.json);
  String get id => json['id'] as String;
  String get hostId => json['hostId'] as String;
  String get source => json['source'] as String? ?? 'nexuslink';
  String get sourceName => json['sourceName'] as String? ?? source;
  String get title => json['title'] as String? ?? 'Chat';
  String get preview => json['preview'] as String? ?? '';
  String? get sessionId => json['agentSessionId'] as String?;
  String? get folderId => json['folderId'] as String?;

  /// Library id of the orchestrator that started this chat (a worker session).
  String? get parentId => json['parentId'] as String?;
  String? get folderPath => json['folderPath'] as String?;
  String get folderName => json['folderName'] as String? ?? 'No folder';
  DateTime? get activity => json['activityAt'] is num
      ? DateTime.fromMillisecondsSinceEpoch((json['activityAt'] as num).toInt())
      : null;
  bool get archived => json['archived'] == true;
  String get execution => json['execution'] as String? ?? 'unknown';
  bool get canReply => (json['capabilities'] as Map?)?['continue'] == true;
  String? get replyReason =>
      (json['capabilities'] as Map?)?['reason'] as String?;
  String? get status => execution == 'working'
      ? 'Working'
      : execution == 'needsReply'
      ? 'Needs your reply'
      : !canReply
      ? 'Read only'
      : null;
}

class ChatFolder {
  final Map<String, dynamic> json;
  ChatFolder(this.json);
  String? get id => json['id'] as String?;
  String get name => json['name'] as String? ?? 'No folder';
  String? get path => json['path'] as String?;
  int get count => (json['count'] as num?)?.toInt() ?? 0;
  String get latestTitle => json['latestTitle'] as String? ?? '';
}

String chatDateGroup(DateTime? activity, {DateTime? now}) {
  if (activity == null) return 'Older';
  final current = now ?? DateTime.now();
  final local = activity.toLocal();
  final today = DateTime(current.year, current.month, current.day);
  final date = DateTime(local.year, local.month, local.day);
  if (!date.isBefore(today)) return 'Today';
  if (date == DateTime(current.year, current.month, current.day - 1)) {
    return 'Yesterday';
  }
  if (!date.isBefore(DateTime(current.year, current.month, current.day - 6))) {
    return 'Last 7 days';
  }
  return 'Older';
}

String chatRelativeTime(DateTime? activity) {
  if (activity == null) return '';
  final age = DateTime.now().difference(activity);
  if (age.inMinutes < 1) return 'Just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} hr ago';
  if (age.inDays == 1) return 'Yesterday';
  return '${age.inDays} days ago';
}

/// Compact "4m 12s" / "1h 05m" for running timers.
String formatElapsed(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inHours > 0) {
    return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
  if (d.inMinutes > 0) {
    return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${d.inSeconds}s';
}

/// What the agent is doing right now (host `ChatLive`); absent on older hosts.
class ChatLive {
  ChatLive(this.json);
  final Map<String, dynamic> json;

  /// working | waiting | done | failed | idle
  String get state => json['state'] as String? ?? 'idle';
  String? get step => _text(json['step']);
  String? get tool => _text(json['tool']);
  String? get activity => _text(json['activity']);
  DateTime? get turnStartedAt => _time(json['turnStartedAt']);
  DateTime? get updatedAt => _time(json['updatedAt']);
  String? get lastText => _text(json['lastText']);
  String? get waitingFor => _text(json['waitingFor']);

  /// approval | question | plan, for a `waiting` chat.
  String? get waitKind => _text(json['waitKind']);

  /// True when "waiting" was inferred from silence, not reported by the app.
  bool get guessed => (json['via'] as String? ?? '').endsWith('-heuristic');

  /// The turn ended and left an optional follow-up ("Should I commit it?").
  String? get ask => _text(json['ask']);
  List<ChatSubagent> get subagents => [
    for (final s in (json['subagents'] as List? ?? const []))
      if (s is Map && s['name'] is String)
        ChatSubagent(Map<String, dynamic>.from(s)),
  ];
  String? get model => _text(json['model']);
  int? get steps => (json['steps'] as num?)?.toInt();
  List<({String text, String state})> get todos => [
    for (final t in (json['todos'] as List? ?? const []))
      if (t is Map && t['text'] is String)
        (text: t['text'] as String, state: t['state'] as String? ?? 'pending'),
  ];
  int get todosDone => todos.where((t) => t.state == 'done').length;
  String? get activeTodo =>
      todos.where((t) => t.state == 'active').firstOrNull?.text;
  static String? _text(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : null;
  static DateTime? _time(Object? v) =>
      v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
}

/// A sub-agent a chat delegated to (host `ChatSubagent`).
class ChatSubagent {
  ChatSubagent(this.json);
  final Map<String, dynamic> json;
  String get name => json['name'] as String;
  String? get kind => ChatLive._text(json['kind']);

  /// working | waiting | done
  String get state => json['state'] as String? ?? 'done';
  String? get step => ChatLive._text(json['step']);
  DateTime? get updatedAt => ChatLive._time(json['updatedAt']);
}

extension AgentMonitorSummary on ChatSummary {
  ChatLive? get live => json['live'] is Map
      ? ChatLive(Map<String, dynamic>.from(json['live'] as Map))
      : null;

  /// Set when needs-you was cleared on the PC: 'acknowledged' (marked done) or 'stale'.
  String? get attentionCleared => json['attentionCleared'] as String?;

  /// One state vocabulary for the whole app: working | waiting | turn | failed | done | idle.
  String get liveState {
    if (yourTurn) return 'turn';
    final cleared = attentionCleared;
    if (cleared != null && execution != 'working' && live?.state != 'working') {
      return cleared == 'acknowledged' ? 'done' : 'idle';
    }
    final l = live?.state;
    if (execution == 'needsReply' || l == 'waiting') return 'waiting';
    if (['failed', 'interrupted'].contains(json['taskState']) ||
        l == 'failed') {
      return 'failed';
    }
    if (execution == 'working' || l == 'working') return 'working';
    if (l == 'done' || json['taskState'] == 'completed') return 'done';
    return 'idle';
  }

  /// The best one-line description of the current step.
  String get stepLabel =>
      live?.waitingFor ??
      (yourTurn ? live?.ask : null) ??
      live?.step ??
      (running || needsAttention ? monitorStatus : (live?.lastText ?? preview));

  DateTime? get turnStartedAt => live?.turnStartedAt;
  DateTime? get lastWriteAt => live?.updatedAt ?? activity;

  bool get needsAttention =>
      attentionCleared == null &&
      (execution == 'needsReply' ||
          live?.state == 'waiting' ||
          live?.state == 'failed' ||
          ['failed', 'interrupted'].contains(json['taskState']));
  bool get running =>
      (execution == 'working' || live?.state == 'working') && !needsAttention;

  /// Started by an orchestrator session: its reports go to that session, not to you.
  bool get isWorker => parentId != null;

  /// Finished with an optional follow-up for you. A worker's follow-up is its orchestrator's.
  bool get yourTurn =>
      attentionCleared == null &&
      live?.ask != null &&
      !isWorker &&
      !running &&
      !needsAttention;
  int get monitorPriority => needsAttention
      ? 0
      : yourTurn
      ? 1
      : running
      ? 2
      : 3;
  String get monitorSection => needsAttention
      ? 'Needs attention'
      : yourTurn
      ? 'Your turn'
      : running
      ? 'Running'
      : 'Recent';
  String get monitorStatus {
    if (execution == 'needsReply' || live?.state == 'waiting') {
      return switch (live?.waitKind) {
        'approval' when live!.guessed => 'Probably needs approval',
        'approval' => 'Needs approval',
        'question' => 'Asking you',
        'plan' => 'Plan to approve',
        _ => 'Waiting for you',
      };
    }
    if (yourTurn) return 'Your turn';
    if (isWorker && live?.ask != null && !running) {
      return 'Reported to its orchestrator';
    }
    if (json['taskState'] == 'failed' || live?.state == 'failed') {
      return 'Failed';
    }
    if (json['taskState'] == 'interrupted') return 'Interrupted';
    if (running) {
      return switch (live?.activity ?? json['activity']) {
        'searching' => 'Searching',
        'browsing' => 'Browsing the web',
        'waiting' => 'Waiting',
        'editing' => 'Editing files',
        'reading' => 'Reading / searching',
        'running-command' => 'Running a command',
        'thinking' => 'Thinking',
        'responding' => 'Writing a response',
        _ => 'Working',
      };
    }
    return switch (json['taskState']) {
      'completed' => 'Finished',
      'canceled' => 'Canceled',
      _ => execution == 'unknown' ? 'Status unavailable' : 'Idle',
    };
  }

  bool matchesMonitor(String filter) => switch (filter) {
    'running' => running,
    'attention' => needsAttention,
    'recent' => !running && !needsAttention,
    _ => true,
  };
}

int compareMonitorChats(ChatSummary a, ChatSummary b) {
  final priority = a.monitorPriority.compareTo(b.monitorPriority);
  if (priority != 0) return priority;
  final time = (b.activity?.millisecondsSinceEpoch ?? 0).compareTo(
    a.activity?.millisecondsSinceEpoch ?? 0,
  );
  return time != 0 ? time : a.id.compareTo(b.id);
}
