// The Arena: a pannable, zoomable office campus. One room per recent project;
// each agent walks to where its work is (desk, bookshelves, server rack, lounge,
// help desk) and anything waiting on you is impossible to miss.

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../chats/chat_models.dart';
import '../monitor/approvals.dart';
import '../monitor/mission_control.dart';
import '../theme/nexus_theme.dart';
import 'pixel_art.dart';
import 'world.dart';
import 'world_painter.dart';

/// Logical pixels per art pixel at 1× zoom.
const double kArtScale = 2;
const _walkSpeed = 46.0; // art px per second

class ArenaWorld extends ConsumerStatefulWidget {
  const ArenaWorld({
    super.key,
    required this.chats,
    required this.offline,
    required this.onOpen,
    this.onActions,
    this.now,
    this.onNewChat,
  });
  final List<ChatSummary> chats;
  final bool offline;

  /// Tapped a room's reception desk: start a chat in that project.
  final ValueChanged<WorldRoom>? onNewChat;
  final ValueChanged<ChatSummary> onOpen;
  final ValueChanged<ChatSummary>? onActions;

  /// Fixed clock for tests and screenshots.
  final DateTime? now;
  @override
  ConsumerState<ArenaWorld> createState() => ArenaWorldState();
}

class _Mover {
  _Mover(this.pos, this.spot);
  Offset pos;
  Spot spot;
  List<Offset> route = const [];
  Offset dir = Offset.zero;
  Pose? pose;
}

