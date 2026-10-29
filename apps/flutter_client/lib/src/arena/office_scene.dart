import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../chats/chat_models.dart';
import '../theme/nexus_theme.dart';
import 'office_models.dart';

/// Small, code-drawn sprites stay crisp at every density and need no atlas.
class OfficeScene extends StatefulWidget {
  const OfficeScene({
    super.key,
    required this.chats,
    required this.offline,
    required this.numberOffset,
    required this.onOpen,
    this.onLongPress,
  });
  final List<ChatSummary> chats;
  final bool offline;
  final int numberOffset;
  final ValueChanged<ChatSummary> onOpen;
  final ValueChanged<ChatSummary>? onLongPress;
  @override
  State<OfficeScene> createState() => _OfficeSceneState();
}

class _Journey {
  _Journey(this.points, this.started);
  final List<Offset> points;
  final int started;
  Offset at(int clock) {
    final lengths = [
      for (var i = 1; i < points.length; i++)
        (points[i] - points[i - 1]).distance,
    ];
    final total = lengths.fold<double>(0, (a, b) => a + b);
    var distance = ((clock - started) / 18).clamp(0.0, total);
    for (var i = 0; i < lengths.length; i++) {
      if (distance <= lengths[i] && lengths[i] > 0) {
        return Offset.lerp(points[i], points[i + 1], distance / lengths[i])!;
      }
      distance -= lengths[i];
    }
    return points.last;
  }

  bool moving(int clock) => (at(clock) - points.last).distance > .5;
}

