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

/// Pinned PC apps and running work, scoped to the selected, connected PC.
class HomeDock extends ConsumerWidget {
  const HomeDock({super.key, required this.target, required this.visible});
  final SavedTarget target;
  final bool visible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!visible) return const SizedBox.shrink();
    final connection = ref.watch(connectionProvider);
    final host = nexusLinkUrlOf(target);
    if (host == null ||
        connection.hostUrl != host ||
        connection.status != RpcStatus.connected ||
        connection.client == null) {
      return const SizedBox.shrink();
    }
    final client = connection.client!;
    final capabilities = client.capabilities['capabilities'];
    if (client.capabilities.isNotEmpty &&
        !client.supports('apps.list') &&
        !(capabilities is List && capabilities.contains('apps'))) {
      return const SizedBox.shrink();
    }
    return _DockContent(
      key: ValueKey(host),
      host: host,
      actionContext: context,
      actionRef: ref,
    );
  }
}

class _DockContent extends ConsumerWidget {
  const _DockContent({
    super.key,
    required this.host,
    required this.actionContext,
    required this.actionRef,
  });
  final String host;
  // HomeDock stays mounted when a route covers Home and releases this data consumer.
  final BuildContext actionContext;
  final WidgetRef actionRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(appsProvider).value ?? const <AppInfo>[];
    ref.watch(windowsProvider);
    ref.watch(appSessionsProvider);
    final prefs = ref.watch(launcherPreferencesProvider(host)).value;
    if (prefs == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final pinned = apps.where(prefs.isFavourite).toList();
        final height = 62 + MediaQuery.textScalerOf(context).scale(12) * 2;
        Widget action(String label, IconData icon, String key, bool pin) =>
            SizedBox(
              width: 64,
              child: InkWell(
                key: ValueKey(key),
                borderRadius: BorderRadius.circular(12),
                onTap: () => _showSheet(actionContext, host, pin: pin),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 24),
                        const SizedBox(height: 5),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            action('Pin', Icons.push_pin_outlined, 'home-pin-apps', true),
            action('Running', Icons.layers_outlined, 'home-running', false),
          ],
        );
        final pins = pinned.isEmpty
            ? const Center(
                child: Text(
                  'Pin your PC apps',
                  style: TextStyle(color: NX.textDim, fontSize: 12),
                ),
              )
            : ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: pinned.length,
                separatorBuilder: (_, _) => const SizedBox(width: 4),
                itemBuilder: (context, i) {
                  final app = pinned[i];
                  return SizedBox(
                    width: 72,
                    child: InkWell(
                      key: ValueKey('dock-app-${app.appId}'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: () =>
                          _openPinned(actionContext, actionRef, app, host),
                      onLongPress: () =>
                          _showPinnedMenu(actionContext, actionRef, app, host),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AppIconTile(icon: app.icon, name: app.name, size: 44),
                          const SizedBox(height: 5),
                          Text(
                            app.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final largeText =
                      MediaQuery.textScalerOf(context).scale(12) > 18;
                  if (constraints.maxWidth < 280 || largeText) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (pinned.isNotEmpty)
                          SizedBox(height: height, child: pins),
                        actions,
                      ],
                    );
                  }
                  return SizedBox(
                    height: height,
                    child: Row(
                      children: [
                        Expanded(child: pins),
                        const VerticalDivider(
                          width: 12,
                          indent: 16,
                          endIndent: 16,
                        ),
                        actions,
                      ],
                    ),
                  );
                },
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

void _showPinnedMenu(
  BuildContext context,
  WidgetRef ref,
  AppInfo app,
  String host,
) {
  if (_stillConnected(ref, host)) showAppMenu(context, ref, _entry(ref, app));
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
                  widget.pin ? 'Pin apps' : 'Running',
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
