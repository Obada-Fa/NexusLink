// Draws the Arena world in art pixels. The static layer (grounds, rooms,
// furniture) is recorded once per layout; the live layer (people, screens,
// lights, bubbles) repaints on the scene clock.

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../chats/chat_models.dart';
import '../theme/nexus_theme.dart';
import 'pixel_art.dart';
import 'world.dart';

const _ink = Color(0xFF14121C);
const _wall = Color(0xFF35454D);
const _wallFace = Color(0xFFD4D3BE);
const _wainscot = Color(0xFF779591);
const _wood = Color(0xFFB59A79);
const _woodDark = Color(0xFFA48A6D);
const _carpet = Color(0xFF466B6D);
const _tileA = Color(0xFF6B8184);
const _tileB = Color(0xFF667C7F);
const _rug = Color(0xFF577D78);
const _grass = Color(0xFF294A42);
const _path = Color(0xFF8F9887);

int _hash(int a, [int b = 0, int c = 0]) {
  var h = a * 73856093 ^ b * 19349663 ^ c * 83492791;
  h = (h ^ (h >> 13)) * 1274126177;
  return (h ^ (h >> 16)) & 0x7fffffff;
}

/// 0 at midday, 1 at midnight (smooth), from the phone's local time.
double nightFor(DateTime now) {
  final h = now.hour + now.minute / 60;
  return ((math.cos((h - 13) / 24 * 2 * math.pi) * -1 + 1) / 2).clamp(0, 1) *
          1.25 -
      .25;
}

Color skyFor(double night) => Color.lerp(
  const Color(0xFF8FD3FF),
  const Color(0xFF141A3A),
  night.clamp(0, 1),
)!;

/// Grounds, paths and every room's walls, floors and furniture.
ui.Picture recordStatic(World world, {required double night}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final px = Px(canvas);
  final size = world.size;

  // Grass with tufts and flowers.
  px.r(0, 0, size.width, size.height, _grass);
  for (var y = 0.0; y < size.height; y += 8) {
    for (var x = 0.0; x < size.width; x += 8) {
      final h = _hash(x.toInt(), y.toInt());
      if (h % 17 == 0) {
        px.r(x + h % 7, y + h % 5, 2, 1, const Color(0xFF35594D));
      }
      if (h % 31 == 0) {
        px.r(x + h % 6, y + h % 4, 1, 2, const Color(0xFF234339));
      }
      if (h % 257 == 0) {
        px.r(
          x + 2,
          y + 2,
          2,
          2,
          [
            const Color(0xFFF2D16B),
            const Color(0xFFE88AA8),
            const Color(0xFFEDEDED),
          ][h % 3],
        );
      }
    }
  }

  // Paths: a street under each row of doors, joined by lanes between columns.
  final rows = <double, List<WorldRoom>>{};
  for (final r in world.rooms) {
    (rows[r.rect.top] ??= []).add(r);
  }
  for (final row in rows.values) {
    final bottom = row.map((r) => r.rect.bottom).reduce(math.max);
    final y = bottom + tile * 1.2;
    _road(px, 0, y, size.width, tile * 1.1);
    for (final r in row) {
      _road(
        px,
        r.door.dx - tile * .7,
        r.rect.bottom,
        tile * 1.4,
        y - r.rect.bottom,
      );
    }
  }
  final firstRoomTop = world.rooms.isEmpty ? 0.0 : world.rooms.first.rect.top;
  for (final r in world.rooms) {
    if (r.rect.left > tile * 4) {
      _road(
        px,
        r.rect.left - tile * 2.6,
        firstRoomTop,
        tile * 1.1,
        size.height - firstRoomTop,
      );
    }
  }

  // Trees, lamps and benches on the grass, seeded so they never move.
  bool clear(Rect r) =>
      !world.rooms.any((room) => room.rect.inflate(tile * 1.5).overlaps(r));
  for (var i = 0; i < (size.width * size.height / 9000).round(); i++) {
    final h = _hash(i, 7);
    final p = Offset(
      (h % size.width.toInt()).toDouble(),
      ((h ~/ 3) % size.height.toInt()).toDouble(),
    );
    final box = Rect.fromCenter(center: p, width: 26, height: 30);
    if (!clear(box)) continue;
    if (h % 9 == 0) {
      _bench(px, p);
    } else if (h % 13 == 0) {
      _lampPost(px, p);
    } else {
      _tree(px, p, h);
    }
  }

  for (final room in world.rooms) {
    _room(canvas, px, room, night);
  }
  return recorder.endRecording();
}

void _road(Px px, double x, double y, double w, double h) {
  px.r(x, y, w, h, _path);
  for (var yy = y; yy < y + h; yy += 6) {
    for (var xx = x; xx < x + w; xx += 6) {
      final k = _hash(xx.toInt(), yy.toInt(), 3);
      if (k % 4 == 0) {
        px.r(xx + k % 4, yy + k % 3, 2, 1, const Color(0xFF7A715F));
      }
    }
  }
}

void _tree(Px px, Offset p, int h) {
  final x = p.dx, y = p.dy;
  px.r(x - 9, y + 9, 20, 4, const Color(0x55000000));
  px.r(x - 2, y + 2, 4, 9, const Color(0xFF5B3A26));
  final leaf = [
    const Color(0xFF52806A),
    const Color(0xFF65947B),
    const Color(0xFF416C5D),
  ][h % 3];
  px.r(x - 9, y - 10, 18, 13, _ink);
  px.r(x - 8, y - 12, 16, 15, leaf);
  px.r(x - 10, y - 7, 20, 8, leaf);
  px.r(x - 6, y - 11, 6, 3, tint(leaf, .25));
  px.r(x - 8, y - 1, 16, 2, shade(leaf, .75));
}