class _OfficeSceneState extends State<OfficeScene>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _clock = ValueNotifier<int>(0);
  final _journeys = <String, _Journey>{};
  bool _reduce = false;
  int _clockAtStart = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final ms = _clockAtStart + elapsed.inMilliseconds;
      if (ms - _clock.value >= 100) {
        _clock.value = ms;
      }
    });
    _updatePositions();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncTicker();
  }

  @override
  void didUpdateWidget(OfficeScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePositions();
    _syncTicker();
  }

  void _syncTicker() {
    final animate = !_reduce && !widget.offline;
    if (animate && !_ticker.isActive) {
      _clockAtStart = _clock.value;
      _ticker.start();
    }
    if (!animate && _ticker.isActive) _ticker.stop();
  }

  void _updatePositions() {
    final counts = <OfficeStation, int>{};
    for (final chat in widget.chats) {
      final station = officeStationFor(chat);
      final slot = counts.update(station, (v) => v + 1, ifAbsent: () => 0);
      final target = switch (station) {
        OfficeStation.research => Offset(
          18 + slot % 4 * 20,
          51 + slot ~/ 4 * 14,
        ),
        OfficeStation.code => Offset(116 + slot % 4 * 20, 51 + slot ~/ 4 * 14),
        OfficeStation.review => Offset(
          18 + slot % 4 * 20,
          137 + slot ~/ 4 * 14,
        ),
        OfficeStation.lounge => Offset(
          116 + slot % 4 * 20,
          137 + slot ~/ 4 * 14,
        ),
        OfficeStation.help => Offset(18 + slot * 22, 87),
      };
      final old = _journeys[chat.id];
      if (old == null || old.points.last != target) {
        final from = old?.at(_clock.value) ?? target;
        _journeys[chat.id] = _Journey([
          from,
          Offset(from.dx, 87),
          Offset(target.dx, 87),
          target,
        ], _clock.value);
        if (old == null) _journeys[chat.id] = _Journey([target], _clock.value);
      }
    }
    _journeys.removeWhere((id, _) => !widget.chats.any((c) => c.id == id));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 384 / 328,
    child: FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 384,
        height: 328,
        child: Stack(
          children: [
            const Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(painter: _OfficePainter()),
              ),
            ),
            for (final label in [
              (text: 'RESEARCH', x: 20.0, y: 18.0),
              (text: 'CODE', x: 216.0, y: 18.0),
              (text: 'REVIEW', x: 20.0, y: 206.0),
              (text: 'LOUNGE', x: 216.0, y: 206.0),
            ])
              Positioned(
                left: label.x,
                top: label.y,
                child: Text(
                  label.text,
                  style: const TextStyle(
                    color: Color(0xFFDDE8D1),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            Positioned(
              left: 12,
              top: 186,
              child: Text(
                widget.offline ? 'LAST KNOWN' : 'NEEDS YOU',
                style: TextStyle(
                  color: widget.offline ? NX.textDim : const Color(0xFFE3C177),
                  fontSize: 8,
                  height: 1,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _clock,
              builder: (context, clock, _) => Stack(
                children: [
                  for (var i = 0; i < widget.chats.length; i++)
                    _puppet(widget.chats[i], i, clock),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _puppet(ChatSummary chat, int index, int clock) {
    final journey = _journeys[chat.id]!;
    final frozen = _reduce || widget.offline;
    final position = frozen ? journey.points.last : journey.at(clock);
    final moving = !frozen && journey.moving(clock);
    final number = widget.numberOffset + index + 1;
    final state = widget.offline ? 'offline' : chat.liveState;
    return Positioned(
      left: (position.dx * 2 - 18).roundToDouble(),
      top: (position.dy * 2 - 36).roundToDouble(),
      child: Semantics(
        button: true,
        label:
            'Open agent $number, ${Providers.name(chat.source)}, ${chat.title}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onOpen(chat),
          onLongPress: widget.onLongPress == null
              ? null
              : () => widget.onLongPress!(chat),
          child: SizedBox(
            width: 36,
            height: 48,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _PuppetPainter(
                      shirt: Providers.color(chat.source),
                      seed: _identity(chat.id),
                      state: state,
                      frame: frozen ? 0 : clock ~/ 220,
                      moving: moving,
                      working: !frozen && chat.running,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    color: const Color(0xFF14232C),
                    child: Text(
                      '$number',
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

int _identity(String id) =>
    id.codeUnits.fold(7, (a, b) => (a * 31 + b) & 0x7fffffff);

class _PuppetPainter extends CustomPainter {
  const _PuppetPainter({
    required this.shirt,
    required this.seed,
    required this.state,
    required this.frame,
    required this.moving,
    required this.working,
  });
  final Color shirt;
  final int seed;
  final String state;
  final int frame;
  final bool moving;
  final bool working;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(2);
    final paint = Paint()..isAntiAlias = false;
    void box(double x, double y, double w, double h, Color c) {
      paint.color = c;
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    }

    const ink = Color(0xFF172530);
    final skin = [
      const Color(0xFFF1C59D),
      const Color(0xFFB77F5D),
      const Color(0xFFDAAA7A),
      const Color(0xFF8C5844),
    ][seed % 4];
    final hair = [
      const Color(0xFF46332C),
      const Color(0xFFC69045),
      const Color(0xFF252736),
      const Color(0xFF915849),
    ][(seed ~/ 4) % 4];
    final step = moving ? frame % 2 : 0;
    box(3, 17, 12, 2, const Color(0x55302224));
    canvas.save();
    if (moving && step == 1) canvas.translate(0, -1);
    box(6, 14, 3, 4 - step.toDouble(), ink);
    box(10, 14, 3, 3 + step.toDouble(), ink);
    box(5, 9, 9, 6, ink);
    box(6, 9, 7, 5, shirt);
    box(8, 9, 2, 2, skin);
    box(4, working && frame % 2 == 0 ? 10 : 12, 2, 3, skin);
    box(13, working && frame % 2 == 1 ? 10 : 12, 2, 3, skin);
    box(5, 2, 9, 7, ink);
    box(6, 3, 7, 6, skin);
    box(5, 1, 9, 3, hair);
    if (seed.isEven) box(5, 3, 2, 4, hair);
    box(8, 5, 1, 1, ink);
    box(11, 5, 1, 1, ink);
    if (seed % 3 == 0) {
      box(7, 4, 3, 3, ink);
      box(11, 4, 3, 3, ink);
      box(8, 5, 1, 1, const Color(0xFF93CDD0));
      box(12, 5, 1, 1, const Color(0xFF93CDD0));
    }
    canvas.restore();
    if (state == 'waiting' || state == 'failed') {
      final c = Status.color(state);
      box(13, 0, 5, 7, ink);
      box(15, 1, 1, 3, c);
      box(15, 5, 1, 1, c);
    } else if (state == 'turn') {
      // Speech bubble: finished, with a follow-up for you.
      box(13, 0, 6, 4, ink);
      box(14, 1, 4, 2, NX.accent);
      box(14, 4, 1, 1, ink);
    } else if (state == 'done') {
      box(13, 2, 2, 2, NX.done);
      box(15, 0, 2, 3, NX.done);
    }
  }

  @override
  bool shouldRepaint(_PuppetPainter old) =>
      old.shirt != shirt ||
      old.seed != seed ||
      old.state != state ||
      old.frame != frame ||
      old.moving != moving ||
      old.working != working;
}

class _OfficePainter extends CustomPainter {
  const _OfficePainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 192, size.height / 164);
    final paint = Paint()..isAntiAlias = false;
    void box(num x, num y, num w, num h, int color) {
      paint.color = Color(color);
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble()),
        paint,
      );
    }

    const wood = 0xFF997654;
    const light = 0xFFC09B6B;
    const dark = 0xFF3D4650;
    // Walnut floor, little plank seams, and an uninterrupted central hallway.
    box(0, 0, 192, 164, 0xFF263C43);
    for (var y = 4; y < 164; y += 8) {
      for (var x = 4; x < 188; x += 16) {
        box(x, y, 15, 7, (x + y) % 3 == 0 ? 0xFF7A6553 : 0xFF735F50);
        box(x + (y % 16 == 4 ? 4 : 10), y + 2, 3, 1, 0xFF806B58);
      }
    }
    box(4, 74, 184, 24, 0xFF344D52);
    for (var x = 8; x < 188; x += 12) {
      box(x, 92, 6, 1, 0xFF59706B);
    }
    // Four little interiors, connected by open doorways.
    for (final origin in [
      const Offset(4, 4),
      const Offset(102, 4),
      const Offset(4, 98),
      const Offset(102, 98),
    ]) {
      final x = origin.dx;
      final y = origin.dy;
      box(x, y, 86, 18, 0xFF304D51);
      box(x, y + 17, 86, 3, 0xFF162E37);
      box(x, y, 86, 2, 0xFF6F8780);
      box(x, y + 20, 2, 46, 0xFF293C41);
      box(x + 84, y + 20, 2, 46, 0xFF293C41);
      box(x, y + 66, 32, 3, 0xFF263B41);
      box(x + 52, y + 66, 34, 3, 0xFF263B41);
    }
    // Research library and reading tables.
    for (var x = 10; x < 80; x += 24) {
      box(x, 25, 20, 15, dark);
      for (var b = 0; b < 5; b++) {
        box(
          x + 2 + b * 3,
          26 + b % 2,
          2,
          8 - b % 2,
          [0xFFB47766, 0xFF8DAF9C, 0xFFD0B27A, 0xFF86A4B2, 0xFFAA8DA8][b],
        );
      }
      box(x, 35, 20, 2, light);
    }
    box(27, 49, 39, 3, 0xFF4B403B);
    box(27, 43, 39, 6, wood);
    box(33, 43, 9, 4, 0xFFE0D6B7);
    box(43, 43, 8, 4, 0xFFB8C6AD);
    box(36, 44, 1, 2, 0xFF8E987C);
    // Coding desks: four laptop setups, mugs and cables.
    for (var x = 109; x < 184; x += 19) {
      box(x, 42, 16, 3, 0xFF4E4039);
      box(x, 36, 16, 6, light);
      box(x + 1, 45, 2, 4, dark);
      box(x + 12, 45, 2, 4, dark);
      box(x + 3, 27, 10, 10, 0xFF162F3D);
      box(x + 4, 28, 8, 7, 0xFF7CB4AE);
      box(x + 5, 30, 4, 1, 0xFFDCF1C7);
      box(x + 5, 32, 6, 1, 0xFF467D81);
      box(x + 2, 37, 12, 2, 0xFF536873);
      box(x + 14, 34, 2, 3, 0xFFE9D5AC);
      box(x + 5, 52, 8, 3, 0xFF425C65);
    }
    // Review wall: pinned tasks, a planning table and paper stacks.
    box(10, 120, 33, 12, wood);
    box(11, 121, 31, 10, 0xFFAF9C73);
    for (var i = 0; i < 6; i++) {
      box(
        14 + i % 3 * 9,
        122 + i ~/ 3 * 5,
        5,
        3,
        i.isEven ? 0xFFDBCA91 : 0xFF92B5AA,
      );
    }
    box(51, 124, 31, 9, light);
    box(53, 133, 2, 5, dark);
    box(78, 133, 2, 5, dark);
    box(57, 124, 8, 5, 0xFFD6DDC3);
    box(68, 124, 9, 3, 0xFF91AEA6);
    // Lounge sofa, rug, coffee table and a tiny coffee machine.
    box(110, 123, 48, 30, 0xFF78847A);
    box(112, 125, 44, 26, 0xFF8F9A86);
    for (var x = 114; x < 154; x += 6) {
      box(x, 147, 3, 1, 0xFFB4B69A);
    }
    box(110, 120, 47, 8, 0xFF496C68);
    box(110, 126, 47, 7, 0xFF709188);
    box(110, 120, 3, 14, 0xFF345454);
    box(154, 120, 3, 14, 0xFF345454);
    box(121, 137, 27, 6, light);
    box(123, 143, 2, 3, dark);
    box(143, 143, 2, 3, dark);
    box(128, 135, 3, 3, 0xFFE9D5AC);
    box(165, 121, 16, 12, wood);
    box(168, 116, 10, 9, 0xFF1A3037);
    box(170, 117, 6, 3, 0xFF90B4AD);
    box(171, 122, 3, 3, 0xFFE9D5AC);
    // Potted plants frame the corridor, with a little reception bell.
    for (final p in [
      const Offset(5, 78),
      const Offset(179, 78),
      const Offset(83, 141),
    ]) {
      box(p.dx + 2, p.dy + 8, 6, 5, 0xFFB58161);
      box(p.dx + 4, p.dy + 2, 2, 7, 0xFF405C43);
      box(p.dx, p.dy + 2, 5, 4, 0xFF7B9D73);
      box(p.dx + 5, p.dy, 5, 5, 0xFFA2BB86);
    }
    box(91, 6, 9, 5, 0xFFD8C18A);
    box(94, 7, 2, 3, 0xFF485F60);
    // Pixel corners give the whole room a cartridge-game frame.
    for (final x in [0, 189]) {
      box(x, 0, 3, 164, 0xFF1B3038);
    }
  }

  @override
  bool shouldRepaint(_OfficePainter oldDelegate) => false;
}
