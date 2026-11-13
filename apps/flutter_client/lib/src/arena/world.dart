// The Arena world: one room per recent project, laid out on a pannable map.
// Everything here is pure (no Flutter widgets) so layout and "who stands where"
// are unit-testable. Units are art pixels; one floor tile is [tile] pixels.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;
import '../chats/chat_models.dart';

const double tile = 16;

/// How long a project stays on the map after its last activity.
const recentWindow = Duration(days: 7);
const maxRooms = 12;
const maxAgentsPerRoom = 12;

/// What an agent is doing, as the world shows it.
enum Pose {
  /// Sitting at its desk, typing.
  typing,

  /// Standing at the bookshelves (reading, searching, browsing).
  researching,

  /// At the server rack (running a command).
  running,

  /// At the help desk by the door: blocked until you act.
  asking,

  /// In the lounge with a speech bubble: finished, with a follow-up for you.
  yourTurn,

  /// In the lounge, finished.
  resting,

  /// At its desk with smoke: the last turn failed.
  failed,

  /// Asleep at its desk: nothing for a while.
  sleeping,
}

/// One agent's place in the world.
class WorldAgent {
  WorldAgent({
    required this.chat,
    required this.pose,
    required this.desk,
    required this.spot,
    required this.isBoss,
    required this.number,
  });
  final ChatSummary chat;
  final Pose pose;

  /// Its own desk (seat spot), where it types, fails or sleeps.
  final Spot desk;

  /// Where it is going for [pose].
  final Spot spot;

  /// Leads worker sessions in this room.
  final bool isBoss;

  /// 1-based number inside its room, for accessibility labels.
  final int number;
  String get id => chat.id;
}

/// A place an agent can stand. [lane] is the x of the free column next to it,
/// so paths walk around desks instead of through them.
class Spot {
  const Spot(this.pos, {double? lane, this.facing = Facing.down})
    : lane = lane ?? -1;
  final Offset pos;
  final double lane;
  final Facing facing;
  double get laneX => lane < 0 ? pos.dx : lane;
}

enum Facing { up, down, left, right }

class WorldRoom {
  WorldRoom({
    required this.id,
    required this.name,
    required this.path,
    required this.rect,
    required this.desksPerRow,
    required this.deskRows,
    required this.agents,
    required this.hidden,
    required this.desks,
    required this.shelfSpots,
    required this.serverSpots,
    required this.loungeSpots,
    required this.helpSpots,
    this.compact = false,
  });
  final String id;
  final String name;
  final String? path;

  /// Room bounds in world pixels, walls included.
  final Rect rect;
  final int desksPerRow;
  final int deskRows;
  final List<WorldAgent> agents;

  /// Older chats of this project that did not get a desk.
  final int hidden;
  final List<Spot> desks;
  final List<Spot> shelfSpots;
  final List<Spot> serverSpots;
  final List<Spot> loungeSpots;
  final List<Spot> helpSpots;

  /// A small room, so a phone sees several projects and their agents at once.
  final bool compact;

  /// Interior geometry (world pixels), shared with the painter.
  double get wallHeight => (compact ? 2 : 3) * tile;
  double get researchWidth => (compact ? 2.5 : 4) * tile;
  double get rightWidth => (compact ? 2.5 : 5) * tile;
  double get deskLeft =>
      rect.left + 4 + researchWidth + tile * (compact ? .25 : .5);
  double get rightLeft =>
      deskLeft + desksPerRow * 3 * tile + tile * (compact ? .25 : .5);
  Rect get floor => Rect.fromLTRB(
    rect.left + 4,
    rect.top + wallHeight,
    rect.right - 4,
    rect.bottom - 4,
  );
  double get aisleY => rect.bottom - tile * (compact ? 1 : 1.2);
  Offset get door => Offset(rect.center.dx, rect.bottom);
  Offset deskOrigin(int i) => Offset(
    deskLeft + (i % desksPerRow) * 3 * tile,
    rect.top + wallHeight + tile * 0.5 + (i ~/ desksPerRow) * 3 * tile,
  );

  int get needsYou => agents.where((a) => a.pose == Pose.asking).length;
  int get yourTurn => agents.where((a) => a.pose == Pose.yourTurn).length;
  int get working => agents
      .where(
        (a) =>
            a.pose == Pose.typing ||
            a.pose == Pose.researching ||
            a.pose == Pose.running,
      )
      .length;
  int get failed => agents.where((a) => a.pose == Pose.failed).length;