void _bench(Px px, Offset p) {
  px.r(p.dx - 9, p.dy + 4, 18, 2, const Color(0x55000000));
  px.block(p.dx - 8, p.dy - 2, 16, 3, const Color(0xFF9A6A43));
  px.r(p.dx - 7, p.dy + 1, 2, 3, _ink);
  px.r(p.dx + 5, p.dy + 1, 2, 3, _ink);
}

void _lampPost(Px px, Offset p) {
  px.r(p.dx - 1, p.dy - 14, 2, 18, const Color(0xFF2A2735));
  px.block(p.dx - 3, p.dy - 18, 6, 4, const Color(0xFFF5E6A8));
}

void _room(Canvas canvas, Px px, WorldRoom room, double night) {
  final r = room.rect;
  final top = r.top + room.wallHeight;
  final left = r.left + 4;
  final deskLeft = left + room.researchWidth + tile * .5;
  final rightLeft = deskLeft + room.desksPerRow * 3 * tile + tile * .5;

  // Shadow, walls and the back wall face.
  px.r(r.left + 4, r.top + 6, r.width, r.height, const Color(0x66000000));
  px.r(r.left - 1, r.top - 1, r.width + 2, r.height + 2, _ink);
  px.r(r.left, r.top, r.width, r.height, _wall);
  px.r(left, r.top + 4, r.width - 8, room.wallHeight - 4, _wallFace);
  px.r(left, top - 10, r.width - 8, 8, _wainscot);
  px.r(left, top - 3, r.width - 8, 3, shade(_wainscot, .7));
  for (var x = left + 3; x < r.right - 6; x += 24) {
    px.r(x, top - 9, 1, 6, shade(_wainscot, .8));
  }

  // Floors per zone.
  final floor = Rect.fromLTRB(left, top, r.right - 4, r.bottom - 4);
  px.r(floor.left, floor.top, floor.width, floor.height, _wood);
  canvas.save();
  canvas.clipRect(floor);
  for (var y = floor.top; y < floor.bottom; y += 10) {
    px.r(floor.left, y + 9, floor.width, 1, _woodDark);
    final row = ((y - floor.top) / 10).floor();
    for (var x = floor.left + (row.isEven ? 0 : 18); x < floor.right; x += 36) {
      px.r(x, y, 1, 9, _woodDark);
      if (_hash(x.toInt(), y.toInt()) % 7 == 0) {
        px.r(x + 6, y + 2, 2, 1, tint(_wood, .15));
      }
    }
  }
  canvas.restore();
  final research = Rect.fromLTWH(
    left,
    top,
    room.researchWidth,
    floor.height - tile * 1.6,
  );
  px.r(research.left, research.top, research.width, research.height, _carpet);
  for (var y = research.top + 3; y < research.bottom; y += 12) {
    for (var x = research.left + 3; x < research.right; x += 12) {
      px.r(x, y, 1, 1, tint(_carpet, .07));
    }
  }
  final server = Rect.fromLTWH(
    rightLeft,
    top,
    r.right - 4 - rightLeft,
    tile * 3.2,
  );
  for (var y = server.top; y < server.bottom; y += 8) {
    for (var x = server.left; x < server.right; x += 8) {
      px.r(
        x,
        y,
        8,
        8,
        ((x - server.left) ~/ 8 + (y - server.top) ~/ 8).isEven
            ? _tileA
            : _tileB,
      );
    }
  }
  final lounge = Rect.fromLTWH(
    rightLeft + 2,
    top + tile * 3.4,
    r.right - 8 - rightLeft,
    tile * 3.4,
  );
  px.r(lounge.left, lounge.top, lounge.width, lounge.height, _ink);
  px.r(
    lounge.left + 1,
    lounge.top + 1,
    lounge.width - 2,
    lounge.height - 2,
    _rug,
  );
  px.r(
    lounge.left + 3,
    lounge.top + 3,
    lounge.width - 6,
    lounge.height - 6,
    tint(_rug, .12),
  );
  px.r(
    lounge.left + 5,
    lounge.top + 5,
    lounge.width - 10,
    lounge.height - 10,
    _rug,
  );

  // Windows along the back wall, skipping the whiteboard and the rack.
  final sky = skyFor(night);
  for (var x = left + tile * .6; x < r.right - tile * 1.6; x += tile * 2.6) {
    if (x > deskLeft + tile &&
        x < rightLeft - tile &&
        room.desksPerRow >= 2 &&
        (x - (deskLeft + room.desksPerRow * 1.5 * tile)).abs() < tile * 2) {
      continue;
    }
    if (x > rightLeft - tile * .5 && x < rightLeft + tile * 2) continue;
    _window(px, x, r.top + 9, sky, night);
  }

  // Whiteboard over the desks (its content is live).
  final board = _boardRect(room);
  px.block(
    board.left,
    board.top,
    board.width,
    board.height,
    const Color(0xFF8A93A6),
  );
  px.r(
    board.left + 2,
    board.top + 2,
    board.width - 4,
    board.height - 5,
    const Color(0xFFEEF2F6),
  );
  px.r(
    board.left + 4,
    board.bottom - 2,
    board.width - 8,
    2,
    const Color(0xFF6B7385),
  );

  // Research corner: two bookcases, a reading lamp, a plant.
  for (var i = 0; i < 2; i++) {
    _bookcase(px, left + 4 + i * 30, top - 22, i + room.id.length);
  }
  _plant(px, Offset(left + 7, r.bottom - tile * 1.9), 1);

  // Desks: each with a monitor (screen drawn live), keyboard, mug and a stool.
  for (var i = 0; i < room.desks.length; i++) {
    _desk(px, room.deskOrigin(i), i);
    final seat = room.desks[i].pos;
    px.r(seat.dx - 5, seat.dy - 3, 10, 3, const Color(0xFF2A2638));
    px.r(seat.dx - 4, seat.dy - 3, 8, 1, const Color(0xFF4D4766));
  }

  // Server corner: a rack (LEDs live), a terminal desk.
  _rack(px, _rackRect(room));
  px.block(
    rightLeft + tile * 2.4,
    top + 2,
    tile * 2,
    8,
    const Color(0xFF4B4F5E),
  );
  px.r(rightLeft + tile * 2.8, top - 6, 14, 9, _ink);
  px.r(rightLeft + tile * 2.8 + 1, top - 5, 12, 7, const Color(0xFF0E1A14));

  // Lounge: sofa, coffee machine, plant.
  px.block(
    lounge.left + 6,
    lounge.top - 6,
    lounge.width - 26,
    9,
    const Color(0xFFC08B52),
  );
  px.r(
    lounge.left + 6,
    lounge.top - 6,
    lounge.width - 26,
    3,
    const Color(0xFFD8AB70),
  );
  px.block(lounge.left + 4, lounge.top - 4, 4, 9, const Color(0xFF996C44));
  px.block(lounge.right - 24, lounge.top - 4, 4, 9, const Color(0xFF996C44));
  _coffee(px, Offset(lounge.right - 9, lounge.top - 2));
  _plant(px, Offset(lounge.right - 8, lounge.bottom - 6), 2);

  // Bottom wall with the door and a help desk beside it.
  final door = room.door;
  px.r(door.dx - tile, r.bottom - 5, tile * 2, 5, const Color(0xFF6F6A5E));
  px.r(
    door.dx - tile + 2,
    r.bottom - 4,
    tile * 2 - 4,
    3,
    const Color(0xFFB8A97C),
  );
  final help = Offset(door.dx + tile * 1.1, r.bottom - tile * 2.2);
  px.block(help.dx, help.dy, 22, 7, const Color(0xFFA77B4F));
  px.r(help.dx + 15, help.dy - 3, 4, 3, const Color(0xFFE2C35A));
  px.r(help.dx + 16, help.dy - 4, 2, 1, const Color(0xFFF5E6A8));
  _floorMark(px, Offset(door.dx, room.aisleY + 2));

  // Name plate above the room.
  _plate(canvas, px, room);
}

