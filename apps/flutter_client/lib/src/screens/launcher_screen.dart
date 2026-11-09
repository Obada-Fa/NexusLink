// Desktop: the PC's home screen on the phone, in three destinations.
//
//  * Desktop — how the PC is doing (compact readings), favourite apps, Open
//    desktop / View only, and what is open to resume.
//  * Apps — every launchable app (agent apps included), searchable.
//  * Running — one entry per open app; agents in terminals; windows no app
//    was found for, by title.
//
// A tap does the same everywhere (see openEntry): closed → launch, one
// window → resume, several → choose by title. Each app has one menu with
// favourites, App info and its supported actions. Each destination keeps its
// own scroll position, and the search survives switching and the viewer.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../pc/app_actions.dart';
import '../pc/desktop_overview.dart';
import '../pc/pc_actions.dart';
import '../pc/pc_ui.dart';
import '../rpc/models.dart';
import '../state/app_groups.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../state/launcher_preferences.dart';
import '../theme/nexus_theme.dart';
import '../widgets/app_icon.dart';
import '../workspace/workspace_shell.dart';

class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});

  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

/// Rebuild Desktop when an agent app appears, changes state or windows, not
/// on every 2-second vitals push.
String _agentSignature(MonitorSnapshot? s) {
  if (s == null) return '';
  final apps = s.apps
      .map(
        (a) => '${a.id}/${a.state}/${a.windows.map((w) => w['id']).join(',')}',
      )
      .join(';');
  final launchers = s.launchers.map((l) => '${l.appId}/${l.running}').join(';');
  return '$apps|$launchers';
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  static const desktopTab = 0, appsTab = 1, runningTab = 2;

  String _search = '';
  int _tab = desktopTab;
  final _desktopScroll = ScrollController();
  final _appsScroll = ScrollController();
  final _runningScroll = ScrollController();
  final _searchField = TextEditingController();

  @override
  void dispose() {
    _desktopScroll.dispose();
    _appsScroll.dispose();
    _runningScroll.dispose();
    _searchField.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await Future.wait([
      ref.read(appsProvider.notifier).refresh(),
      ref.read(windowsProvider.notifier).refresh(),
      ref.read(appSessionsProvider.notifier).refresh(),
      ref.read(monitorProvider.notifier).refresh(),
    ]);
  }

  void _open(AppEntry entry, List<AppInfo> apps) =>
      openEntry(context, ref, entry, apps);

  void _menu(AppEntry entry) =>
      showAppMenu(context, ref, entry, onChanged: () => setState(() {}));

  @override
  Widget build(BuildContext context) {
    final appsAsync = ref.watch(appsProvider);
    final apps = appsAsync.value ?? const <AppInfo>[];
    final windows = ref.watch(windowsProvider).value ?? const <WindowInfo>[];
    final sessions =
        ref.watch(appSessionsProvider).value ?? const <AppSessionInfo>[];
    final preferences = ref
        .watch(
          launcherPreferencesProvider(
            ref.watch(connectionProvider).hostUrl ?? '',
          ),
        )
        .value;
    ref.watch(monitorProvider.select((s) => _agentSignature(s.snapshot)));
    final snapshot = ref.read(monitorProvider).snapshot;
    final client = ref.watch(activeClientProvider);
    final monitor = snapshot != null || hostSupportsMonitor(client);
    final running = groupRunning(
      apps: apps,
      windows: windows,
      sessions: sessions,
      agents: snapshot?.apps ?? const [],
    );
    final drawer = drawerApps(
      apps: apps,
      running: running,
      launchers: snapshot?.launchers ?? const [],
    );
    // The shell keeps every visited tab mounted; only stream while shown.
    final visible = TickerMode.valuesOf(context).enabled;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: NX.pad,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              desktopTitle(ref),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const DesktopStatusLine(),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More options',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) {
              if (action == 'settings') {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const PcScreen()));
              } else {
                disconnectFromPc(context, ref);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'settings',
                child: _menuRow(Icons.settings_outlined, 'Settings'),
              ),
              PopupMenuItem(
                value: 'disconnect',
                child: _menuRow(Icons.power_settings_new, 'Disconnect from PC'),
              ),
            ],
          ),
        ],
      ),
      body: MonitorDemand(
        owner: 'pc',
        intervalMs: 2000,
        active: visible && monitor && _tab != appsTab,
        child: ValueListenableBuilder<Map<String, String>>(
          valueListenable: appProgress,
          builder: (context, progress, _) => IndexedStack(
            index: _tab,
            children: [
              _desktop(monitor, drawer, running, apps, preferences, progress),
              _apps(drawer, apps, preferences, appsAsync, progress),
              _running(running, apps, progress),
            ],
          ),
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: NX.line)),
        ),
        child: NavigationBar(
          key: const ValueKey('desktop-nav'),
          selectedIndex: _tab,
          elevation: 0,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.desktop_windows_outlined),
              selectedIcon: Icon(Icons.desktop_windows),
              label: 'Desktop',
            ),
            const NavigationDestination(
              icon: Icon(Icons.apps_outlined),
              selectedIcon: Icon(Icons.apps),
              label: 'Apps',
            ),
            NavigationDestination(
              icon: Badge.count(
                count: running.count,
                isLabelVisible: running.count > 0,
                backgroundColor: running.apps.any((e) => e.stuck)
                    ? NX.waiting
                    : null,
                child: const Icon(Icons.layers_outlined),
              ),
              selectedIcon: Badge.count(
                count: running.count,
                isLabelVisible: running.count > 0,
                backgroundColor: running.apps.any((e) => e.stuck)
                    ? NX.waiting
                    : null,
                child: const Icon(Icons.layers),
              ),
              label: 'Running',
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Desktop

  Widget _desktop(
    bool monitor,
    List<AppEntry> drawer,
    RunningApps running,
    List<AppInfo> apps,
    LauncherPreferences? preferences,
    Map<String, String> progress,
  ) {
    final favourites = [
      for (final e in drawer)
        if (e.app != null && (preferences?.isFavourite(e.app!) ?? false)) e,
    ];
    final open = [...running.apps, ...running.unidentified];
    const resumeLimit = 4;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const PageStorageKey('desktop-home'),
        controller: _desktopScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          monitor ? const DesktopReadings() : const LegacyDesktopReadings(),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NX.pad),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('open-desktop'),
                  onPressed: () => openDesktop(context, viewOnly: false),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.desktop_windows_outlined, size: 20),
                  label: const Text('Open desktop'),
                ),
                TextButton.icon(
                  onPressed: () => openDesktop(context, viewOnly: true),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.visibility_outlined, size: 20),
                  label: const Text('View only'),
                ),
              ],
            ),
          ),
          _header(
            'Favourites',
            action: TextButton(
              onPressed: () => setState(() => _tab = appsTab),
              child: const Text('All apps'),
            ),
          ),
          if (favourites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: NX.pad),
              child: Text(
                'In Apps, open an app’s menu and add it to favourites.',
                style: TextStyle(color: NX.textDim, fontSize: 13),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NX.pad - 4),
              child: _grid(favourites, apps),
            ),
          _header(
            'Open apps',
            action: running.count > resumeLimit
                ? TextButton(
                    onPressed: () => setState(() => _tab = runningTab),
                    child: Text('All ${running.count}'),
                  )
                : null,
          ),
          if (open.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: NX.pad),
              child: Text(
                'Nothing is open on the PC.',
                style: TextStyle(color: NX.textDim, fontSize: 13),
              ),
            ),
          for (final e in open.take(resumeLimit))
            _row(e, apps, progress, key: ValueKey('resume-${e.key}')),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Apps

  Widget _apps(
    List<AppEntry> drawer,
    List<AppInfo> apps,
    LauncherPreferences? preferences,
    AsyncValue<List<AppInfo>> appsAsync,
    Map<String, String> progress,
  ) {
    final q = _search.trim().toLowerCase();
    final shown = q.isEmpty
        ? drawer
        : drawer.where((e) => e.name.toLowerCase().contains(q)).toList();
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const PageStorageKey('desktop-apps'),
        controller: _appsScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 12, bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NX.pad),
            child: TextField(
              controller: _searchField,
              onChanged: (value) => setState(() => _search = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search apps',
                border: const OutlineInputBorder(),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _searchField.clear();
                          _search = '';
                        }),
                      ),
              ),
            ),
          ),
          if (appsAsync.isLoading && apps.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(NX.pad, 8, NX.pad, 0),
              child: LinearProgressIndicator(),
            ),
          if (appsAsync.hasError)
            const Padding(
              padding: EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
              child: Text('Could not load apps. Pull down to retry.'),
            ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(NX.pad),
              child: Text(
                q.isEmpty
                    ? 'No apps reported by this PC.'
                    : 'No matching apps on this PC.',
                style: const TextStyle(color: NX.textDim),
              ),
            ),
          for (final e in shown)
            _row(
              e,
              apps,
              progress,
              key: ValueKey('app-${e.key}'),
              favourite:
                  e.app != null && (preferences?.isFavourite(e.app!) ?? false),
              drawer: true,
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Running

  Widget _running(
    RunningApps running,
    List<AppInfo> apps,
    Map<String, String> progress,
  ) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const PageStorageKey('desktop-running'),
        controller: _runningScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          if (running.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(NX.pad, 48, NX.pad, 0),
              child: Center(
                child: Text(
                  'Nothing is open on the PC.',
                  style: TextStyle(color: NX.textDim, fontSize: 15),
                ),
              ),
            ),
          for (final e in running.apps)
            _row(e, apps, progress, key: ValueKey('running-${e.key}')),
          if (running.terminals.isNotEmpty) ...[
            _header('In terminals'),
            for (final a in running.terminals)
              _row(
                AppEntry(key: 'terminal:${a.id}', name: a.name, agent: a),
                apps,
                progress,
                key: ValueKey('terminal-${a.id}'),
                terminal: true,
              ),
          ],
          if (running.unidentified.isNotEmpty) ...[
            _header('Other windows'),
            for (final e in running.unidentified)
              _row(e, apps, progress, key: ValueKey('window-${e.key}')),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Pieces

  static Widget _menuRow(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 20, color: NX.textDim),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );

  static Widget _header(String text, {Widget? action}) => Padding(
    padding: EdgeInsets.fromLTRB(NX.pad, 18, action == null ? NX.pad : 4, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: NX.textDim,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ?action,
      ],
    ),
  );

  /// One app row: icon, name (with "Not responding" beside it when frozen),
  /// what it has open, and its menu.
  Widget _row(
    AppEntry e,
    List<AppInfo> apps,
    Map<String, String> progress, {
    Key? key,
    bool favourite = false,
    bool drawer = false,
    bool terminal = false,
  }) {
    final agent = e.agent;
    final busy = agent == null ? null : progress[agent.id];
    final String? subtitle;
    if (busy != null) {
      subtitle = busy;
    } else if (terminal && agent != null) {
      subtitle = [
        if (agent.tty != null) agent.tty!,
        if (agent.cwd != null) shortPath(agent.cwd!),
      ].join(' · ');
    } else if (drawer) {
      subtitle = e.running ? (e.detail ?? 'Running') : null;
    } else if (!e.identified) {
      final cls = e.windows.isEmpty
          ? null
          : bestWindowName(e.windows.first, apps);
      subtitle = cls == e.name ? null : cls;
    } else {
      subtitle =
          e.detail ??
          (e.openCount == 0 && agent != null ? 'No window shown' : null);
    }
    return Semantics(
      container: true,
      child: ListTile(
        key: key,
        minTileHeight: 56,
        contentPadding: const EdgeInsets.only(left: NX.pad, right: 4),
        leading: terminal
            ? const SizedBox.square(
                dimension: 36,
                child: Icon(Icons.terminal_rounded, color: NX.textDim),
              )
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  AppIconTile(icon: e.icon, name: e.name, size: 36),
                  if (drawer && e.running)
                    const Positioned(
                      right: -2,
                      bottom: -2,
                      child: Icon(Icons.circle, size: 8, color: NX.working),
                    ),
                ],
              ),
        // The name and its state tag wrap at large text instead of clipping.
        title: Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (e.stuck) const _StuckTag(),
            if (favourite)
              const Icon(Icons.star_rounded, size: 15, color: NX.textDim),
          ],
        ),
        subtitle: subtitle == null || subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: NX.textDim),
              ),
        onTap: busy != null
            ? null
            : terminal
            ? () => _menu(e)
            : () => _open(e, apps),
        onLongPress: () => _menu(e),
        trailing: busy != null
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: 'Actions for ${e.name}',
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => _menu(e),
              ),
      ),
    );
  }

  Widget _grid(List<AppEntry> entries, List<AppInfo> apps) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: EdgeInsets.zero,
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 88,
      mainAxisSpacing: 10,
      crossAxisSpacing: 4,
      // Icon + gap + one label line, which grows with the text size.
      mainAxisExtent: 70 + MediaQuery.textScalerOf(context).scale(11.5) * 1.5,
    ),
    itemCount: entries.length,
    itemBuilder: (_, i) {
      final e = entries[i];
      return Semantics(
        button: true,
        label:
            '${e.name}${e.stuck
                ? ', not responding'
                : e.running
                ? ', running'
                : ''}',
        hint: 'Long-press for the app menu',
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey('fav-${e.key}'),
          onTap: () => _open(e, apps),
          onLongPress: () => _menu(e),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AppIconTile(icon: e.icon, name: e.name, size: 48),
                    if (e.running)
                      Positioned(
                        bottom: -4,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Icon(
                            Icons.circle,
                            size: 5,
                            color: e.stuck ? NX.waiting : NX.working,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: NX.textDim),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _StuckTag extends StatelessWidget {
  const _StuckTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: NX.waiting.withValues(alpha: .6)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: const Text(
      'Not responding',
      style: TextStyle(
        color: NX.waiting,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