  /// What is happening in this room, most urgent first.
  String get summary {
    final blocked = needsYou + failed;
    if (blocked > 0) return '$blocked need you';
    if (yourTurn > 0) return '$yourTurn your turn';
    if (working > 0) return '$working working';
    return 'quiet';
  }
}

class World {
  World(this.rooms, this.size);
  final List<WorldRoom> rooms;
  final Size size;
  Iterable<WorldAgent> get agents => rooms.expand((r) => r.agents);
  WorldRoom? roomOf(String chatId) =>
      rooms.where((r) => r.agents.any((a) => a.id == chatId)).firstOrNull;
  WorldAgent? agent(String chatId) =>
      agents.where((a) => a.id == chatId).firstOrNull;
}

/// The pose for a chat. [asking] are chat ids with a prompt waiting on the phone.
Pose poseFor(ChatSummary chat, {Set<String> asking = const {}, DateTime? now}) {
  if (asking.contains(chat.id)) return Pose.asking;
  final state = chat.liveState;
  if (state == 'waiting') return Pose.asking;
  if (state == 'failed') return Pose.failed;
  if (state == 'turn') return Pose.yourTurn;
  if (state == 'working') {
    return switch (chat.live?.activity ?? chat.json['activity']) {
      'reading' || 'searching' || 'browsing' => Pose.researching,
      'running-command' => Pose.running,
      _ => Pose.typing,
    };
  }
  final last = chat.lastWriteAt;
  final age = last == null
      ? const Duration(days: 1)
      : (now ?? DateTime.now()).difference(last);
  // The host reports a stopped session as idle unless it was marked completed.
  return (state == 'done' || state == 'idle') && age < const Duration(hours: 3)
      ? Pose.resting
      : Pose.sleeping;
}

int _poseRank(Pose p) => switch (p) {
  Pose.asking => 0,
  Pose.failed => 1,
  Pose.yourTurn => 2,
  Pose.typing || Pose.researching || Pose.running => 3,
  Pose.resting => 4,
  Pose.sleeping => 5,
};

bool _active(Pose p) => _poseRank(p) <= 3;

/// Reception counter beside a room's entrance: starts a chat in that project.
Rect receptionRect(WorldRoom room) => Rect.fromLTWH(
  room.door.dx + tile * 1.1,
  room.rect.bottom - tile * 2.2 - 20,
  30,
  30,
);