Rect _boardRect(WorldRoom room) {
  final deskLeft = room.rect.left + 4 + room.researchWidth + tile * .5;
  final mid = deskLeft + room.desksPerRow * 1.5 * tile;
  final w = math.min(room.desksPerRow * 2.2 * tile, tile * 6);
  return Rect.fromLTWH(mid - w / 2, room.rect.top + 8, w, tile * 1.7);
}

Rect _rackRect(WorldRoom room) {
  final deskLeft = room.rect.left + 4 + room.researchWidth + tile * .5;
  final rightLeft = deskLeft + room.desksPerRow * 3 * tile + tile * .5;
  return Rect.fromLTWH(
    rightLeft + 4,
    room.rect.top + room.wallHeight - 30,
    22,
    40,
  );
}

void _window(Px px, double x, double y, Color sky, double night) {
  px.block(x, y, 26, 18, const Color(0xFF2B2639));
  px.r(x + 2, y + 2, 22, 14, sky);
  if (night > .5) {
    for (var i = 0; i < 4; i++) {
      final h = _hash(x.toInt(), i);
      px.r(
        x + 3 + h % 19,
        y + 3 + (h ~/ 5) % 10,
        1,
        1,
        const Color(0xFFE9ECFF),
      );
    }
  } else {
    px.r(x + 4, y + 4, 6, 1, tint(sky, .5));
    px.r(x + 4, y + 5, 3, 1, tint(sky, .5));
  }
  px.r(x + 12, y + 2, 2, 14, const Color(0xFF2B2639));
  px.r(x + 2, y + 8, 22, 1, const Color(0xFF2B2639));
}

void _bookcase(Px px, double x, double y, int seed) {
  px.block(x, y, 26, 34, const Color(0xFF6A4630));
  const colors = [
    Color(0xFFC9524A),
    Color(0xFF4A8CC9),
    Color(0xFFE3B341),
    Color(0xFF5CAB6A),
    Color(0xFF9B6BD1),
    Color(0xFFE08A5E),
    Color(0xFFDCD6C8),
  ];
  for (var shelf = 0; shelf < 3; shelf++) {
    final sy = y + 3 + shelf * 10;
    px.r(x + 2, sy + 8, 22, 2, const Color(0xFF4D311F));
    var bx = x + 3;
    var k = 0;
    while (bx < x + 23) {
      final h = _hash(seed, shelf, k++);
      final w = 2 + h % 2.0;
      final bh = 6 + h % 3.0;
      px.r(bx, sy + 8 - bh, w, bh, colors[h % colors.length]);
      px.r(bx, sy + 8 - bh, w, 1, tint(colors[h % colors.length], .3));
      bx += w + (h % 5 == 0 ? 2 : 0);
    }
  }
}

