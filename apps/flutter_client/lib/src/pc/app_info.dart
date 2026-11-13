// App info: one app's state, resource usage (for agent apps the monitor
// tracks), what it has open, and its recovery actions. Reached from the app's
// menu in Desktop, Apps and Running. Stays live while open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../rpc/models.dart';
import '../state/app_groups.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../state/launcher_preferences.dart';
import '../theme/nexus_theme.dart';
import '../widgets/app_icon.dart';
import 'app_actions.dart';
import 'pc_ui.dart';

Future<void> openAppInfo(BuildContext context, String key) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'app-info'),
        builder: (_) => AppInfoScreen(entryKey: key),
      ),
    );

/// Builds the current entry for [key] from live providers; terminal agents
/// use `terminal:<agent id>`.
AppEntry? currentEntry(WidgetRef ref, String key) {
  final apps = ref.watch(appsProvider).value ?? const <AppInfo>[];
  final windows = ref.watch(windowsProvider).value ?? const <WindowInfo>[];
  final sessions =
      ref.watch(appSessionsProvider).value ?? const <AppSessionInfo>[];
  final snapshot = ref.watch(monitorProvider.select((s) => s.snapshot));
  final agents = snapshot?.apps ?? const <AgentApp>[];
  if (key.startsWith('terminal:')) {
    final id = key.substring('terminal:'.length);
    final agent = agents.where((a) => a.id == id).firstOrNull;
    return agent == null
        ? null
        : AppEntry(key: key, name: agent.name, agent: agent);
  }
  final running = groupRunning(
    apps: apps,
    windows: windows,
    sessions: sessions,
    agents: agents,
  );
  final all = [
    ...running.apps,
    ...running.unidentified,
    ...drawerApps(
      apps: apps,
      running: running,
      launchers: snapshot?.launchers ?? const [],
    ),
  ];
  return all.where((e) => e.key == key).firstOrNull;
}

class AppInfoScreen extends ConsumerStatefulWidget {
  const AppInfoScreen({super.key, required this.entryKey});
  final String entryKey;

  @override
  ConsumerState<AppInfoScreen> createState() => _AppInfoScreenState();
}

class _AppInfoScreenState extends ConsumerState<AppInfoScreen> {
  /// The last live entry, kept only to name what went away.
  AppEntry? _last;