class ArenaWorldState extends ConsumerState<ArenaWorld>
    with TickerProviderStateMixin {
  final _camera = TransformationController();
  final _sprites = SpriteBook();
  final _clock = ValueNotifier<int>(0);
  late final Ticker _ticker;
  AnimationController? _fly;
  World? _world;
  String _signature = '';
  ui.Picture? _static;
  int _staticNight = -1;
  final _movers = <String, _Mover>{};
  final _bursts = <Burst>[];
  final _tags = <String, AgentTag>{};
  String? _selected;
  Size _viewport = Size.zero;
  bool _placed = false;
  Duration _lastTick = Duration.zero;
  int _sceneMs = 0;
  final _cycle = <String, int>{};

  World? get world => _world;
  TransformationController get camera => _camera;
  String? get selected => _selected;
  Offset? positionOf(String id) => _movers[id]?.pos;
  bool isWalking(String id) => _movers[id]?.route.isNotEmpty ?? false;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  DateTime get _now => widget.now ?? DateTime.now();
  double get _night => nightFor(_now);
  double get _zoom => _camera.value.getMaxScaleOnAxis() * kArtScale / 2;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    _camera.addListener(_onCamera);
  }

  void _syncTicker() {
    if (_reduced || widget.offline || !TickerMode.valuesOf(context).enabled) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ArenaWorld oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fly?.dispose();
    _camera.removeListener(_onCamera);
    _camera.dispose();
    _clock.dispose();
    _static?.dispose();
    _sprites.dispose();
    for (final t in _tags.values) {
      t.dispose();
    }
    super.dispose();
  }

  void _onCamera() => _clock.value++;

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, .1);
    _lastTick = elapsed;
    if (_reduced || widget.offline) return;
    _sceneMs += (dt * 1000).round();
    var moving = false;
    for (final m in _movers.values) {
      if (m.route.isEmpty) continue;
      moving = true;
      var budget = _walkSpeed * dt;
      while (budget > 0 && m.route.isNotEmpty) {
        final to = m.route.first;
        final d = to - m.pos;
        final len = d.distance;
        if (len <= budget) {
          m.pos = to;
          budget -= len;
          m.route = m.route.sublist(1);
        } else {
          m.dir = d / len;
          m.pos += m.dir * budget;
          budget = 0;
        }
      }
      if (m.route.isEmpty) m.dir = Offset.zero;
    }
    _bursts.removeWhere((b) => _sceneMs - b.start > 2200);
    // ~20 fps is plenty for pixel art; walking and bursts get every frame.
    if (moving || _bursts.isNotEmpty || _sceneMs - _clock.value > 50) {
      _clock.value = _sceneMs;
    }
  }

  void _sync(World world) {
    final reduced = _reduced;
    final alive = <String>{};
    for (final room in world.rooms) {
      for (final a in room.agents) {
        alive.add(a.id);
        final m = _movers[a.id];
        if (m == null) {
          _movers[a.id] = _Mover(a.spot.pos, a.spot)..pose = a.pose;
          continue;
        }
        final was = m.pose;
        if (was != null && was != a.pose) {
          final head = a.spot.pos - const Offset(0, 22);
          final wasWorking =
              was == Pose.typing ||
              was == Pose.researching ||
              was == Pose.running;
          if (wasWorking &&
              (a.pose == Pose.yourTurn ||
                  (a.pose == Pose.resting && a.chat.liveState == 'done'))) {
            _bursts.add(Burst(m.pos - const Offset(0, 22), _sceneMs));
          } else if (a.pose == Pose.failed) {
            _bursts.add(Burst(head, _sceneMs, smoke: true));
          }
        }
        m.pose = a.pose;
        if ((m.spot.pos - a.spot.pos).distance > .5) {
          m.route = reduced
              ? const []
              : routeBetween(m.pos, m.spot, a.spot, room.aisleY);
          if (reduced) m.pos = a.spot.pos;
          m.spot = a.spot;
        }
      }
    }
    _movers.removeWhere((id, _) => !alive.contains(id));
    for (final id in _tags.keys.where((id) => !alive.contains(id)).toList()) {
      _tags.remove(id)?.dispose();
    }
  }

  AgentTag _tag(WorldAgent a) {
    final status = switch (a.pose) {
      Pose.typing =>
        a.chat.live?.activity == 'thinking' ? 'Thinking' : 'Working',
      Pose.researching => switch (a.chat.live?.activity ??
          a.chat.json['activity']) {
        'browsing' => 'Browsing',
        'searching' => 'Searching',
        _ => 'Reading',
      },
      Pose.running => 'Running',
      Pose.asking => 'Needs you',
      Pose.yourTurn => 'Your turn',
      Pose.failed => 'Failed',
      // A stopped session may not have succeeded; only say Done when it did.
      Pose.resting => a.chat.liveState == 'done' ? 'Done' : 'Stopped',
      Pose.sleeping => 'Idle',
    };
    final color = switch (a.pose) {
      Pose.asking => NX.waiting,
      Pose.failed => NX.failed,
      Pose.yourTurn => NX.accent,
      Pose.typing ||
      Pose.researching ||
      Pose.running => const Color(0xFFA8DBC4),
      _ => const Color(0xFFB8C6CB),
    };
    // Keep text readable at the initial room-fit zoom without enlarging sprites.
    final fontSize =
        (MediaQuery.textScalerOf(context).scale(11) / (2 * _zoom.clamp(.4, 3)))
            .clamp(6.5, 16.0);
    // Small rooms have few neighbours per row, so the status can stay whole.
    final width = _selected == a.id ? 150.0 : (_isCompact ? 58.0 : 42.0);
    final label = _selected == a.id
        ? '${a.chat.title} · ${a.chat.folderName}'
        : a.chat.title;
    final detail = _selected == a.id ? '$status · ${a.chat.stepLabel}' : status;
    final key = '$label|$detail|$fontSize|$width';
    final existing = _tags[a.id];
    if (existing != null && existing.key == key) return existing;
    existing?.dispose();
    return _tags[a.id] = AgentTag(
      key: key,
      title: label,
      status: detail,
      color: color,
      fontSize: fontSize,
      maxWidth: width,
    );
  }

  Frame _frame() {
    final world = _world!;
    final actors = <Actor>[];
    for (final room in world.rooms) {
      for (final a in room.agents) {
        final m = _movers[a.id];
        actors.add(
          Actor(
            agent: a,
            look: lookFor(a.chat, boss: a.isBoss),
            pos: m?.pos ?? a.spot.pos,
            moving: (m?.route.isNotEmpty ?? false),
            dir: m?.dir ?? Offset.zero,
          ),
        );
      }
    }
    return Frame(
      world: world,
      actors: actors,
      clockMs: _sceneMs,
      night: _night,
      zoom: _zoom,
      offline: widget.offline,
      reduced: _reduced,
      selected: _selected,
      bursts: _bursts,
      tags: {
        for (final room in world.rooms)
          for (final a in room.agents) a.id: _tag(a),
      },
    );
  }

  // --- Camera ---------------------------------------------------------------

  /// Room for the counter and project chips at the top of the view.
  static const _hudTop = 96.0;

  Matrix4 _focusMatrix(Offset art, double scale) {
    final p = art * kArtScale;
    return Matrix4.identity()
      ..translateByDouble(
        _viewport.width / 2 - p.dx * scale,
        _hudTop + (_viewport.height - _hudTop) / 2 - p.dy * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  double get _fitScale {
    final w = _world!.size;
    return math.min(
      _viewport.width / (w.width * kArtScale),
      _viewport.height / (w.height * kArtScale),
    );
  }

  void _flyTo(Matrix4 target) {
    _fly?.dispose();
    _fly = null;
    if (_reduced) {
      _camera.value = target;
      return;
    }
    final tween = Matrix4Tween(begin: _camera.value.clone(), end: target);
    final fly = _fly = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    final curve = CurvedAnimation(parent: fly, curve: Curves.easeInOutCubic);
    fly.addListener(() => _camera.value = tween.evaluate(curve));
    fly.forward();
  }

  /// Centres the camera on an agent and selects it.
  void focusAgent(String id, {bool select = true}) {
    final w = _world;
    if (w == null) return;
    final m = _movers[id];
    final a = w.agent(id);
    if (a == null) return;
    final scale = math.max(_camera.value.getMaxScaleOnAxis(), .9);
    _flyTo(_focusMatrix((m?.pos ?? a.spot.pos) - const Offset(0, 10), scale));
    if (select) setState(() => _selected = id);
  }

  void focusRoom(WorldRoom room) {
    final scale = math.min(
      _viewport.width / (room.rect.width * kArtScale + 24),
      2.0,
    );
    _flyTo(_focusMatrix(room.rect.center, scale));
  }

  /// The room under the middle of the view, or the nearest one.
  WorldRoom? get currentRoom {
    final rooms = _world?.rooms ?? const <WorldRoom>[];
    if (rooms.isEmpty) return null;
    final center = _camera.toScene(_viewport.center(Offset.zero)) / kArtScale;
    double away(WorldRoom r) {
      final x = center.dx.clamp(r.rect.left, r.rect.right);
      final y = center.dy.clamp(r.rect.top, r.rect.bottom);
      return (Offset(x, y) - center).distance;
    }

    return rooms.reduce((a, b) => away(b) < away(a) ? b : a);
  }

  /// Small rooms open filling the width, top rooms first, so people stay legible.
  Matrix4 get _overview {
    final scale = _viewport.width / (_world!.size.width * kArtScale);
    return Matrix4.identity()
      ..translateByDouble(0, _hudTop, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  bool get _isCompact => _world?.rooms.firstOrNull?.compact ?? false;

  /// Every room is on screen at the overview, so a minimap adds nothing.
  bool get fitsOverview {
    final w = _world;
    if (w == null || !_isCompact) return false;
    return _hudTop + w.size.height * _viewport.width / w.size.width <=
        _viewport.height;
  }

  void fitAll() {
    if (_isCompact) {
      _flyTo(_overview);
      return;
    }
    _flyTo(
      Matrix4.identity()
        ..translateByDouble(
          (_viewport.width - _world!.size.width * kArtScale * _fitScale) / 2,
          (_viewport.height - _world!.size.height * kArtScale * _fitScale) / 2,
          0,
          1,
        )
        ..scaleByDouble(_fitScale, _fitScale, _fitScale, 1),
    );
  }

  void _zoomBy(double factor) {
    final s = (_camera.value.getMaxScaleOnAxis() * factor).clamp(
      _minScale,
      3.0,
    );
    final center = _camera.toScene(_viewport.center(Offset.zero));
    _flyTo(_focusMatrix(center / kArtScale, s));
  }

  double get _minScale => math.min(_fitScale * .9, .25);

  void _placeCamera() {
    final w = _world!;
    if (w.rooms.isEmpty) return;
    if (_isCompact) {
      _camera.value = _overview;
      return;
    }
    // Open on the first room (the most urgent), its full width on screen.
    final first = w.rooms.first;
    final fit = (_viewport.width - 16) / (first.rect.width * kArtScale);
    final scale = fit.clamp(_minScale, 1.6);
    // Top of the room (and its name plate) just under the counter chips.
    final focus = Offset(
      first.rect.center.dx,
      first.rect.top -
          24 +
          (_viewport.height - _hudTop) / 2 / scale / kArtScale,
    );
    _camera.value = _focusMatrix(focus, scale);
  }

  /// Cycles the camera through agents matching [poses].
  void cycle(String key, Set<Pose> poses) {
    final list = _world!.agents.where((a) => poses.contains(a.pose)).toList();
    if (list.isEmpty) return;
    final i = (_cycle[key] = ((_cycle[key] ?? -1) + 1) % list.length);
    HapticFeedback.selectionClick();
    focusAgent(list[i].id);
  }

  // --- Input ----------------------------------------------------------------

  void _tapAt(Offset local) {
    final w = _world;
    if (w == null) return;
    final art = local / kArtScale;
    WorldAgent? hit;
    var best = double.infinity;
    for (final a in w.agents) {
      final pos = _movers[a.id]?.pos ?? a.spot.pos;
      final box = Rect.fromLTRB(
        pos.dx - 8,
        pos.dy - 24,
        pos.dx + 8,
        pos.dy + 3,
      );
      if (!box.contains(art)) continue;
      final d = (pos - const Offset(0, 9) - art).distance;
      if (d < best) {
        best = d;
        hit = a;
      }
    }
    if (hit != null) {
      HapticFeedback.selectionClick();
      setState(() => _selected = hit!.id);
      _openAgent(hit.chat);
      return;
    }
    for (final room in w.rooms) {
      if (!room.compact &&
          !widget.offline &&
          widget.onNewChat != null &&
          receptionRect(room).inflate(8).contains(art)) {
        HapticFeedback.selectionClick();
        widget.onNewChat!(room);
        return;
      }
      final plate = Rect.fromLTWH(
        room.rect.left,
        room.rect.top - 20,
        room.rect.width * .7,
        22,
      );
      if (plate.contains(art)) {
        HapticFeedback.selectionClick();
        _openRoom(room);
        return;
      }
    }
    if (_selected != null) setState(() => _selected = null);
  }

  Future<void> _openAgent(ChatSummary chat) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: NX.surface,
    builder: (_) => ArenaAgentSheet(
      chatId: chat.id,
      lookup: () => _world?.agent(chat.id)?.chat ?? chat,
      room: _world?.roomOf(chat.id),
      world: _world,
      offline: widget.offline,
      onOpen: () {
        Navigator.pop(context);
        widget.onOpen(chat);
      },
      onActions: widget.onActions == null
          ? null
          : () {
              Navigator.pop(context);
              widget.onActions!(chat);
            },
    ),
  );

  Future<void> _openRoom(
    WorldRoom room, {
    String? title,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: NX.surface,
    builder: (sheet) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .7,
      maxChildSize: .95,
      builder: (_, scroll) => ListView(
        controller: scroll,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 10),
            child: Text(
              title ?? room.name,
              style: const TextStyle(
                color: NX.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (room.path != null && title == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 12),
              child: Text(
                room.path!,
                style: const TextStyle(color: NX.textDim, fontSize: 12),
              ),
            ),
          for (final r in title == null ? [room] : _world!.rooms)
            for (final a in r.agents)
              LiveAgentCard(
                key: ValueKey(a.id),
                chat: a.chat,
                offline: widget.offline,
                onOpen: () {
                  Navigator.pop(sheet);
                  widget.onOpen(a.chat);
                },
                onLongPress: widget.onActions == null
                    ? null
                    : () => widget.onActions!(a.chat),
              ),
          if (room.hidden > 0 && title == null)
            Padding(
              padding: const EdgeInsets.all(NX.pad),
              child: Text(
                '+${room.hidden} older ${room.hidden == 1 ? 'chat' : 'chats'} in this project are in Projects.',
                style: const TextStyle(color: NX.textDim, fontSize: 12),
              ),
            ),
        ],
      ),
    ),
  );

  void openAgentList() {
    final w = _world;
    if (w == null || w.rooms.isEmpty) return;
    _openRoom(w.rooms.first, title: 'Everyone in the Arena');
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final asking = ref.watch(approvalsProvider.select((s) => s.chatIds));
    return LayoutBuilder(
      builder: (context, c) {
        _viewport = c.biggest;
        final signature = [
          for (final chat in widget.chats)
            '${chat.id}|${chat.json['activityAt']}|${chat.liveState}|${chat.live?.activity}|${chat.title}|${chat.parentId}|${chat.live?.subagents.length}|${chat.stepLabel}|${chat.folderPath}',
          ...asking,
          c.maxWidth.round(),
        ].join(';');
        if (signature != _signature || _world == null) {
          _signature = signature;
          final next = buildWorld(
            widget.chats,
            asking: asking,
            now: _now,
            viewportWidth: c.maxWidth,
          );
          // The map changed scale (a second project arrived, say): re-aim after
          // this frame, since the camera drives widgets being built right now.
          if (_placed &&
              _isCompact != (next.rooms.firstOrNull?.compact ?? false)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _placeCamera();
            });
          }
          final layoutChanged =
              _world == null ||
              _world!.size != next.size ||
              _world!.rooms.map((r) => '${r.id}${r.rect}').join() !=
                  next.rooms.map((r) => '${r.id}${r.rect}').join();
          _world = next;
          if (layoutChanged) {
            _static?.dispose();
            _static = null;
          }
          _sync(next);
        }
        final nightBucket = (_night * 8).round();
        if (_static == null || nightBucket != _staticNight) {
          _static?.dispose();
          _static = recordStatic(_world!, night: _night);
          _staticNight = nightBucket;
        }
        // Chats can load after the first build; wait for a room to aim at.
        if (!_placed &&
            _world!.rooms.isNotEmpty &&
            c.maxWidth > 0 &&
            c.maxHeight > 0) {
          _placed = true;
          _placeCamera();
        }
        final w = _world!;
        if (w.rooms.isEmpty) return _empty();
        final size = w.size * kArtScale;
        return Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xFF294A42),
                child: InteractiveViewer(
                  transformationController: _camera,
                  constrained: false,
                  boundaryMargin: EdgeInsets.all(c.maxWidth * .6),
                  minScale: _minScale,
                  maxScale: 3,
                  onInteractionStart: (_) => _fly?.stop(),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _tapAt(d.localPosition),
                    child: SizedBox.fromSize(
                      size: size,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: StaticPainter(_static!, w.size),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: LivePainter(
                                _frame,
                                _sprites,
                                repaint: _clock,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _Hud(state: this, world: w, offline: widget.offline),
          ],
        );
      },
    );
  }

  Widget _empty() => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.apartment_rounded, color: Color(0xFFF2DFB9), size: 40),
          SizedBox(height: 12),
          Text(
            'The campus is quiet.',
            style: TextStyle(color: NX.text, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 6),
          Text(
            'Projects you worked on in the last 7 days get a room here. Your current filters apply.',
            textAlign: TextAlign.center,
            style: TextStyle(color: NX.textDim, height: 1.45),
          ),
        ],
      ),
    ),
  );
}