/// Groups chats into project rooms and lays the rooms out on a map.
World buildWorld(
  List<ChatSummary> chats, {
  Set<String> asking = const {},
  DateTime? now,
  double viewportWidth = 400,
}) {
  final clock = now ?? DateTime.now();
  final groups = <String, List<ChatSummary>>{};
  final names = <String, String>{};
  final paths = <String, String?>{};
  for (final chat in chats) {
    if (chat.archived) continue;
    final path = chat.folderPath;
    final folder = path != null && path.isNotEmpty
        ? path
        : chat.folderId ?? chat.folderName;
    final id = '${chat.hostId}:$folder';
    (groups[id] ??= []).add(chat);
    names[id] = chat.folderName == 'No folder'
        ? 'Common room'
        : chat.folderName;
    paths[id] = path;
  }

  final poses = {
    for (final c in chats) c.id: poseFor(c, asking: asking, now: clock),
  };
  final recent = clock.subtract(recentWindow);
  final picked = <({String id, List<ChatSummary> chats, int hidden})>[];
  for (final entry in groups.entries) {
    final list = [...entry.value]
      ..sort((a, b) {
        final r = _poseRank(poses[a.id]!).compareTo(_poseRank(poses[b.id]!));
        if (r != 0) return r;
        return (b.activity?.millisecondsSinceEpoch ?? 0).compareTo(
          a.activity?.millisecondsSinceEpoch ?? 0,
        );
      });
    final keep = list
        .where(
          (c) => _active(poses[c.id]!) || c.activity?.isAfter(recent) == true,
        )
        .toList();
    if (keep.isEmpty) continue;
    // Active agents always get a desk; quiet ones fill what is left of the cap.
    final busy = keep.where((c) => _active(poses[c.id]!)).toList();
    final quiet = keep.where((c) => !_active(poses[c.id]!));
    final desks = [
      ...busy,
      ...quiet.take(math.max(0, maxAgentsPerRoom - busy.length)),
    ]..sort((a, b) => a.id.compareTo(b.id)); // Desks survive state changes.
    picked.add((
      id: entry.key,
      chats: desks,
      hidden: list.length - desks.length,
    ));
  }

  // Rooms that need you first, then by their most urgent agent, then by recency.
  int latest(List<ChatSummary> c) =>
      c.map((x) => x.activity?.millisecondsSinceEpoch ?? 0).reduce(math.max);
  picked.sort((a, b) {
    final r = _rankOf(a.chats, poses).compareTo(_rankOf(b.chats, poses));
    return r != 0 ? r : latest(b.chats).compareTo(latest(a.chats));
  });
  // The cap only drops quiet rooms: an active agent always stays on the map.
  final rooms = [
    for (final (i, room) in picked.indexed)
      if (i < maxRooms || room.chats.any((c) => _active(poses[c.id]!))) room,
  ];

  // Several projects on a phone get small rooms, so they share the screen.
  final compact = rooms.length >= 2 && viewportWidth < 700;

  // Rooms flow in rows; a narrow phone gets one or two columns.
  final columns = rooms.length <= 1
      ? 1
      : rooms.length <= 6 || viewportWidth < 700
      ? 2
      : 3;
  final margin = (compact ? .5 : 3) * tile;
  final gap = (compact ? 1 : 4) * tile;
  final rowGap = (compact ? 2 : 4) * tile;
  final out = <WorldRoom>[];
  var y = compact ? tile * 1.5 : margin + tile * 2;
  double width = 0;
  for (var row = 0; row * columns < rooms.length; row++) {
    var x = margin;
    var rowHeight = 0.0;
    for (var col = 0; col < columns; col++) {
      final i = row * columns + col;
      if (i >= rooms.length) break;
      final r = rooms[i];
      final room = _layoutRoom(
        r.id,
        names[r.id]!,
        paths[r.id],
        Offset(x, y),
        _withBosses(r.chats),
        r.hidden,
        poses,
        // A phone gets taller rooms, so people stay big enough to read.
        maxPerRow: compact ? 2 : (viewportWidth < 500 ? 3 : 4),
        compact: compact,
      );
      out.add(room);
      x = room.rect.right + gap;
      rowHeight = math.max(rowHeight, room.rect.height);
    }
    width = math.max(width, x - gap + margin);
    y += rowHeight + rowGap;
  }
  return World(
    out,
    Size(math.max(width, 20 * tile), y - rowGap + margin + tile),
  );
}

/// A room's most urgent pose rank.
int _rankOf(List<ChatSummary> chats, Map<String, Pose> poses) =>
    chats.map((c) => _poseRank(poses[c.id]!)).reduce(math.min);

/// Orchestrators first, each followed by its workers, so they sit together.
List<ChatSummary> _withBosses(List<ChatSummary> chats) {
  final ids = {for (final c in chats) c.id};
  final workers = <String, List<ChatSummary>>{};
  final rest = <ChatSummary>[];
  for (final c in chats) {
    final parent = c.parentId;
    if (parent != null && ids.contains(parent)) {
      (workers[parent] ??= []).add(c);
    } else {
      rest.add(c);
    }
  }
  return [
    for (final c in rest) ...[c, ...?workers[c.id]],
  ];
}

