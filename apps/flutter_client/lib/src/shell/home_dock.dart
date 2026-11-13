import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_provider.dart';
import '../pc/app_actions.dart';
import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../session/target.dart';
import '../state/app_groups.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../state/launcher_preferences.dart';
import '../theme/nexus_theme.dart';
import '../widgets/app_icon.dart';
import 'auto_connect.dart';
import 'tiles.dart';

/// Favourites on Home and running apps in its bottom bar.
class HomeDock extends ConsumerWidget {
  const HomeDock({
    super.key,
    required this.target,
    required this.visible,
    this.favourites = false,
  });
  final SavedTarget target;
  final bool visible;
  final bool favourites;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(connectionProvider);
    final host = nexusLinkUrlOf(target);
    if (!visible ||
        host == null ||
        c.hostUrl != host ||
        c.status != RpcStatus.connected ||
        c.client == null) {
      return const SizedBox.shrink();
    }
    final capabilities = c.client!.capabilities['capabilities'];
    if (c.client!.capabilities.isNotEmpty &&
        !c.client!.supports('apps.list') &&
        !(capabilities is List && capabilities.contains('apps'))) {
      return const SizedBox.shrink();
    }
    return MonitorDemand(
      owner: favourites ? 'home-favourites' : 'home-running-apps',
      active: !favourites && hostSupportsMonitor(c.client),
      child: _HomeApps(
        key: ValueKey(host),
        host: host,
        favourites: favourites,
        actionContext: context,
        actionRef: ref,
      ),
    );
  }
}

