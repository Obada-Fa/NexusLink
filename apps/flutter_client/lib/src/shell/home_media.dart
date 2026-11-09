import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_audio/nexus_audio.dart';
import 'package:nexus_remote/nexus_remote.dart';

import '../modules/audio/audio_runtime.dart';
import '../modules/remote/remote_module.dart';
import '../theme/nexus_theme.dart';

/// Compact PC playback and audio-routing controls for the current Home.
class HomeMedia extends StatefulWidget {
  const HomeMedia({
    super.key,
    required this.targetId,
    required this.visible,
    required this.onOpenMedia,
  });
  final String targetId;
  final bool visible;
  final VoidCallback onOpenMedia;

  @override
  State<HomeMedia> createState() => _HomeMediaState();
}

class _HomeMediaState extends State<HomeMedia> {
  RemoteSession? _session;
  Timer? _timer;
  Map<String, dynamic>? _player;
  bool _busy = false;
  bool _refreshAgain = false;
  bool _actionBusy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    RemoteRuntime.session.addListener(_bind);
    _bind();
  }

  @override
  void didUpdateWidget(covariant HomeMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetId != widget.targetId ||
        oldWidget.visible != widget.visible) {
      _bind();
    }
  }

  void _bind() {
    final next = RemoteRuntime.targetId == widget.targetId
        ? RemoteRuntime.session.value
        : null;
    final changed = !identical(next, _session);
    if (changed) {
      _session?.removeListener(_bind);
      _session = next;
      _session?.addListener(_bind);
    }
    final active =
        widget.visible &&
        next?.connected == true &&
        next?.mediaSupported == true;
    if (!changed && active == (_timer != null)) return;
    _generation++;
    _busy = false;
    _actionBusy = false;
    _refreshAgain = false;
    _timer?.cancel();
    _timer = null;
    setState(() => _player = null);
    if (active) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final session = _session;
    if (!mounted || _timer == null || session == null || !session.connected) {
      return;
    }
    if (_busy) {
      _refreshAgain = true;
      return;
    }
    _busy = true;
    final generation = _generation;
    try {
      final result = await session.rpc('media.list', {});
      final found = (result['players'] as List? ?? const [])
          .whereType<Map>()
          .map((p) => Map<String, dynamic>.from(p))
          .where((p) => p['id'] is String)
          .where((p) => p['status'] == 'Playing' || p['status'] == 'Paused')
          .toList();
      final playing = found.where((p) => p['status'] == 'Playing');
      final current = found.where((p) => p['id'] == _player?['id']);
      final selected = current.isNotEmpty
          ? current.first
          : playing.isNotEmpty
          ? playing.first
          : (found.isNotEmpty ? found.first : null);
      if (mounted && generation == _generation) {
        setState(() => _player = selected);
      }
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _player = null);
    } finally {
      if (generation == _generation) {
        _busy = false;
        if (_refreshAgain) {
          _refreshAgain = false;
          unawaited(_refresh());
        }
      }
    }
  }

  Future<void> _action(String action) async {
    final session = _session;
    final id = _player?['id'];
    if (_actionBusy || session == null || id is! String) return;
    final generation = _generation;
    setState(() => _actionBusy = true);
    try {
      await session.rpc('media.action', {'player_id': id, 'action': action});
      if (mounted && generation == _generation) await _refresh();
    } catch (_) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not control PC playback.')),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _actionBusy = false);
      }
    }
  }

  @override
  void dispose() {
    RemoteRuntime.session.removeListener(_bind);
    _session?.removeListener(_bind);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AudioView>(
    valueListenable: AudioRuntime.view,
    builder: (context, audio, _) {
      final streamOn =
          audio.targetId == widget.targetId && audio.isOn(AudioStream.playHere);
      final player = _player;
      if (player == null && !streamOn) return const SizedBox.shrink();
      final playing = player?['status'] == 'Playing';
      final title = player?['title']?.toString();
      return Container(
        key: const ValueKey('home-media'),
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        decoration: BoxDecoration(
          color: NX.surface2,
          border: Border.all(color: NX.line),
          borderRadius: BorderRadius.circular(NX.radius),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (player != null) ...[
              InkWell(
                onTap: widget.onOpenMedia,
                borderRadius: BorderRadius.circular(NX.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const _Record(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title == null || title.isEmpty
                                  ? 'Untitled track'
                                  : title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              '${playing ? 'Playing' : 'Paused'} on ${_session?.endpoint.pcName ?? 'PC'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: NX.textDim),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: NX.textDim),
                    ],
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous track',
                    onPressed: _actionBusy ? null : () => _action('previous'),
                    icon: const Icon(Icons.skip_previous_rounded),
                  ),
                  IconButton.filledTonal(
                    tooltip: playing ? 'Pause playback' : 'Play',
                    onPressed: _actionBusy ? null : () => _action('play_pause'),
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next track',
                    onPressed: _actionBusy ? null : () => _action('next'),
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ],
              ),
            ],
            if (streamOn)
              Row(
                children: [
                  const Icon(
                    Icons.headphones_rounded,
                    size: 18,
                    color: NX.working,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(switch (audio.phaseOf(AudioStream.playHere)) {
                      StreamPhase.connecting => 'PC audio here · Connecting…',
                      StreamPhase.retrying => 'PC audio here · Retrying…',
                      _ => 'Listening on this phone',
                    }, style: const TextStyle(color: NX.textDim)),
                  ),
                  TextButton(
                    onPressed: () => unawaited(
                      AudioRuntime.setStream(AudioStream.playHere, false),
                    ),
                    child: const Text('Stop stream'),
                  ),
                ],
              ),
          ],
        ),
      );
    },
  );
}

class _Record extends StatelessWidget {
  const _Record();

  @override
  Widget build(BuildContext context) => Container(
    width: 48,
    height: 48,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: const Color(0xff17191e),
      border: Border.all(color: NX.line),
    ),
    alignment: Alignment.center,
    child: Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xff41414a)),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 14,
        height: 14,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xffe7a68f),
        ),
      ),
    ),
  );
}