  @override
  Widget build(BuildContext context) {
    // Launchable apps stay listed (in the drawer) after they close, so a
    // missing entry is something that can't be reopened from here: a terminal
    // agent that exited, a window or phone session that closed. Its commands
    // would act on nothing (or on a reused id), so none are offered.
    final entry = currentEntry(ref, widget.entryKey);
    if (entry != null) _last = entry;
    final apps = ref.watch(appsProvider).value ?? const <AppInfo>[];
    ref.watch(
      launcherPreferencesProvider(ref.watch(connectionProvider).hostUrl ?? ''),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('App info')),
      body: MonitorDemand(
        owner: 'app-info',
        intervalMs: 2000,
        child: entry == null
            ? _Gone(last: _last)
            : ValueListenableBuilder<Map<String, String>>(
                valueListenable: appProgress,
                builder: (context, progress, _) =>
                    _body(context, entry, apps, progress),
              ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppEntry entry,
    List<AppInfo> apps,
    Map<String, String> progress,
  ) {
    final agent = entry.agent;
    final busy = agent == null ? null : progress[agent.id];
    final commands = commandsFor(entry);
    final prefs = launcherPrefs(ref);
    final app = entry.app;
    final favourite = app != null && (prefs?.isFavourite(app) ?? false);
    final items = entry.items;
    return ListView(
      key: const ValueKey('app-info'),
      padding: const EdgeInsets.fromLTRB(NX.pad, 8, NX.pad, 32),
      children: [
        Row(
          children: [
            AppIconTile(icon: entry.icon, name: entry.name, size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    appStateText(entry),
                    style: TextStyle(
                      color: entry.stuck ? NX.waiting : NX.textDim,
                      fontWeight: entry.stuck ? FontWeight.w700 : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (entry.stuck)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'It has stopped responding. Restart closes it (forcing it '
              'if needed) and opens it again.',
              style: TextStyle(color: NX.waiting, fontSize: 13),
            ),
          ),
        if (busy != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(busy)),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (items.isNotEmpty || entry.launchable)
              FilledButton.icon(
                onPressed: busy != null
                    ? null
                    : () => openEntry(context, ref, entry, apps),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 44)),
                icon: Icon(
                  items.isEmpty
                      ? Icons.play_arrow_rounded
                      : Icons.open_in_full_rounded,
                  size: 18,
                ),
                label: Text(items.isEmpty ? 'Open' : 'Resume'),
              ),
            for (final c in AppCommand.values)
              if (commands.contains(c))
                OutlinedButton.icon(
                  key: ValueKey('app-info-${c.name}'),
                  onPressed: busy != null
                      ? null
                      : () => runAppCommand(context, ref, entry, c),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    foregroundColor: c == AppCommand.kill ? NX.waiting : null,
                    side: const BorderSide(color: NX.line),
                  ),
                  icon: Icon(commandIcon(c), size: 18),
                  label: Text(commandLabel(entry, c)),
                ),
          ],
        ),
        if (agent != null) ...[
          const _Header('Resource usage'),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              PcStat(label: 'CPU', value: fmtPct(agent.cpu)),
              PcStat(label: 'MEMORY', value: fmtIec(agent.memory)),
              PcStat(label: 'PROCESSES', value: '${agent.processCount}'),
              PcStat(label: 'RUNNING FOR', value: fmtSince(agent.startedAt)),
            ],
          ),
          if (agent.cwd != null || agent.tty != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                [
                  if (agent.tty != null) agent.tty!,
                  if (agent.cwd != null) shortPath(agent.cwd!),
                ].join(' · '),
                style: const TextStyle(color: NX.textDim, fontSize: 13),
              ),
            ),
        ] else if (entry.running)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              'CPU and memory are tracked for agent apps. For any process, '
              'tap CPU on Desktop, then Processes.',
              style: TextStyle(color: NX.textFaint, fontSize: 12.5),
            ),
          ),
        if (items.isNotEmpty) ...[
          const _Header('Open'),
          for (final item in items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: 48,
              leading: Icon(
                item is SessionItem
                    ? Icons.smartphone_rounded
                    : Icons.web_asset_rounded,
                color: NX.textDim,
              ),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: item is SessionItem
                  ? const Text('On your phone')
                  : null,
              onTap: () => resumeItem(context, item, apps),
            ),
        ],
        if (app != null && prefs != null) ...[
          const _Header('On this phone'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Favourite'),
            subtitle: const Text('Shown on Desktop'),
            value: favourite,
            onChanged: (_) async {
              await prefs.toggleFavourite(app);
              if (mounted) setState(() {});
            },
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(
            app != null
                ? 'App ID ${app.appId}'
                : agent != null
                ? 'Agent ${agent.appId}'
                : entry.windows.isNotEmpty
                ? 'Window ${entry.windows.first.wmClass}'
                : '',
            style: const TextStyle(color: NX.textFaint, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// The entry went away while App info was open: say so, with no actions.
class _Gone extends StatelessWidget {
  const _Gone({this.last});
  final AppEntry? last;

  @override
  Widget build(BuildContext context) {
    final last = this.last;
    final text = last == null
        ? 'This app is no longer open.'
        : '${last.name} is no longer open.';
    return Center(
      key: const ValueKey('app-info-gone'),
      child: Padding(
        padding: const EdgeInsets.all(NX.pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (last != null) ...[
              AppIconTile(icon: last.icon, name: last.name, size: 52),
              const SizedBox(height: 14),
            ],
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: NX.textFaint,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
      ),
    ),
  );
}