void _desk(Px px, Offset o, int i) {
  final x = o.dx, y = o.dy;
  // Oak top, inset drawer and slim legs, with one consistent light direction.
  px.r(x + 1, y + 14, 32, 13, const Color(0x260F2428));
  px.r(x + 2, y + 20, 2, 6, const Color(0xFF394A50));
  px.r(x + 28, y + 20, 2, 6, const Color(0xFF394A50));
  px.block(x, y + 10, 32, 11, const Color(0xFFD2AF7C));
  px.r(x + 1, y + 11, 30, 1, const Color(0xFFEBD2A4));
  px.r(x + 1, y + 19, 30, 2, const Color(0xFFAE875B));
  px.r(x + 23, y + 22, 7, 2, const Color(0xFFB38E63));
  px.r(x + 25, y + 22, 3, 1, const Color(0xFFE4C899));
  // Monitor bezel, stand and a small power indicator.
  px.block(x + 6, y - 4, 20, 14, const Color(0xFF44565D));
  px.r(x + 8, y - 2, 16, 11, const Color(0xFF20363F));
  px.r(x + 23, y + 9, 1, 1, const Color(0xFF96CAB7));
  px.r(x + 15, y + 10, 2, 3, const Color(0xFF44565D));
  px.r(x + 12, y + 12, 8, 1, const Color(0xFF60777B));
  px.r(x + 10, y + 15, 12, 3, const Color(0xFF738888));
  px.r(x + 11, y + 15, 10, 1, const Color(0xFFB6C7BB));
  px.r(x + 24, y + 16, 2, 2, const Color(0xFF61787A));
  if (i.isEven) {
    px.r(x + 3, y + 13, 3, 4, const Color(0xFFF2E4CA));
    px.r(x + 6, y + 14, 1, 2, const Color(0xFFF2E4CA));
    px.r(x + 3, y + 13, 3, 1, const Color(0xFF73533F));
  } else {
    px.r(x + 3, y + 14, 5, 4, const Color(0xFF678F85));
    px.r(x + 4, y + 14, 1, 4, const Color(0xFFB6CEB8));
  }
}

Rect screenRect(WorldRoom room, int i) {
  final o = room.deskOrigin(i);
  return Rect.fromLTWH(o.dx + 8, o.dy - 2, 16, 11);
}

void _rack(Px px, Rect r) {
  px.block(r.left, r.top, r.width, r.height, const Color(0xFF242733));
  for (var y = r.top + 3; y < r.bottom - 4; y += 6) {
    px.r(r.left + 2, y, r.width - 4, 4, const Color(0xFF30344A));
    px.r(r.left + 3, y + 1, 9, 1, const Color(0xFF1A1C26));
  }
}

void _coffee(Px px, Offset p) {
  px.block(p.dx - 5, p.dy - 12, 10, 14, const Color(0xFF8C9199));
  px.r(p.dx - 3, p.dy - 9, 6, 3, _ink);
  px.r(p.dx - 2, p.dy - 4, 4, 3, const Color(0xFFEDEDED));
}

void _plant(Px px, Offset p, int kind) {
  px.r(p.dx - 6, p.dy + 3, 12, 2, const Color(0x44000000));
  px.block(p.dx - 4, p.dy - 4, 8, 7, const Color(0xFFB5643D));
  final leaf = kind.isEven ? const Color(0xFF65947B) : const Color(0xFF5DAE63);
  px.r(p.dx - 6, p.dy - 13, 5, 9, leaf);
  px.r(p.dx + 1, p.dy - 15, 5, 11, leaf);
  px.r(p.dx - 2, p.dy - 17, 4, 12, tint(leaf, .15));
}

void _floorMark(Px px, Offset c) {
  const y = Color(0xFFE2C35A);
  px.r(c.dx - 7, c.dy - 1, 14, 1, y);
  px.r(c.dx - 7, c.dy + 5, 14, 1, y);
  px.r(c.dx - 8, c.dy, 1, 5, y);
  px.r(c.dx + 7, c.dy, 1, 5, y);
}