WorldRoom _layoutRoom(
  String id,
  String name,
  String? path,
  Offset origin,
  List<ChatSummary> chats,
  int hidden,
  Map<String, Pose> poses, {
  int maxPerRow = 4,
  bool compact = false,
}) {
  final count = math.max(chats.length, 2);
  final perRow = math.min(maxPerRow, count);
  final rows = (count / perRow).ceil();
  final wall = (compact ? 2 : 3) * tile;
  final research = (compact ? 2.5 : 4) * tile;
  final deskGap = (compact ? .25 : .5) * tile;
  final width = compact
      ? research + deskGap * 2 + perRow * 3 * tile + 2.5 * tile + 8
      : (4 + perRow * 3 + 1 + 5) * tile + 8;
  final height = compact
      ? wall + rows * 3 * tile + tile * 1.8 + 4
      : wall + math.max(rows * 3 * tile + tile, 6 * tile) + tile * 2 + 4;
  final rect = Rect.fromLTWH(origin.dx, origin.dy, width, height);

  final left = rect.left + 4;
  final top = rect.top + wall;
  final deskLeft = left + research + deskGap;
  final rightLeft = deskLeft + perRow * 3 * tile + deskGap;
  final aisle = rect.bottom - tile * (compact ? 1 : 1.2);

  final desks = [
    for (var i = 0; i < count; i++)
      Spot(
        Offset(
          deskLeft + (i % perRow) * 3 * tile + tile,
          top + tile * 0.5 + (i ~/ perRow) * 3 * tile + tile * 2.1,
        ),
        lane: deskLeft + (i % perRow) * 3 * tile + tile * 2.5,
        facing: Facing.up,
      ),
  ];
  final shelfSpots = [
    for (var i = 0; i < 6; i++)
      Spot(
        compact
            ? Offset(
                left + tile * (0.7 + (i % 2) * 1.15),
                top + tile * (1.5 + (i ~/ 2) * .9),
              )
            : Offset(
                left + tile * (0.9 + (i % 3) * 1.1),
                top + tile * (1.6 + (i ~/ 3) * 2.2),
              ),
        facing: Facing.up,
      ),
  ];
  final serverSpots = [
    for (var i = 0; i < 4; i++)
      Spot(
        compact
            ? Offset(
                rightLeft + tile * (0.7 + (i % 2) * 1.15),
                top + tile * (1.3 + (i ~/ 2) * .5),
              )
            : Offset(
                rightLeft + tile * (0.8 + (i % 2) * 1.3),
                top + tile * (1.5 + (i ~/ 2) * 1.2),
              ),
        facing: Facing.up,
      ),
  ];
  final loungeTop = top + tile * (compact ? 2.3 : 3.6);
  final loungeSpots = [
    for (var i = 0; i < 8; i++)
      Spot(
        compact
            ? Offset(
                rightLeft + tile * (0.7 + (i % 2) * 1.15),
                loungeTop + tile * (1.3 + (i ~/ 2) * .4),
              )
            : Offset(
                rightLeft + tile * (0.9 + (i % 3) * 1.25),
                loungeTop + tile * (0.4 + (i ~/ 3) * 1.25),
              ),
      ),
  ];
  final door = rect.center.dx;
  final helpSpots = [
    for (var i = 0; i < 8; i++)
      Spot(
        Offset(
          door + (i.isEven ? -1 : 1) * tile * (1.2 + (i ~/ 2) * 1.1),
          aisle,
        ),
      ),
  ];

  final agents = <WorldAgent>[];
  final used = <Pose, int>{};
  Spot take(List<Spot> spots, Pose pose) {
    final n = used[pose] = (used[pose] ?? -1) + 1;
    final base = spots[n % spots.length];
    // More agents than spots: stagger instead of stacking.
    if (n < spots.length) return base;
    return Spot(
      base.pos + Offset(4.0 * (n ~/ spots.length), 3.0 * (n ~/ spots.length)),
      lane: base.lane < 0 ? null : base.lane,
      facing: base.facing,
    );
  }

  final bosses = {for (final c in chats) ?c.parentId};
  for (var i = 0; i < chats.length; i++) {
    final chat = chats[i];
    final pose = poses[chat.id]!;
    final desk = desks[i];
    final spot = switch (pose) {
      Pose.typing || Pose.failed || Pose.sleeping => desk,
      Pose.researching => take(shelfSpots, pose),
      Pose.running => take(serverSpots, pose),
      Pose.asking => take(helpSpots, pose),
      Pose.yourTurn || Pose.resting => take(loungeSpots, Pose.resting),
    };
    agents.add(
      WorldAgent(
        chat: chat,
        pose: pose,
        desk: desk,
        spot: spot,
        isBoss: bosses.contains(chat.id),
        number: i + 1,
      ),
    );
  }
  return WorldRoom(
    id: id,
    name: name,
    path: path,
    rect: rect,
    desksPerRow: perRow,
    deskRows: rows,
    agents: agents,
    hidden: hidden,
    desks: desks,
    shelfSpots: shelfSpots,
    serverSpots: serverSpots,
    loungeSpots: loungeSpots,
    helpSpots: helpSpots,
    compact: compact,
  );
}

/// A walking route from [from] to [to] that keeps to lanes and the aisle.
List<Offset> routeBetween(Offset from, Spot? fromSpot, Spot to, double aisleY) {
  if ((from - to.pos).distance < 1) return [to.pos];
  final open = (fromSpot == null || fromSpot.lane < 0) && to.lane < 0;
  if (open && (from - to.pos).distance < tile * 3) return [to.pos];
  final a = fromSpot?.laneX ?? from.dx;
  final b = to.laneX;
  return [
    Offset(a, from.dy),
    Offset(a, aisleY),
    Offset(b, aisleY),
    Offset(b, to.pos.dy),
    to.pos,
  ];
}
