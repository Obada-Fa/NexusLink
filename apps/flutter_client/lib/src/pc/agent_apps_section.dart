// Running agent apps (Claude, Codex, Antigravity, Cursor… and agent CLIs) with
// live CPU, memory and state, plus one-tap Focus / Restart and Quit / Force
// stop. Installed apps that aren't running get a Start chip.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_actions.dart';
import 'pc_ui.dart';

class AgentAppsSection extends ConsumerStatefulWidget {
  const AgentAppsSection({super.key});
  @override
  ConsumerState<AgentAppsSection> createState() => _AgentAppsSectionState();
}

class _AgentAppsSectionState extends ConsumerState<AgentAppsSection>
    with AutomaticKeepAliveClientMixin {
  /// app id (or `launch:<appId>`) → progress text while an action runs.
  final _busy = <String, String>{};

  /// Apps mid-action, so a restarting app keeps its card (and spinner) even
  /// while it is briefly absent from the host's list.
  final _pending = <String, AgentApp>{};

  @override
  bool get wantKeepAlive => _busy.isNotEmpty;

  Future<void> _run(
    String key,
    String progress,
    Future<String> Function() action, {
    AgentApp? app,
  }) async {
    if (_busy.containsKey(key)) return;
    setState(() {
      _busy[key] = progress;
      if (app != null) _pending[key] = app;
    });
    updateKeepAlive();
    final messenger = ScaffoldMessenger.maybeOf(context);
    String message;
    try {
      message = await action();
    } catch (error) {
      message = pcActionError(error);
    }
    if (mounted) {
      setState(() {
        _busy.remove(key);
        _pending.remove(key);
      });
      updateKeepAlive();
    }
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _act(AgentApp app, String action) async {
    final notifier = ref.read(monitorProvider.notifier);
    final name = app.name;
    if (action == 'focus') {
      return _run(
        app.id,
        'Bringing $name to the front…',
        () => notifier.appAction(app, 'focus'),
        app: app,
      );
    }
    final spec = switch (action) {
      'restart' => (
        title: 'Restart $name?',
        body:
            'NexusLink closes $name gracefully. If it’s frozen and still open after 6 seconds, it’s force-stopped. Then it opens again.\n\nUnsaved work in $name may be lost.',
        confirm: 'Restart',
        progress: 'Restarting $name…',
        icon: Icons.restart_alt_rounded,
        destructive: false,
      ),
      'quit' => (
        title: 'Quit $name?',
        body:
            'Closes its windows as if you clicked ×. If it’s still running after 6 seconds, it’s stopped.',
        confirm: 'Quit',
        progress: 'Quitting $name…',
        icon: Icons.logout_rounded,
        destructive: false,
      ),
      _ when app.isDesktop => (
        title: 'Force stop $name?',
        body:
            'Ends all ${app.processCount} of its processes immediately, without letting it save. Use this when Quit doesn’t work.',
        confirm: 'Force stop',
        progress: 'Force-stopping $name…',
        icon: Icons.dangerous_outlined,
        destructive: true,
      ),
      _ => (
        title: 'Stop $name?',
        body:
            'Ends the agent${app.tty == null ? '' : ' in ${app.tty}'}'
            '${app.cwd == null ? '' : ' working in ${shortPath(app.cwd!)}'}. Whatever it’s doing right now is interrupted.',
        confirm: 'Stop',
        progress: 'Stopping $name…',
        icon: Icons.stop_circle_outlined,
        destructive: true,
      ),
    };
    final ok = await confirmPcAction(
      context,
      title: spec.title,
      body: spec.body,
      confirm: spec.confirm,
      icon: spec.icon,
      destructive: spec.destructive,
    );
    if (!ok || !mounted) return;
    await _run(
      app.id,
      spec.progress,
      () => notifier.appAction(app, action),
      app: app,
    );
  }

  void _launch(AgentLauncher launcher) => _run(
    'launch:${launcher.appId}',
    'Starting ${launcher.name}…',
    () => ref.read(monitorProvider.notifier).launch(launcher.appId),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final snapshot = ref.watch(monitorProvider.select((s) => s.snapshot));
    if (snapshot == null) return const SizedBox.shrink();
    final live = snapshot.apps;
    final apps = [
      ...live,
      for (final entry in _pending.entries)
        if (!live.any((a) => a.id == entry.key)) entry.value,
    ];
    final desktop = apps.where((a) => a.isDesktop).toList();
    final cli = apps.where((a) => !a.isDesktop).toList();
    final idle = snapshot.launchers
        .where((l) => !l.running && !apps.any((a) => a.appId == l.appId))
        .toList();
    final stuck = apps.where((a) => a.isStuck).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PcSectionHeader(
          'Agent apps',
          count: apps.length,
          color: stuck > 0 ? NX.stuck : null,
          trailing: stuck > 0
              ? NxPill(
                  '$stuck frozen?',
                  color: NX.stuck,
                  live: true,
                  dense: true,
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NX.pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (apps.isEmpty)
                const NxCard(
                  child: Text(
                    'No agent apps are running on the PC.',
                    style: TextStyle(color: NX.textDim),
                  ),
                ),
              for (final app in desktop)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AgentAppCard(
                    key: ValueKey('agent-app-${app.id}'),
                    app: app,
                    busy: _busy[app.id],
                    onAction: (action) => _act(app, action),
                  ),
                ),
              if (cli.isNotEmpty) ...[
                if (desktop.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(2, 6, 0, 8),
                    child: Text(
                      'In terminals',
                      style: TextStyle(
                        color: NX.textFaint,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                for (final app in cli)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: AgentCliCard(
                      key: ValueKey('agent-cli-${app.id}'),
                      app: app,
                      busy: _busy[app.id],
                      onStop: () => _act(app, 'kill'),
                    ),
                  ),
              ],
              if (idle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final l in idle)
                      _StartChip(
                        launcher: l,
                        busy: _busy.containsKey('launch:${l.appId}'),
                        onStart: () => _launch(l),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Card for a desktop agent app.
class AgentAppCard extends StatelessWidget {
  const AgentAppCard({
    super.key,
    required this.app,
    required this.busy,
    required this.onAction,
  });
  final AgentApp app;
  final String? busy;
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) {
    final stuck = app.isStuck;
    final brand = Providers.color(app.provider);
    final stateColor = Status.color(app.state);
    final windows = app.windows.length;
    final meta = [
      '${app.processCount} ${app.processCount == 1 ? 'process' : 'processes'}',
      if (windows > 0) '$windows ${windows == 1 ? 'window' : 'windows'}',
      'up ${fmtSince(app.startedAt)}',
    ].join(' · ');
    final firstTitle = app.windows.isEmpty
        ? null
        : app.windows.first['title'] as String?;
    return Semantics(
      container: true,
      label:
          '${app.name}, ${Status.label(app.state)}, CPU ${app.cpu.round()} percent, memory ${formatBytes(app.memory)}',
      child: NxCard(
        accent: stuck
            ? NX.stuck
            : app.state == 'busy'
            ? NX.working
            : null,
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ProviderBadge(app.provider, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NX.textDim,
                          fontSize: 12,
                          fontFeatures: NX.tabular,
                        ),
                      ),
                      if (firstTitle != null &&
                          firstTitle.isNotEmpty &&
                          firstTitle != app.name)
                        Text(
                          firstTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NX.textFaint,
                            fontSize: 11.5,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: NxPill(
                    Status.label(app.state),
                    color: stateColor,
                    live: stuck || app.state == 'busy',
                    dense: true,
                  ),
                ),
              ],
            ),
            if (stuck)
              const Padding(
                padding: EdgeInsets.only(top: 10, right: 8),
                child: PcNote(
                  'It has been maxing out a CPU core for over 90 seconds and may be frozen. Restart closes it, force-stops it if needed, and opens it again.',
                  color: NX.stuck,
                  icon: Icons.ac_unit,
                ),
              ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _UsageRow(app: app, color: stuck ? NX.stuck : brand),
            ),
            const SizedBox(height: 8),
            busy != null
                ? _BusyRow(text: busy!, color: stuck ? NX.stuck : brand)
                : _DesktopActions(app: app, onAction: onAction),
          ],
        ),
      ),
    );
  }
}

/// Card for an agent running in a terminal (Claude Code, Codex CLI…).
class AgentCliCard extends StatelessWidget {
  const AgentCliCard({
    super.key,
    required this.app,
    required this.busy,
    required this.onStop,
  });
  final AgentApp app;
  final String? busy;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final brand = Providers.color(app.provider);
    final where = [
      if (app.cwd != null) _tailPath(app.cwd!),
      if (app.tty != null) app.tty!,
    ].join(' · ');
    return Semantics(
      container: true,
      label:
          '${app.name}${app.cwd == null ? '' : ' in ${shortPath(app.cwd!)}'}, ${Status.label(app.state)}, CPU ${app.cpu.round()} percent',
      child: NxCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ProviderBadge(app.provider, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (where.isNotEmpty)
                        Text(
                          where,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NX.textDim,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: NxPill(
                    Status.label(app.state),
                    color: Status.color(app.state),
                    live: app.state == 'busy',
                    dense: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _UsageRow(app: app, color: brand, compact: true),
            ),
            if (busy != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: _BusyRow(text: busy!, color: brand),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${app.processCount} ${app.processCount == 1 ? 'process' : 'processes'} · up ${fmtSince(app.startedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: NX.textFaint,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  if (app.can('kill'))
                    TextButton.icon(
                      onPressed: onStop,
                      style: TextButton.styleFrom(
                        foregroundColor: NX.failed,
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: Text('Stop', semanticsLabel: 'Stop ${app.name}'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Last two path segments, e.g. "…/mobile/NexusLink".
  static String _tailPath(String path) {
    final short = shortPath(path);
    final parts = short.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 3) return short;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.app,
    required this.color,
    this.compact = false,
  });
  final AgentApp app;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final history = app.cpuHistory;
    final peak = history.isEmpty ? 0.0 : history.reduce(math.max);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: history.length < 2
              ? SizedBox(height: compact ? 24 : 32)
              : ExcludeSemantics(
                  child: RepaintBoundary(
                    child: Sparkline(
                      values: history,
                      color: color,
                      // ~2 threads flat out fills the chart; idle stays flat.
                      max: math.max(12.5, peak * 1.15),
                      height: compact ? 24 : 32,
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 12),
        _Metric(label: 'CPU', value: fmtPct(app.cpu), color: NX.heat(app.cpu)),
        const SizedBox(width: 12),
        _Metric(label: 'RAM', value: formatBytes(app.memory), color: NX.text),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          fontFeatures: NX.tabular,
        ),
      ),
      Text(
        label,
        style: const TextStyle(
          color: NX.textFaint,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: .8,
        ),
      ),
    ],
  );
}

class _DesktopActions extends StatelessWidget {
  const _DesktopActions({required this.app, required this.onAction});
  final AgentApp app;
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) {
    final stuck = app.isStuck;
    final more = [
      if (app.can('quit')) ('quit', 'Quit', Icons.logout_rounded),
      if (app.can('kill')) ('kill', 'Force stop', Icons.dangerous_outlined),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final narrow = c.maxWidth / scale < 270;
        return Row(
          children: [
            if (app.can('restart'))
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => onAction('restart'),
                  // Solid only when the app looks frozen; tonal otherwise so
                  // a row of healthy apps doesn't shout.
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    backgroundColor: stuck
                        ? NX.stuck
                        : NX.accent.withValues(alpha: .16),
                    foregroundColor: stuck ? NX.bg : NX.accent,
                  ),
                  icon: const Icon(Icons.restart_alt_rounded, size: 20),
                  label: Text(
                    'Restart',
                    semanticsLabel: 'Restart ${app.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: 8),
            if (app.can('focus') && app.windows.isNotEmpty)
              narrow
                  ? IconButton.outlined(
                      tooltip: 'Focus ${app.name} on the PC',
                      onPressed: () => onAction('focus'),
                      icon: const Icon(Icons.center_focus_strong_outlined),
                    )
                  : OutlinedButton.icon(
                      onPressed: () => onAction('focus'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(
                        Icons.center_focus_strong_outlined,
                        size: 18,
                      ),
                      label: Text(
                        'Focus',
                        semanticsLabel: 'Focus ${app.name} on the PC',
                      ),
                    ),
            if (more.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'More actions for ${app.name}',
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: onAction,
                itemBuilder: (_) => [
                  for (final (id, label, icon) in more)
                    PopupMenuItem(
                      value: id,
                      child: Row(
                        children: [
                          Icon(
                            icon,
                            size: 20,
                            color: id == 'kill' ? NX.failed : NX.textDim,
                          ),
                          const SizedBox(width: 12),
                          Text(label),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _BusyRow extends StatelessWidget {
  const _BusyRow({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: text,
    excludeSemantics: true,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: reduceMotion(context)
                ? Icon(Icons.hourglass_top_rounded, size: 18, color: color)
                : CircularProgressIndicator(strokeWidth: 2.4, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
}

class _StartChip extends StatelessWidget {
  const _StartChip({
    required this.launcher,
    required this.busy,
    required this.onStart,
  });
  final AgentLauncher launcher;
  final bool busy;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => ActionChip(
    tooltip: 'Start ${launcher.name} on the PC',
    avatar: busy
        ? SizedBox.square(
            dimension: 18,
            child: reduceMotion(context)
                ? const Icon(Icons.hourglass_top_rounded, size: 16)
                : const CircularProgressIndicator(strokeWidth: 2),
          )
        : ProviderBadge(launcher.provider, size: 20),
    label: Text(busy ? 'Starting ${launcher.name}…' : 'Start ${launcher.name}'),
    onPressed: busy ? null : onStart,
  );
}