class _Hud extends StatelessWidget {
  const _Hud({required this.state, required this.world, required this.offline});
  final ArenaWorldState state;
  final World world;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: _StatusChips(
                      state: state,
                      world: world,
                      offline: offline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _ProjectStrip(state: state, world: world),
                ],
              ),
            ),
            Positioned(
              left: 10,
              bottom: 10,
              child: Row(
                children: [
                  _RoundButton(
                    icon: Icons.add_rounded,
                    label: 'Zoom in',
                    onTap: () => state._zoomBy(1.4),
                  ),
                  const SizedBox(width: 8),
                  _RoundButton(
                    icon: Icons.remove_rounded,
                    label: 'Zoom out',
                    onTap: () => state._zoomBy(1 / 1.4),
                  ),
                  const SizedBox(width: 8),
                  _RoundButton(
                    icon: Icons.fit_screen_rounded,
                    label: 'Show the whole campus',
                    onTap: state.fitAll,
                  ),
                  const SizedBox(width: 8),
                  _RoundButton(
                    icon: Icons.format_list_bulleted_rounded,
                    label: 'List everyone',
                    onTap: state.openAgentList,
                  ),
                ],
              ),
            ),
            if (!state.fitsOverview)
              Positioned(
                right: 10,
                bottom: 10,
                child: _Minimap(state: state, world: world),
              ),
          ],
        ),
      ),
    );
  }
}