class _HomeApps extends ConsumerWidget {
  const _HomeApps({
    super.key,
    required this.host,
    required this.favourites,
    required this.actionContext,
    required this.actionRef,
  });
  final String host;
  final bool favourites;
  final BuildContext actionContext;
  final WidgetRef actionRef;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(appsProvider).value ?? const <AppInfo>[];
    final running = groupRunning(
      apps: apps,
      windows: ref.watch(windowsProvider).value ?? const [],
      sessions: ref.watch(appSessionsProvider).value ?? const [],
      agents: ref.watch(monitorProvider).snapshot?.apps ?? const [],
    );
    final prefs = ref.watch(launcherPreferencesProvider(host)).value;
    if (prefs == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final entries = favourites
            ? [
                for (final app in apps.where(prefs.isFavourite))
                  running.forApp(app) ??
                      AppEntry(
                        key: app.appId,
                        name: app.name,
                        app: app,
                        icon: app.icon,
                      ),
              ]
            : [
                ...running.apps,
                for (final agent in running.terminals)
                  AppEntry(
                    key: 'terminal:${agent.id}',
                    name: agent.name,
                    agent: agent,
                  ),
                ...running.unidentified,
              ];
        Widget tile(AppEntry e) => InkWell(
          key: ValueKey(
            '${favourites ? 'home-favourite' : 'dock-app'}-${e.key}',
          ),
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            if (!_stillConnected(actionRef, host)) return;
            if (e.app != null) {
              await _openPinned(actionContext, actionRef, e.app!, host);
            } else if (e.agent?.isDesktop == false) {
              showAppMenu(actionContext, actionRef, e);
            } else {
              await openEntry(actionContext, actionRef, e, apps);
            }
          },
          onLongPress: () {
            if (_stillConnected(actionRef, host)) {
              showAppMenu(actionContext, actionRef, e);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIconTile(
                  icon: e.icon,
                  name: e.name,
                  size: favourites ? 54 : 44,
                ),
                const SizedBox(height: 6),
                Text(
                  e.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: favourites ? 14 : 12),
                ),
              ],
            ),
          ),
        );
        if (favourites) {
          return Padding(
            key: const ValueKey('home-favourites'),
            padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Favourite apps',
                        style: TextStyle(color: NX.textDim),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Choose favourite apps',
                      onPressed: () =>
                          _showSheet(actionContext, host, pin: true),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
                if (entries.isEmpty)
                  TextButton(
                    onPressed: () => _showSheet(actionContext, host, pin: true),
                    child: const Text('Add favourite apps'),
                  )
                else
                  ToolGrid(children: [for (final e in entries) tile(e)]),
              ],
            ),
          );
        }
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Container(
              key: const ValueKey('home-dock'),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: NX.surface2,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: NX.line),
              ),
              height: 68 + MediaQuery.textScalerOf(context).scale(12) * 2,
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        'No apps running',
                        style: TextStyle(color: NX.textDim),
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 4),
                      itemBuilder: (_, i) => SizedBox(
                        width:
                            80 *
                            MediaQuery.textScalerOf(context).scale(12) /
                            12,
                        child: tile(entries[i]),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

bool _stillConnected(WidgetRef ref, String host) {
  final c = ref.read(connectionProvider);
  return c.hostUrl == host && c.status == RpcStatus.connected;
}

AppEntry _entry(WidgetRef ref, AppInfo app) {
  final apps = ref.read(appsProvider).value ?? const <AppInfo>[];
  final running = groupRunning(
    apps: apps,
    windows: ref.read(windowsProvider).value ?? const [],
    sessions: ref.read(appSessionsProvider).value ?? const [],
    agents: ref.read(monitorProvider).snapshot?.apps ?? const [],
  );
  return running.forApp(app) ??
      AppEntry(key: app.appId, name: app.name, app: app, icon: app.icon);
}

Future<void> _openPinned(
  BuildContext context,
  WidgetRef ref,
  AppInfo app,
  String host,
) async {
  // Refresh before resolving: an app may have opened while its dock was idle.
  await Future.wait([
    ref.read(windowsProvider.notifier).refresh(),
    ref.read(appSessionsProvider.notifier).refresh(),
  ]);
  if (!context.mounted || !_stillConnected(ref, host)) return;
  await openEntry(
    context,
    ref,
    _entry(ref, app),
    ref.read(appsProvider).value ?? const [],
  );
}

Future<void> _showSheet(
  BuildContext context,
  String host, {
  required bool pin,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: .85,
    child: _AppsSheet(host: host, pin: pin),
  ),
);

class _AppsSheet extends ConsumerStatefulWidget {
  const _AppsSheet({required this.host, required this.pin});
  final String host;
  final bool pin;
  @override
  ConsumerState<_AppsSheet> createState() => _AppsSheetState();
}

class _AppsSheetState extends ConsumerState<_AppsSheet> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    if (connection.hostUrl != widget.host ||
        connection.status != RpcStatus.connected) {
      return const SafeArea(
        child: Center(child: Text('Connect to this PC to see its apps.')),
      );
    }
    final appsAsync = ref.watch(appsProvider);
    final apps = appsAsync.value ?? const <AppInfo>[];
    final windows = ref.watch(windowsProvider).value ?? const <WindowInfo>[];
    final sessions =
        ref.watch(appSessionsProvider).value ?? const <AppSessionInfo>[];
    final snapshot = ref.watch(monitorProvider).snapshot;
    final running = groupRunning(
      apps: apps,
      windows: windows,
      sessions: sessions,
      agents: snapshot?.apps ?? const [],
    );
    final prefs = ref.watch(launcherPreferencesProvider(widget.host)).value;
    final all = widget.pin
        ? drawerApps(
            apps: apps,
            running: running,
            launchers: snapshot?.launchers ?? const [],
          ).where((e) => e.app != null).toList()
        : [
            ...running.apps,
            for (final agent in running.terminals)
              AppEntry(
                key: 'terminal:${agent.id}',
                name: agent.name,
                agent: agent,
              ),
            ...running.unidentified,
          ];
    final entries = all
        .where((e) => e.name.toLowerCase().contains(_search.toLowerCase()))
        .toList();
    Widget body() => Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.pin ? 'Favourite apps' : 'Running',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search apps',
            ),
            onChanged: (s) => setState(() => _search = s),
          ),
        ),
        Expanded(
          child: appsAsync.isLoading && apps.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        appsAsync.hasError
                            ? 'Could not load apps.'
                            : _search.isNotEmpty
                            ? 'No matching apps.'
                            : widget.pin
                            ? 'No apps available on this PC.'
                            : 'Nothing is open on the PC.',
                      ),
                      TextButton.icon(
                        onPressed: () => Future.wait([
                          ref.read(appsProvider.notifier).refresh(),
                          ref.read(windowsProvider.notifier).refresh(),
                          ref.read(appSessionsProvider.notifier).refresh(),
                        ]),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                )
              : ValueListenableBuilder<Map<String, String>>(
                  valueListenable: appProgress,
                  builder: (context, progress, _) => RefreshIndicator(
                    onRefresh: () => Future.wait([
                      ref.read(appsProvider.notifier).refresh(),
                      ref.read(windowsProvider.notifier).refresh(),
                      ref.read(appSessionsProvider.notifier).refresh(),
                    ]),
                    child: ListView.builder(
                      key: ValueKey(
                        widget.pin ? 'home-pin-picker' : 'home-running-list',
                      ),
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final e = entries[i];
                        final busy = progress[e.agent?.id];
                        return ListTile(
                          minTileHeight: 56,
                          leading: AppIconTile(
                            icon: e.icon,
                            name: e.name,
                            size: 36,
                          ),
                          title: Text(e.name),
                          subtitle: widget.pin
                              ? null
                              : Text(
                                  busy ??
                                      (e.stuck
                                          ? 'Not responding'
                                          : e.detail ??
                                                (e.agent?.isDesktop == false
                                                    ? 'In terminal'
                                                    : 'Running')),
                                ),
                          trailing: widget.pin
                              ? Checkbox(
                                  value:
                                      e.app != null &&
                                      (prefs?.isFavourite(e.app!) ?? false),
                                  onChanged: prefs == null
                                      ? null
                                      : (_) => _toggle(prefs, e.app!),
                                )
                              : IconButton(
                                  tooltip: 'Actions for ${e.name}',
                                  onPressed: () {
                                    if (_stillConnected(ref, widget.host)) {
                                      showAppMenu(context, ref, e);
                                    }
                                  },
                                  icon: const Icon(Icons.more_vert),
                                ),
                          onTap: widget.pin
                              ? prefs == null
                                    ? null
                                    : () => _toggle(prefs, e.app!)
                              : busy != null
                              ? null
                              : () {
                                  if (!_stillConnected(ref, widget.host)) {
                                    return;
                                  }
                                  if (e.agent?.isDesktop == false) {
                                    showAppMenu(context, ref, e);
                                  } else {
                                    openEntry(context, ref, e, apps);
                                  }
                                },
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
    return MonitorDemand(
      owner: 'home-app-sheet',
      intervalMs: 2000,
      active: !widget.pin && hostSupportsMonitor(connection.client),
      child: SafeArea(
        top: false,
        child: prefs == null
            ? body()
            : ListenableBuilder(listenable: prefs, builder: (_, _) => body()),
      ),
    );
  }

  Future<void> _toggle(LauncherPreferences prefs, AppInfo app) async {
    try {
      await prefs.toggleFavourite(app);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save pinned apps. Try again.'),
          ),
        );
      }
    }
  }
}
