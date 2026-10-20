import '../chats/chat_models.dart';

/// Locations describe reported activity; they never imply a task succeeded.
enum OfficeStation {
  research('Research'),
  code('Code'),
  review('Review'),
  lounge('Lounge'),
  help('Reception');

  const OfficeStation(this.label);
  final String label;
}

OfficeStation officeStationFor(ChatSummary chat) {
  if (chat.needsAttention) return OfficeStation.help;
  if (!chat.running) return OfficeStation.lounge;
  return switch (chat.live?.activity ?? chat.json['activity']) {
    'reading' || 'searching' || 'browsing' => OfficeStation.research,
    'editing' || 'running-command' => OfficeStation.code,
    'responding' => OfficeStation.review,
    _ => OfficeStation.review,
  };
}

class OfficeProject {
  OfficeProject(this.id, this.name, this.chats);
  final String id;
  final String name;
  final List<ChatSummary> chats;
}

/// Host and full path keep identically named projects on different PCs apart.
List<OfficeProject> officeProjects(List<ChatSummary> chats) {
  final rooms = <String, OfficeProject>{};
  for (final chat in chats) {
    final path = chat.folderPath;
    final folder = path != null && path.isNotEmpty
        ? path
        : chat.folderId ?? chat.folderName;
    final id = '${chat.hostId}:$folder';
    final name = chat.folderName == 'No folder'
        ? 'Common room'
        : chat.folderName;
    (rooms[id] ??= OfficeProject(id, name, [])).chats.add(chat);
  }
  for (final room in rooms.values) {
    room.chats.sort(compareMonitorChats);
  }
  return rooms.values.toList();
}