Color _roomColor(WorldRoom r) => r.needsYou + r.failed > 0
    ? NX.waiting
    : r.yourTurn > 0
    ? NX.accent
    : r.working > 0
    ? NX.working
    : NX.idle;

/// Totals across every project: who needs you, whose turn it is, who is busy.
class _StatusChips extends StatelessWidget {
  const _StatusChips({
    required this.state,
    required this.world,
    required this.offline,
  });
  final ArenaWorldState state;
  final World world;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    int count(Set<Pose> p) =>
        world.agents.where((a) => p.contains(a.pose)).length;
    const needs = {Pose.asking, Pose.failed};
    const turn = {Pose.yourTurn};
    const busy = {Pose.typing, Pose.researching, Pose.running};
    final nNeeds = count(needs);
    final nTurn = count(turn);
    final nBusy = count(busy);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (offline)
          const _Chip(
            icon: Icons.cloud_off_rounded,
            label: 'Offline · last known',
            color: NX.idle,
          ),
        _Chip(
          icon: Icons.front_hand_rounded,
          label: nNeeds == 0 ? 'Nobody needs you' : '$nNeeds need you',
          color: nNeeds == 0 ? NX.idle : NX.waiting,
          pulse: nNeeds > 0,
          onTap: nNeeds == 0 ? null : () => state.cycle('needs', needs),
        ),
        if (nTurn > 0)
          _Chip(
            icon: Icons.chat_bubble_outline_rounded,
            label: '$nTurn your turn',
            color: NX.accent,
            onTap: () => state.cycle('turn', turn),
          ),
        _Chip(
          icon: Icons.bolt_rounded,
          label: '$nBusy working',
          color: nBusy == 0 ? NX.idle : NX.working,
          onTap: nBusy == 0 ? null : () => state.cycle('busy', busy),
        ),
      ],
    );
  }
}

