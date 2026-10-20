import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../chats/chat_models.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import '../widgets/agent_activity_icon.dart';
import '../workspace/project.dart';
import 'monitor_models.dart';
import 'monitor_provider.dart';

/// One shared 1 Hz tick for every running timer on screen.
final secondTickerProvider = StreamProvider.autoDispose<int>(
  (ref) => Stream.periodic(const Duration(seconds: 1), (i) => i),
);

/// Provider logo inside a ring tinted with the provider colour.
class AgentAvatar extends StatelessWidget {
  const AgentAvatar(this.source, {super.key, this.size = 36, this.state});
  final String source;
  final double size;
  final String? state;
  @override
  Widget build(BuildContext context) {
    final c = Providers.color(source);
    final ring = state == null ? c : Status.color(state!);
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .16),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.withValues(alpha: .14),
        border: Border.all(color: ring.withValues(alpha: .75), width: 1.6),
      ),
      child: AgentMark(agentId: source, size: size * .62, color: c),
    );
  }
}

/// Compact live vitals line; tap → PC tab.
class VitalsPulseStrip extends ConsumerWidget {
  const VitalsPulseStrip({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(monitorProvider.select((s) => s.snapshot?.vitals));
    if (v == null) return const SizedBox.shrink();
    final gpu = v.mainGpu;
    Widget chip(String label, String value, Color color, {String? sub}) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: NX.surface2,
              borderRadius: BorderRadius.circular(NX.radiusSm),
              border: Border.all(color: NX.line.withValues(alpha: .6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: const TextStyle(
                        color: NX.textFaint,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .6,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  style: const TextStyle(
                    color: NX.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    fontFeatures: NX.tabular,
                  ),
                ),
                if (sub != null)
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: const TextStyle(
                      color: NX.textFaint,
                      fontSize: 10.5,
                      fontFeatures: NX.tabular,
                    ),
                  ),
              ],
            ),
          ),
        );
    return Semantics(
      button: true,
      label: 'PC vitals. CPU ${v.cpu.round()} percent. Open PC tab',
      child: GestureDetector(
        onTap: () => ref.read(workspaceTabProvider.notifier).select(3),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(NX.pad, 4, NX.pad, 0),
          child: Row(
            children: [
              chip(
                'CPU',
                '${v.cpu.round()}%',
                NX.heat(v.cpu),
                sub: v.cpuTempC == null ? null : '${v.cpuTempC!.round()}°C',
              ),
              const SizedBox(width: 8),
              chip(
                'GPU',
                gpu?.busy == null ? '—' : '${gpu!.busy!.round()}%',
                NX.heat(gpu?.busy ?? 0),
                sub: gpu?.tempC == null
                    ? null
                    : '${(gpu!.hotspotC ?? gpu.tempC)!.round()}°C',
              ),
              const SizedBox(width: 8),
              chip(
                'RAM',
                '${v.ramPercent.round()}%',
                NX.heat(v.ramPercent),
                sub: formatBytes(v.ramUsed),
              ),
              const SizedBox(width: 8),
              chip(
                'NET',
                '${_short(v.netRx)}/s',
                NX.accent,
                sub: 'up ${_short(v.netTx)}/s',
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _short(double bps) {
    if (bps >= 1024 * 1024) return '${(bps / 1048576).toStringAsFixed(1)}M';
    if (bps >= 1024) return '${(bps / 1024).round()}K';
    return '${bps.round()}B';
  }
}

/// Big glanceable counters that double as filters.
class StatusCounters extends StatelessWidget {
  const StatusCounters({
    super.key,
    required this.working,
    required this.waiting,
    required this.done,
    required this.filter,
    required this.onFilter,
  });
  final int working;
  final int waiting;
  final int done;
  final String filter;
  final ValueChanged<String> onFilter;
  @override
  Widget build(BuildContext context) {
    Widget tile(
      String key,
      String label,
      int count,
      Color color,
      IconData icon,
    ) {
      final selected = filter == key;
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: '$count $label',
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onFilter(selected ? 'all' : key);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: selected ? color.withValues(alpha: .16) : NX.surface2,
                borderRadius: BorderRadius.circular(NX.radiusSm + 2),
                border: Border.all(
                  color: selected
                      ? color.withValues(alpha: .7)
                      : NX.line.withValues(alpha: .6),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: count > 0 ? color : NX.textFaint,
                              fontSize: 24,
                              height: 1.05,
                              fontWeight: FontWeight.w900,
                              fontFeatures: NX.tabular,
                            ),
                          ),
                        ),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NX.textDim,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (key == 'running' && count > 0)
                    LiveDot(color: color, size: 7)
                  else
                    Icon(
                      icon,
                      size: 16,
                      color: count > 0 ? color : NX.textFaint,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
      child: Row(
        children: [
          tile('running', 'Working', working, NX.working, Icons.bolt_rounded),
          const SizedBox(width: 8),
          tile(
            'attention',
            'Needs you',
            waiting,
            NX.waiting,
            Icons.front_hand_rounded,
          ),
          const SizedBox(width: 8),
          tile(
            'recent',
            'Done today',
            done,
            NX.done,
            Icons.check_circle_rounded,
          ),
        ],
      ),
    );
  }
}

IconData activityIcon(String? activity) => switch (activity) {
  'editing' => Icons.edit_note_rounded,
  'reading' => Icons.menu_book_rounded,
  'searching' => Icons.travel_explore_rounded,
  'running-command' => Icons.terminal_rounded,
  'thinking' => Icons.psychology_rounded,
  'responding' => Icons.chat_bubble_outline_rounded,
  'browsing' => Icons.public_rounded,
  'waiting' => Icons.front_hand_rounded,
  _ => Icons.auto_awesome_rounded,
};

/// A chat that is working, waiting for the owner, or just failed.
class LiveAgentCard extends ConsumerWidget {
  const LiveAgentCard({
    super.key,
    required this.chat,
    required this.onOpen,
    this.onLongPress,
    this.offline = false,
  });
  final ChatSummary chat;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final bool offline;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(secondTickerProvider);
    final state = offline ? 'idle' : chat.liveState;
    final color = Status.color(state);
    final live = chat.live;
    final started = chat.turnStartedAt;
    final todos = live?.todos ?? const [];
    final last = chat.lastWriteAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 10),
      child: NxCard(
        accent: offline ? null : color,
        onTap: onOpen,
        onLongPress: onLongPress,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AgentAvatar(chat.source, size: 34, state: state),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NX.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '${chat.sourceName} · ${chat.folderName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NX.textFaint,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      NxPill(
                        offline
                            ? '${Status.label(chat.liveState)} · last known'
                            : Status.label(state),
                        color: color,
                        live: state == 'working',
                        dense: true,
                      ),
                      if (started != null && state == 'working') ...[
                        const SizedBox(height: 4),
                        Text(
                          formatElapsed(DateTime.now().difference(started)),
                          style: const TextStyle(
                            color: NX.textDim,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            fontFeatures: NX.tabular,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    state == 'waiting'
                        ? Icons.front_hand_rounded
                        : state == 'failed'
                        ? Icons.error_outline_rounded
                        : activityIcon(
                            live?.activity ?? chat.json['activity'] as String?,
                          ),
                    size: 17,
                    color: color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chat.stepLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: state == 'waiting' ? NX.waiting : NX.text,
                        fontSize: 13.5,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (todos.isNotEmpty) ...[
              const SizedBox(height: 10),
              _TodoProgress(
                done: live!.todosDone,
                total: todos.length,
                active: live.activeTodo,
                color: color,
              ),
            ],
            if (live?.lastText != null && live!.lastText != chat.stepLabel) ...[
              const SizedBox(height: 8),
              Text(
                live.lastText!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: NX.textDim,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (live?.model != null) ...[
                  Icon(
                    Icons.memory_rounded,
                    size: 13,
                    color: NX.textFaint.withValues(alpha: .9),
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      live!.model!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: NX.textFaint, fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                if (live?.steps != null) ...[
                  Text(
                    '${live!.steps} steps',
                    style: const TextStyle(
                      color: NX.textFaint,
                      fontSize: 11,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: last == null
                      ? const SizedBox.shrink()
                      : Text(
                          _ago(last),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            color: NX.textFaint,
                            fontSize: 11,
                            fontFeatures: NX.tabular,
                          ),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 5) return 'active now';
    if (s < 60) return '${s}s ago';
    return chatRelativeTime(t);
  }
}

class _TodoProgress extends StatelessWidget {
  const _TodoProgress({
    required this.done,
    required this.total,
    required this.active,
    required this.color,
  });
  final int done;
  final int total;
  final String? active;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            'Plan',
            style: const TextStyle(
              color: NX.textFaint,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: .5,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: Stack(
                children: [
                  Container(height: 5, color: NX.line.withValues(alpha: .7)),
                  AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 600),
                    widthFactor: total == 0 ? 0 : done / total,
                    child: Container(height: 5, color: color),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$done/$total',
            style: const TextStyle(
              color: NX.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              fontFeatures: NX.tabular,
            ),
          ),
        ],
      ),
      if (active != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.play_arrow_rounded, size: 14, color: color),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  active!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: NX.textDim, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// Finished / idle chat — one dense row.
class RecentChatRow extends StatelessWidget {
  const RecentChatRow({
    super.key,
    required this.chat,
    required this.onOpen,
    this.onLongPress,
  });
  final ChatSummary chat;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  @override
  Widget build(BuildContext context) {
    final state = chat.liveState;
    return InkWell(
      onTap: onOpen,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NX.pad, vertical: 10),
        child: Row(
          children: [
            AgentAvatar(
              chat.source,
              size: 30,
              state: state == 'done' ? 'done' : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: NX.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      chat.folderName,
                      if ((chat.live?.lastText ?? chat.preview).isNotEmpty)
                        chat.live?.lastText ?? chat.preview,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: NX.textFaint, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  chatRelativeTime(chat.activity),
                  style: const TextStyle(color: NX.textFaint, fontSize: 11.5),
                ),
                if (!chat.canReply)
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Text(
                      'read only',
                      style: TextStyle(color: NX.textFaint, fontSize: 10.5),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Running agent apps on the PC with one-tap restart (e.g. a lagging Antigravity).
class AgentAppsStrip extends ConsumerWidget {
  const AgentAppsStrip({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(monitorProvider.select((s) => s.snapshot));
    if (snap == null) return const SizedBox.shrink();
    final apps = snap.apps;
    final idleLaunchers = snap.launchers.where((l) => !l.running).toList();
    if (apps.isEmpty && idleLaunchers.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NxSectionHeader('Agent apps on PC', count: apps.length),
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NX.pad),
            children: [
              for (final app in apps) _AppTile(app: app),
              for (final l in idleLaunchers) _LauncherTile(launcher: l),
            ],
          ),
        ),
      ],
    );
  }
}

class _AppTile extends ConsumerWidget {
  const _AppTile({required this.app});
  final AgentApp app;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Status.color(app.state == 'busy' ? 'working' : app.state);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: 148,
        child: NxCard(
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 8),
          accent: app.state == 'stuck' ? NX.stuck : null,
          onTap: () => showAgentAppSheet(context, ref, app),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AgentAvatar(app.provider, size: 22),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      app.isDesktop
                          ? app.name
                          : '${app.name}${app.cwd == null ? '' : ' · ${app.cwd!.split('/').last}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: NX.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Sparkline(
                values: app.cpuHistory,
                color: color,
                height: 20,
                max: null,
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Text(
                    app.state == 'stuck'
                        ? 'Frozen?'
                        : '${app.cpu.toStringAsFixed(app.cpu < 10 ? 1 : 0)}% CPU',
                    style: TextStyle(
                      color: app.state == 'stuck' ? NX.stuck : NX.textDim,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatBytes(app.memory),
                    style: const TextStyle(
                      color: NX.textFaint,
                      fontSize: 10.5,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LauncherTile extends ConsumerWidget {
  const _LauncherTile({required this.launcher});
  final AgentLauncher launcher;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: SizedBox(
      width: 112,
      child: NxCard(
        padding: const EdgeInsets.all(10),
        color: NX.surface,
        onTap: () async {
          final msg = await ref
              .read(monitorProvider.notifier)
              .launch(launcher.appId)
              .catchError((Object e) => '$e');
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(msg)));
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Opacity(
              opacity: .6,
              child: AgentAvatar(launcher.provider, size: 22),
            ),
            const Spacer(),
            Text(
              launcher.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: NX.textDim,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Text(
              'Tap to start',
              style: TextStyle(color: NX.textFaint, fontSize: 10.5),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showAgentAppSheet(
  BuildContext context,
  WidgetRef ref,
  AgentApp app,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, NX.pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AgentAvatar(app.provider, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.name,
                        style: const TextStyle(
                          color: NX.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${app.cpu.toStringAsFixed(1)}% CPU · ${formatBytes(app.memory)} · ${app.processCount} processes · up ${formatElapsed(DateTime.now().difference(app.startedAt))}',
                        style: const TextStyle(
                          color: NX.textDim,
                          fontSize: 12,
                          fontFeatures: NX.tabular,
                        ),
                      ),
                    ],
                  ),
                ),
                NxPill(
                  app.state == 'stuck'
                      ? 'Frozen?'
                      : Status.label(
                          app.state == 'busy' ? 'working' : app.state,
                        ),
                  color: Status.color(
                    app.state == 'busy' ? 'working' : app.state,
                  ),
                ),
              ],
            ),
            if (app.cwd != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  app.cwd!,
                  style: const TextStyle(color: NX.textFaint, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            Sparkline(values: app.cpuHistory, color: NX.accent, height: 46),
            const SizedBox(height: 12),
            if (app.actions.contains('focus'))
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('Bring to front on PC'),
                onTap: () => Navigator.pop(ctx, 'focus'),
              ),
            if (app.actions.contains('restart'))
              ListTile(
                leading: const Icon(
                  Icons.restart_alt_rounded,
                  color: NX.accent,
                ),
                title: Text('Restart ${app.name}'),
                subtitle: const Text(
                  'Closes it normally, force-stops it if frozen, then starts it again',
                ),
                onTap: () => Navigator.pop(ctx, 'restart'),
              ),
            if (app.actions.contains('quit'))
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('Quit'),
                onTap: () => Navigator.pop(ctx, 'quit'),
              ),
            if (app.actions.contains('kill'))
              ListTile(
                leading: const Icon(Icons.dangerous_rounded, color: NX.failed),
                title: Text(app.isDesktop ? 'Force stop' : 'Stop this agent'),
                subtitle: const Text('Unsaved work in it may be lost'),
                onTap: () => Navigator.pop(ctx, 'kill'),
              ),
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  if (action == 'kill' || action == 'quit') {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          action == 'kill' ? 'Force stop ${app.name}?' : 'Quit ${app.name}?',
        ),
        content: Text(
          action == 'kill'
              ? 'Every ${app.name} process on the PC is stopped immediately.'
              : '${app.name} is asked to close normally.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action == 'kill' ? 'Force stop' : 'Quit'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.of(context);
  if (action == 'restart') {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Restarting ${app.name}…'),
        duration: const Duration(seconds: 12),
      ),
    );
  }
  final msg = await ref
      .read(monitorProvider.notifier)
      .appAction(app, action)
      .catchError((Object e) => 'Couldn’t do that: $e');
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// Live "x working" title badge for app bars.
class MissionTitle extends StatelessWidget {
  const MissionTitle({super.key, required this.subtitle, required this.online});
  final String subtitle;
  final bool online;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Mission Control',
        style: TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w900,
          letterSpacing: -.3,
        ),
      ),
      Row(
        children: [
          LiveDot(color: online ? NX.working : NX.idle, size: 6, pulse: false),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: NX.textDim,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Shown on the home screen only when remote access is actually broken.
class RemoteAccessAlert extends ConsumerStatefulWidget {
  const RemoteAccessAlert({super.key});
  @override
  ConsumerState<RemoteAccessAlert> createState() => _RemoteAccessAlertState();
}

class _RemoteAccessAlertState extends ConsumerState<RemoteAccessAlert> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final rustdesk = ref.watch(
      monitorProvider.select((s) => s.snapshot?.service('rustdesk')),
    );
    if (rustdesk == null || !rustdesk.installed) return const SizedBox.shrink();
    final broken =
        rustdesk.state == 'down' ||
        rustdesk.issues.any(
          (i) =>
              i.contains('not serving') ||
              i.contains('attached to display') ||
              i.contains('not listening'),
        );
    if (!broken) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(NX.pad, 10, NX.pad, 0),
      child: NxCard(
        accent: NX.failed,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            const Icon(Icons.desktop_access_disabled_rounded, color: NX.failed),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'RustDesk can’t reach your desktop',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                    ),
                  ),
                  Text(
                    rustdesk.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: NX.textDim, fontSize: 12),
                  ),
                ],
              ),
            ),
            _busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      setState(() => _busy = true);
                      final msg = await ref
                          .read(monitorProvider.notifier)
                          .remoteAction('rustdesk', 'restart')
                          .catchError((Object e) => '$e');
                      if (!mounted) return;
                      setState(() => _busy = false);
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          duration: const Duration(seconds: 8),
                        ),
                      );
                    },
                    child: const Text('Restart'),
                  ),
          ],
        ),
      ),
    );
  }
}

enum ChatAction { open, markDone, flagAgain, hide, unhide, files }

/// Long-press menu for any chat card, row or Arena fox.
Future<ChatAction?> showChatActions(
  BuildContext context,
  ChatSummary chat, {
  required bool canEdit,
}) => showModalBottomSheet<ChatAction>(
  context: context,
  builder: (ctx) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, NX.pad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AgentAvatar(chat.source, size: 36, state: chat.liveState),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chat.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${chat.sourceName} · ${chat.folderName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: NX.textDim, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded),
            title: const Text('Open chat'),
            onTap: () => Navigator.pop(ctx, ChatAction.open),
          ),
          if (canEdit && chat.needsAttention)
            ListTile(
              leading: const Icon(
                Icons.check_circle_rounded,
                color: NX.working,
              ),
              title: const Text('Mark as done'),
              subtitle: const Text(
                'Leaves Needs you until this chat does something new',
              ),
              onTap: () => Navigator.pop(ctx, ChatAction.markDone),
            ),
          if (canEdit && chat.attentionCleared == 'acknowledged')
            ListTile(
              leading: const Icon(Icons.front_hand_rounded, color: NX.waiting),
              title: const Text('Flag as needing me again'),
              onTap: () => Navigator.pop(ctx, ChatAction.flagAgain),
            ),
          if (canEdit && !chat.archived)
            ListTile(
              leading: const Icon(Icons.visibility_off_rounded),
              title: const Text('Hide from Monitor'),
              subtitle: const Text(
                'Only on NexusLink; the chat stays in its app. Find it under Filter → Hidden chats',
              ),
              onTap: () => Navigator.pop(ctx, ChatAction.hide),
            ),
          if (canEdit && chat.archived)
            ListTile(
              leading: const Icon(Icons.visibility_rounded),
              title: const Text('Show in Monitor'),
              onTap: () => Navigator.pop(ctx, ChatAction.unhide),
            ),
          if (chat.folderPath != null)
            ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('Open project files'),
              onTap: () => Navigator.pop(ctx, ChatAction.files),
            ),
        ],
      ),
    ),
  ),
);
