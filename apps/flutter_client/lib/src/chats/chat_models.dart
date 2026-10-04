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
  return '${age.inDays} days ago';
}