void _plate(Canvas canvas, Px px, WorldRoom room) {
  final r = room.rect;
  final text = TextPainter(
    text: TextSpan(
      text: room.name.length > 26
          ? '${room.name.substring(0, 25)}…'
          : room.name,
      style: const TextStyle(
        fontFamily: 'Roboto',
        color: Color(0xFFF7E9C6),
        fontSize: 9,
        fontWeight: FontWeight.w800,
        letterSpacing: .4,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final w = text.width + 16;
  final x = r.left + 6;
  final y = r.top - 17;
  px.block(x, y, w, 14, const Color(0xFF354D52));
  px.r(x + 2, y + 2, 2, 10, const Color(0xFFBBD6BE));
  px.r(x + 4, y + 14, 2, 3, _ink);
  px.r(x + w - 6, y + 14, 2, 3, _ink);
  text.paint(canvas, Offset(x + 8, y + 7 - text.height / 2));
  text.dispose();
}

/// Where a person is drawn this frame, and how.
class Actor {
  Actor({
    required this.agent,
    required this.look,
    required this.pos,
    required this.moving,
    required this.dir,
  });
  final WorldAgent agent;
  final Look look;
  final Offset pos;
  final bool moving;

  /// Unit direction while moving.
  final Offset dir;
}

class Burst {
  Burst(this.at, this.start, {this.smoke = false});
  final Offset at;
  final int start;
  final bool smoke;
}

/// Two independently ellipsized lines: long names never displace the status.
class AgentTag {
  AgentTag({
    required this.key,
    required String title,
    required String status,
    required this.color,
    required double fontSize,
    required double maxWidth,
  }) : title = _line(title, const Color(0xFFF4F1E6), fontSize, maxWidth),
       status = _line(status, color, fontSize * .9, maxWidth);

  final String key;
  final Color color;
  final TextPainter title;
  final TextPainter status;
  double get width => math.max(title.width, status.width);
  double get height => title.height + status.height + 1;

  static TextPainter _line(
    String text,
    Color color,
    double size,
    double width,
  ) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Roboto',
        color: color,
        fontSize: size,
        fontWeight: FontWeight.w600,
        height: 1.1,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: width);

  void paint(Canvas canvas, Offset offset) {
    title.paint(canvas, offset);
    status.paint(canvas, offset + Offset(0, title.height + 1));
  }

  void dispose() {
    title.dispose();
    status.dispose();
  }
}

/// Everything the live layer needs for one frame.
class Frame {
  Frame({
    required this.world,
    required this.actors,
    required this.clockMs,
    required this.night,
    required this.zoom,
    required this.offline,
    required this.reduced,
    required this.selected,
    required this.bursts,
    required this.tags,
  });
  final World world;
  final List<Actor> actors;
  final int clockMs;
  final double night;
  final double zoom;
  final bool offline;
  final bool reduced;
  final String? selected;
  final List<Burst> bursts;

  /// Pre-laid-out name tags by chat id.
  final Map<String, AgentTag> tags;
}

class LivePainter extends CustomPainter {
  LivePainter(this.frame, this.sprites, {super.repaint});
  final Frame Function() frame;
  final SpriteBook sprites;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame();
    final px = Px(canvas);
    final t = f.reduced ? 0 : f.clockMs;
    canvas.save();
    canvas.scale(size.width / f.world.size.width);

    for (final room in f.world.rooms) {
      _roomLive(canvas, px, room, f, t);
    }

    final actors = [...f.actors]..sort((a, b) => a.pos.dy.compareTo(b.pos.dy));
    for (final a in actors) {
      _actor(canvas, px, a, f, t);
    }
    for (final b in f.bursts) {
      _burst(px, b, t);
    }

    // Night outside lit rooms, dim rooms with nobody working.
    if (f.night > 0) {
      final dark = Path()..addRect(Offset.zero & f.world.size);
      for (final room in f.world.rooms) {
        if (room.working + room.needsYou + room.failed > 0) {
          dark.addRect(room.rect);
        }
      }
      dark.fillType = PathFillType.evenOdd;
      canvas.drawPath(
        dark,
        Paint()..color = Color.fromRGBO(8, 10, 30, .42 * f.night),
      );
    }
    for (final room in f.world.rooms) {
      if (room.working + room.needsYou + room.failed == 0) {
        canvas.drawRect(room.rect, Paint()..color = const Color(0x180F2428));
      }
    }
    if (f.offline) {
      canvas.drawRect(
        Offset.zero & f.world.size,
        Paint()..color = const Color(0x88101218),
      );
    }
    if (f.zoom >= .4) {
      final occupied = <Rect>[];
      // The selected agent always gets its label; nearby labels never overlap it.
      final labeled = [...actors]
        ..sort((a, b) {
          if (a.agent.id == b.agent.id) return 0;
          if (a.agent.id == f.selected) return -1;
          if (b.agent.id == f.selected) return 1;
          return a.pos.dy.compareTo(b.pos.dy);
        });
      for (final a in labeled) {
        final tag = f.tags[a.agent.id];
        if (tag == null) continue;
        final w = tag.width + 8;
        final x = (a.pos.dx - w / 2).roundToDouble();
        final y = a.pos.dy + 4;
        final rect = Rect.fromLTWH(x, y, w, tag.height + 5);
        if (occupied.any((other) => other.overlaps(rect.inflate(1)))) continue;
        occupied.add(rect);
        px.r(x, y + 1, w, rect.height, const Color(0x330C1B21));
        px.r(x, y, w, rect.height, const Color(0xF023363D));
        px.r(x, y, 1, rect.height, tag.color);
        tag.paint(canvas, Offset(x + 4, y + 2));
      }
    }
    canvas.restore();
  }

  void _roomLive(Canvas canvas, Px px, WorldRoom room, Frame f, int t) {
    if (room.id == 'shared-office') {
      final area = receptionRect(room);
      final receptionist = ChatSummary({
        'id': 'receptionist',
        'source': 'nexuslink',
      });
      sprites.draw(
        canvas,
        front,
        lookFor(receptionist),
        area.center + const Offset(-4, 5),
      );
      final label = TextPainter(
        text: const TextSpan(
          text: 'New chat',
          style: TextStyle(
            color: Color(0xFFF4F1E6),
            fontSize: 7,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      px.r(
        area.left - 3,
        area.top - 10,
        label.width + 6,
        10,
        const Color(0xFF23363D),
      );
      label.paint(canvas, Offset(area.left, area.top - 10));
      label.dispose();
    }

    // Screens.
    for (var i = 0; i < room.desks.length; i++) {
      final s = screenRect(room, i);
      final owner = room.agents
          .where((a) => a.desk == room.desks[i])
          .firstOrNull;
      _screen(px, s, owner, t);
    }
    // Rack LEDs: busy while someone in the room runs a command.
    final rack = _rackRect(room);
    final busy = room.agents.any((a) => a.pose == Pose.running);
    for (var row = 0; row < 6; row++) {
      for (var k = 0; k < 3; k++) {
        final on = busy
            ? _hash(row, k, t ~/ 120) % 3 != 0
            : _hash(row, k, t ~/ 1400) % 4 == 0;
        px.r(
          rack.left + 14 + k * 2.5,
          rack.top + 4 + row * 6,
          1.5,
          1.5,
          on
              ? (k == 2 && busy ? NX.waiting : NX.working)
              : const Color(0xFF1A3A2A),
        );
      }
    }
    // Whiteboard: the most active agent's plan, as a progress strip.
    final board = _boardRect(room);
    final planner = room.agents
        .where((a) => (a.chat.live?.todos ?? const []).isNotEmpty)
        .firstOrNull;
    if (planner != null) {
      final live = planner.chat.live!;
      final total = live.todos.length;
      final done = live.todosDone;
      final w = board.width - 10;
      for (var i = 0; i < total.clamp(0, 12); i++) {
        final x = board.left + 5 + i * (w / total.clamp(1, 12));
        final state = live.todos[i].state;
        px.r(
          x,
          board.top + 5,
          math.max(2, w / total.clamp(1, 12) - 2),
          4,
          state == 'done'
              ? NX.working
              : state == 'active'
              ? NX.accent
              : const Color(0xFFC5CCD8),
        );
      }
      px.r(
        board.left + 5,
        board.top + 12,
        w * done / math.max(total, 1),
        2,
        NX.working,
      );
    } else {
      px.r(
        board.left + 6,
        board.top + 6,
        board.width * .4,
        1,
        const Color(0xFF8A93A6),
      );
      px.r(
        board.left + 6,
        board.top + 10,
        board.width * .25,
        1,
        const Color(0xFF8A93A6),
      );
    }
    // Alarm: a pulsing beacon over the door while someone needs you.
    if (room.needsYou > 0) {
      final pulse = f.reduced ? .6 : (math.sin(t / 180) + 1) / 2;
      final door = room.door;
      final glow = Paint()
        ..shader =
            RadialGradient(
              colors: [
                NX.failed.withValues(alpha: .55 * pulse),
                NX.failed.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: Offset(door.dx, room.rect.bottom - 6),
                radius: 46,
              ),
            );
      canvas.drawCircle(Offset(door.dx, room.rect.bottom - 6), 46, glow);
      px.block(
        door.dx - 3,
        room.rect.bottom - 9,
        6,
        4,
        Color.lerp(const Color(0xFF7A1E22), NX.failed, pulse)!,
      );
    }
    // Warm desk-lamp light while people work.
    if (room.working > 0 && f.night > .2) {
      for (final a in room.agents.where((a) => a.pose == Pose.typing)) {
        final c = a.desk.pos - const Offset(0, 14);
        canvas.drawCircle(
          c,
          28,
          Paint()
            ..shader = RadialGradient(
              colors: [const Color(0x44FFD9A0), const Color(0x00FFD9A0)],
            ).createShader(Rect.fromCircle(center: c, radius: 28)),
        );
      }
    }
  }

  void _screen(Px px, Rect s, WorldAgent? owner, int t) {
    if (owner == null) return;
    final pose = owner.pose;
    switch (pose) {
      case Pose.typing:
        px.r(s.left, s.top, s.width, s.height, const Color(0xFF0F1B2A));
        final activity = owner.chat.live?.activity ?? '';
        if (activity == 'thinking') {
          for (var i = 0; i < 3; i++) {
            final on = (t ~/ 300) % 3 == i;
            px.r(
              s.left + 4 + i * 3.5,
              s.top + 5,
              2,
              2,
              on ? NX.accent : const Color(0xFF2E4A66),
            );
          }
        } else {
          final scroll = (t ~/ 160) % 8;
          for (var i = 0; i < 4; i++) {
            final h = _hash(owner.number, i + scroll);
            px.r(
              s.left + 2 + (h % 3),
              s.top + 2 + i * 2.2,
              4 + h % 8.0,
              1,
              [
                NX.accent,
                NX.working,
                const Color(0xFFE3B341),
                const Color(0xFFC9D1E0),
              ][h % 4],
            );
          }
          if ((t ~/ 400).isEven) {
            px.r(s.left + 12, s.top + 8, 2, 1, Colors.white);
          }
        }
      case Pose.researching || Pose.running || Pose.resting || Pose.yourTurn:
        px.r(s.left, s.top, s.width, s.height, const Color(0xFF16222E));
        px.r(s.left + 3, s.top + 4, 10, 1, const Color(0xFF2E4A66));
      case Pose.asking:
        px.r(s.left, s.top, s.width, s.height, const Color(0xFF3A2C08));
        px.r(s.left + 7, s.top + 2, 2, 5, NX.waiting);
        px.r(s.left + 7, s.top + 8, 2, 1, NX.waiting);
      case Pose.failed:
        px.r(s.left, s.top, s.width, s.height, const Color(0xFF3A0E12));
        for (var i = 0; i < 6; i++) {
          px.r(s.left + 5 + i, s.top + 2 + i, 1, 1, NX.failed);
          px.r(s.left + 10 - i, s.top + 2 + i, 1, 1, NX.failed);
        }
      case Pose.sleeping:
        final c = ((t ~/ 2200) % 3);
        px.r(s.left + 2 + c * 4, s.top + 3 + c, 3, 3, const Color(0xFF1E2E44));
    }
  }

  void _actor(Canvas canvas, Px px, Actor a, Frame f, int t) {
    final agent = a.agent;
    final p = a.pos;
    final atSpot = !a.moving;
    final pose = agent.pose;
    final selected = f.selected == agent.id;

    // Ground shadow (and a selection ring).
    if (selected) {
      final ring = (math.sin(t / 200) + 1) / 2;
      canvas.drawOval(
        Rect.fromCenter(center: p, width: 18 + ring * 3, height: 7 + ring),
        Paint()
          ..color = NX.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    canvas.drawOval(
      Rect.fromCenter(center: p, width: 12, height: 4),
      Paint()..color = const Color(0x55000000),
    );

    Sprite sprite;
    var flip = false;
    var feet = p;
    if (a.moving) {
      final up = a.dir.dy < -.5;
      final step = (t ~/ 140).isEven;
      sprite = up ? back : (step ? walkA : walkB);
      if (up) feet = p - Offset(0, step ? 1 : 0);
      flip = a.dir.dx < -.3;
    } else {
      switch (pose) {
        case Pose.typing:
          sprite = (t ~/ 220).isEven ? typeA : typeB;
        case Pose.failed:
          sprite = typeA;
        case Pose.sleeping:
          sprite = typeA;
          feet = p + const Offset(0, 2);
        case Pose.researching || Pose.running:
          sprite = back;
          feet = p - Offset(0, (t ~/ 600).isEven ? 0 : 1);
        case Pose.asking:
          sprite = front;
          feet = p - Offset(0, (t ~/ 260).isEven ? 0 : 2);
        case Pose.yourTurn:
          sprite = front;
        case Pose.resting:
          // The first lounge row sits on the sofa.
          final row0 = (agent.spot.pos.dy - _loungeTop(f, agent)).abs() < 8;
          sprite = row0 ? sit : front;
      }
    }
    sprites.draw(canvas, sprite, a.look, feet, flip: flip);
    sprites.accessory(canvas, sprite, a.look, feet);
    final head = feet - Offset(0, sprite.height.toDouble());

    if (agent.isBoss) {
      // A small gold crown for orchestrators.
      px.r(head.dx - 3, head.dy - 3, 6, 2, const Color(0xFFE8B931));
      px.r(head.dx - 3, head.dy - 5, 1, 2, const Color(0xFFE8B931));
      px.r(head.dx - .5, head.dy - 5, 1, 2, const Color(0xFFE8B931));
      px.r(head.dx + 2, head.dy - 5, 1, 2, const Color(0xFFE8B931));
    }

    if (!atSpot) return;
    switch (pose) {
      case Pose.asking:
        final kind = agent.chat.live?.waitKind;
        _bubble(
          px,
          head - const Offset(0, 6),
          kind == 'question' ? NX.accent : NX.waiting,
          kind == 'question'
              ? '?'
              : kind == 'plan'
              ? 'plan'
              : '!',
          pulse: f.reduced ? 0 : (math.sin(t / 160) + 1) / 2,
        );
      case Pose.yourTurn:
        _bubble(px, head - const Offset(0, 5), NX.accent, '…');
      case Pose.failed:
        for (var i = 0; i < 3; i++) {
          final k = ((t / 900) + i / 3) % 1;
          final c = head + Offset(4 + i * 2 - k * 3, -k * 14);
          px.r(c.dx, c.dy, 3, 3, Color.fromRGBO(90, 90, 100, (1 - k) * .8));
        }
        px.r(head.dx + 6, head.dy - 4, 3, 3, NX.failed);
      case Pose.sleeping:
        final k = (t / 1600) % 1;
        _z(px, head + Offset(6, -2 - k * 8), (1 - k));
      case Pose.typing || Pose.researching || Pose.running:
        if (f.zoom >= .6) {
          _activityIcon(px, head + const Offset(8, -3), agent, t);
        }
      case Pose.resting:
        break;
    }

    // Sub-agents: little robots that follow their parent.
    final helpers = (agent.chat.live?.subagents ?? const [])
        .where((s) => s.state != 'done')
        .take(3)
        .toList();
    for (var i = 0; i < helpers.length; i++) {
      final s = helpers[i];
      final angle = (f.reduced ? 0 : t / 1400) + i * 2.1;
      final c = p + Offset(math.cos(angle) * 13, 2 + math.sin(angle) * 4);
      final bob = f.reduced ? 0.0 : ((t ~/ 200 + i).isEven ? 0.0 : 1.0);
      final look = Look(
        key: 'bot:${s.state}',
        accessory: 'none',
        palette: {
          'o': _ink,
          'k': const Color(0xFFB9C3D6),
          'c': const Color(0xFF8A96AD),
          'e': const Color(0xFF1B1626),
          'L': s.state == 'waiting' ? NX.waiting : NX.working,
        },
      );
      canvas.drawOval(
        Rect.fromCenter(center: c, width: 8, height: 3),
        Paint()..color = const Color(0x44000000),
      );
      sprites.draw(canvas, bot, look, c - Offset(0, bob));
      if (s.state == 'waiting') {
        px.r(c.dx - 1, c.dy - 14, 2, 3, NX.waiting);
        px.r(c.dx - 1, c.dy - 10, 2, 1, NX.waiting);
      }
    }
  }

  double _loungeTop(Frame f, WorldAgent agent) {
    final room = f.world.roomOf(agent.id);
    if (room == null || room.loungeSpots.isEmpty) return -999;
    return room.loungeSpots.first.pos.dy;
  }

  void _bubble(
    Px px,
    Offset tip,
    Color color,
    String mark, {
    double pulse = 0,
  }) {
    final w = mark == 'plan' ? 13.0 : 9.0;
    final x = (tip.dx - w / 2).roundToDouble();
    final y = (tip.dy - 10 - pulse * 2).roundToDouble();
    px.r(x - 1, y - 1, w + 2, 11, _ink);
    px.r(x, y, w, 9, Colors.white);
    px.r(tip.dx - 1, y + 9, 3, 2, _ink);
    px.r(tip.dx, y + 9, 1, 1, Colors.white);
    switch (mark) {
      case '!':
        px.r(x + w / 2 - 1, y + 1, 2, 5, color);
        px.r(x + w / 2 - 1, y + 7, 2, 1, color);
      case '?':
        px.r(x + 3, y + 1, 3, 1, color);
        px.r(x + 6, y + 2, 1, 2, color);
        px.r(x + 4, y + 4, 2, 1, color);
        px.r(x + 4, y + 5, 1, 1, color);
        px.r(x + 4, y + 7, 1, 1, color);
      case 'plan':
        for (var i = 0; i < 3; i++) {
          px.r(x + 2, y + 2 + i * 2, 1, 1, color);
          px.r(x + 4, y + 2 + i * 2, 7, 1, const Color(0xFF8A93A6));
        }
      default:
        for (var i = 0; i < 3; i++) {
          px.r(x + 1.5 + i * 2.2, y + 4, 1.4, 1.4, color);
        }
    }
  }

  void _z(Px px, Offset p, double alpha) {
    final c = Color.fromRGBO(200, 214, 255, alpha.clamp(0, 1));
    px.r(p.dx, p.dy, 4, 1, c);
    px.r(p.dx + 2, p.dy + 1, 1, 1, c);
    px.r(p.dx + 1, p.dy + 2, 1, 1, c);
    px.r(p.dx, p.dy + 3, 4, 1, c);
  }

  void _activityIcon(Px px, Offset p, WorldAgent agent, int t) {
    final a = agent.chat.live?.activity ?? '';
    final bob = (t ~/ 500).isEven ? 0.0 : 1.0;
    final y = p.dy - bob;
    px.r(p.dx - 1, y - 1, 8, 8, const Color(0xCC14121C));
    switch (a) {
      case 'reading' || 'searching':
        px.r(p.dx, y, 6, 5, const Color(0xFFDCD6C8));
        px.r(p.dx + 3, y, 0.6, 5, const Color(0xFF6A4630));
      case 'browsing':
        px.r(p.dx + 1, y, 4, 6, NX.accent);
        px.r(p.dx, y + 1, 6, 4, NX.accent);
        px.r(p.dx + 2.5, y, 1, 6, const Color(0xFF14121C));
      case 'running-command':
        px.r(p.dx, y, 6, 6, const Color(0xFF0E1A14));
        px.r(p.dx + 1, y + 2, 2, 1, NX.working);
        if ((t ~/ 300).isEven) px.r(p.dx + 3, y + 4, 2, 1, NX.working);
      case 'thinking':
        px.r(p.dx + 1, y + 1, 4, 3, const Color(0xFFEFEFF5));
        px.r(p.dx, y + 4, 1, 1, const Color(0xFFEFEFF5));
      default:
        px.r(p.dx + 1, y + 4, 4, 1, const Color(0xFFE3B341));
        px.r(p.dx + 4, y + 1, 1, 3, const Color(0xFFE3B341));
        px.r(p.dx + 5, y, 1, 1, const Color(0xFFF7A66B));
    }
  }

  void _burst(Px px, Burst b, int t) {
    final age = (t - b.start) / 1000;
    if (age < 0 || age > 2) return;
    for (var i = 0; i < 14; i++) {
      final h = _hash(b.start, i);
      final angle = (h % 360) * math.pi / 180;
      final speed = 18 + h % 22;
      final p =
          b.at +
          Offset(
            math.cos(angle) * speed * age,
            -18 - math.sin(angle).abs() * speed * age + 30 * age * age,
          );
      final c = b.smoke
          ? Color.fromRGBO(110, 110, 120, (1 - age / 2) * .7)
          : [
              NX.working,
              NX.accent,
              NX.waiting,
              const Color(0xFFF28FAD),
            ][h % 4].withValues(alpha: 1 - age / 2);
      px.r(p.dx, p.dy, 2, 2, c);
    }
  }

  @override
  bool shouldRepaint(LivePainter old) => false;
}

class StaticPainter extends CustomPainter {
  StaticPainter(this.picture, this.worldSize);
  final ui.Picture picture;
  final Size worldSize;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / worldSize.width);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  @override
  bool shouldRepaint(StaticPainter old) => old.picture != picture;
}
