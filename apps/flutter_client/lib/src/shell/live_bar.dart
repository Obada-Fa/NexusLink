// The live bar: everything modules are running right now (the agent monitor,
// an audio stream, a connected trackpad...), with a stop button each.

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/nexus_theme.dart';
import 'module.dart';

/// Flattens the latest activities per module in [order] (module ids).
List<LiveActivity> combineLiveActivities(
  Map<String, List<LiveActivity>> latest,
  List<String> order,
) => [for (final id in order) ...?latest[id]];

/// Subscribes to every module's [NexusModule.liveActivities] for [ctx] and
/// reports the combined list. Streams are created once per module and target.
class LiveActivityWatcher {
  LiveActivityWatcher(this.onChanged);
  final void Function(List<LiveActivity>) onChanged;

  final _subs = <String, StreamSubscription<List<LiveActivity>>>{};
  final _latest = <String, List<LiveActivity>>{};
  List<String> _order = const [];
  String? _targetId;

  List<LiveActivity> get current => combineLiveActivities(_latest, _order);

  void update(List<NexusModule> modules, ModuleContext? ctx) {
    final targetId = ctx?.target.id;
    if (targetId != _targetId) {
      _cancelAll();
      _targetId = targetId;
    }
    _order = [for (final m in modules) m.id];
    if (ctx == null) {
      onChanged(const []);
      return;
    }
    for (final id in _subs.keys.toList()) {
      if (!_order.contains(id)) {
        _subs.remove(id)?.cancel();
        _latest.remove(id);
      }
    }
    for (final m in modules) {
      if (_subs.containsKey(m.id)) continue;
      final stream = m.liveActivities(ctx);
      if (stream == null) continue;
      _subs[m.id] = stream.listen((list) {
        _latest[m.id] = list;
        onChanged(current);
      }, onError: (_) {});
    }
  }

  void _cancelAll() {
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    _latest.clear();
  }

  void dispose() => _cancelAll();
}

class LiveBar extends StatefulWidget {
  const LiveBar({super.key, required this.modules, required this.ctx});
  final List<NexusModule> modules;
  final ModuleContext? ctx;

  @override
  State<LiveBar> createState() => _LiveBarState();
}

class _LiveBarState extends State<LiveBar> {
  late final LiveActivityWatcher _watcher;
  List<LiveActivity> _activities = const [];

  @override
  void initState() {
    super.initState();
    _watcher = LiveActivityWatcher((list) {
      if (mounted) setState(() => _activities = list);
    });
    _watcher.update(widget.modules, widget.ctx);
  }

  @override
  void didUpdateWidget(LiveBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _watcher.update(widget.modules, widget.ctx);
  }

  @override
  void dispose() {
    _watcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // PC audio has its own stop control in HomeMedia. Keep every other
    // activity, including the other audio streams, in the live bar.
    final items = _activities
        .where((a) => !(a.moduleId == 'audio' && a.activityId == 'playHere'))
        .toList();
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: items.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
              child: DecoratedBox(
                key: const ValueKey('live-bar'),
                decoration: BoxDecoration(
                  color: NX.surface,
                  borderRadius: BorderRadius.circular(NX.radius),
                  border: Border.all(color: NX.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (items.length > 1)
                        Row(
                          children: [
                            const Icon(
                              Icons.circle,
                              color: NX.working,
                              size: 7,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'LIVE NOW · ${items.length}',
                              style: const TextStyle(
                                color: NX.working,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.3,
                              ),
                            ),
                          ],
                        ),
                      if (items.length > 1) const SizedBox(height: 4),
                      for (final a in items) _LiveRow(activity: a),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _LiveRow extends StatelessWidget {
  const _LiveRow({required this.activity});
  final LiveActivity activity;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(NX.radiusSm),
    onTap: activity.onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(activity.icon, size: 18, color: NX.text),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              activity.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (activity.onStop != null)
            IconButton(
              tooltip: 'Stop ${activity.label}',
              icon: const Icon(Icons.stop_circle_outlined, color: NX.textDim),
              onPressed: activity.onStop,
            )
          else
            const SizedBox(height: 40),
        ],
      ),
    ),
  );
}