/// Every project on the map and how it is doing; the room in view is marked.
class _ProjectStrip extends StatelessWidget {
  const _ProjectStrip({required this.state, required this.world});
  final ArenaWorldState state;
  final World world;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: AnimatedBuilder(
      animation: state.camera,
      builder: (_, _) {
        final current = state.currentRoom;
        return Row(
          children: [
            for (final room in world.rooms)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _Chip(
                  icon: Icons.apartment_rounded,
                  label: '${room.name} · ${room.summary}',
                  color: _roomColor(room),
                  pulse: room.id == current?.id,
                  onTap: () => state.focusRoom(room),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.pulse = false,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool pulse;
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: onTap == null ? label : '$label. Tap to go there.',
    excludeSemantics: true,
    child: Material(
      color: const Color(0xE614121C),
      shape: StadiumBorder(
        side: BorderSide(
          color: color.withValues(alpha: pulse ? .9 : .45),
          width: pulse ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color == NX.idle ? NX.textDim : NX.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Material(
      color: const Color(0xE614121C),
      shape: const CircleBorder(side: BorderSide(color: NX.line)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 40,
          child: Icon(icon, size: 20, color: NX.text, semanticLabel: label),
        ),
      ),
    ),
  );
}

class _Minimap extends StatelessWidget {
  const _Minimap({required this.state, required this.world});
  final ArenaWorldState state;
  final World world;
  @override
  Widget build(BuildContext context) {
    const maxW = 92.0;
    final scale = math.min(maxW / world.size.width, 72 / world.size.height);
    final size = world.size * scale;
    return Semantics(
      label: 'Map of ${world.rooms.length} project rooms',
      child: GestureDetector(
        onTapUp: (d) {
          final art = d.localPosition / scale;
          final room = world.rooms
              .where((r) => r.rect.inflate(tile).contains(art))
              .firstOrNull;
          if (room != null) state.focusRoom(room);
        },
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: const Color(0xCC14121C),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: NX.line),
          ),
          child: AnimatedBuilder(
            animation: state.camera,
            builder: (_, _) => CustomPaint(
              size: size,
              painter: _MinimapPainter(world, scale, state),
            ),
          ),
        ),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter(this.world, this.scale, this.state);
  final World world;
  final double scale;
  final ArenaWorldState state;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF294A42),
    );
    for (final r in world.rooms) {
      final color = _roomColor(r);
      final rect = Rect.fromLTRB(
        r.rect.left * scale,
        r.rect.top * scale,
        r.rect.right * scale,
        r.rect.bottom * scale,
      );
      canvas.drawRect(rect, Paint()..color = const Color(0xFF35454D));
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final view = state._viewport;
    if (view.isEmpty) return;
    final tl = state.camera.toScene(Offset.zero) / kArtScale * scale;
    final br =
        state.camera.toScene(view.bottomRight(Offset.zero)) / kArtScale * scale;
    canvas.drawRect(
      Rect.fromPoints(tl, br),
      Paint()
        ..color = Colors.white.withValues(alpha: .9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_MinimapPainter old) => true;
}

/// What one agent is doing, with phone approvals right there.
class ArenaAgentSheet extends ConsumerWidget {
  const ArenaAgentSheet({
    super.key,
    required this.chatId,
    required this.lookup,
    required this.room,
    required this.world,
    required this.offline,
    required this.onOpen,
    this.onActions,
  });
  final String chatId;
  final ChatSummary Function() lookup;
  final WorldRoom? room;
  final World? world;
  final bool offline;
  final VoidCallback onOpen;
  final VoidCallback? onActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = lookup();
    final approvals = offline
        ? const <ExternalApproval>[]
        : ref.watch(approvalsProvider.select((s) => s.forChat(chatId)));
    final boss = chat.parentId == null ? null : world?.agent(chat.parentId!);
    final crew =
        world?.agents.where((a) => a.chat.parentId == chatId).toList() ??
        const [];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: approvals.isEmpty ? .55 : .8,
      maxChildSize: .95,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.forum_outlined, size: 18),
                    label: const Text('Open chat'),
                  ),
                ),
                if (onActions != null) ...[
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: onActions,
                    icon: const Icon(Icons.more_horiz_rounded, size: 18),
                    label: const Text('More'),
                  ),
                ],
              ],
            ),
          ),
          LiveAgentCard(chat: chat, offline: offline, onOpen: onOpen),
          if (approvals.isEmpty && chat.needsAttention && !offline)
            const Padding(
              padding: EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 8),
              child: Text(
                'Answer this on the PC, or turn on Phone approvals in the PC tab to answer Claude prompts here.',
                style: TextStyle(
                  color: NX.textDim,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
          if (room != null || boss != null || crew.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(NX.pad, 4, NX.pad, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (room != null) _Fact(Icons.apartment_rounded, room!.name),
                  if (boss != null)
                    _Fact(
                      Icons.workspace_premium_outlined,
                      'Reports to ${boss.chat.title}',
                    ),
                  if (crew.isNotEmpty)
                    _Fact(
                      Icons.groups_2_outlined,
                      'Leads ${crew.length} ${crew.length == 1 ? 'worker' : 'workers'}',
                    ),
                  _Fact(Icons.smart_toy_outlined, Providers.name(chat.source)),
                ],
              ),
            ),
          if ((chat.live?.subagents ?? const []).isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(NX.pad, 4, NX.pad, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SUB-AGENTS',
                    style: TextStyle(
                      color: NX.textFaint,
                      fontSize: 11,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final s in chat.live!.subagents)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.smart_toy_rounded,
                            size: 16,
                            color: s.state == 'waiting'
                                ? NX.waiting
                                : s.state == 'working'
                                ? NX.working
                                : NX.idle,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              [
                                s.name,
                                if (s.kind != null) s.kind!,
                                if (s.step != null) s.step!,
                              ].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: NX.text,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: NX.surface2,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: NX.line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: NX.textDim),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: NX.text, fontSize: 12.5),
          ),
        ),
      ],
    ),
  );
}
