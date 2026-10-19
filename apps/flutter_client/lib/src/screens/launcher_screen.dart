// Mobile PC tab: running apps, saved favourites, and frequently opened apps.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../state/launcher_preferences.dart';
import '../widgets/app_icon.dart';

import 'mirror_screen.dart';
import '../workspace/workspace_shell.dart';
import '../widgets/pc_charts.dart';

class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});

  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  String _search = '';
  bool _expanded = false;
  bool _busy = false;

  LauncherPreferences? get _preferences => ref
      .read(
        launcherPreferencesProvider(ref.read(connectionProvider).hostUrl ?? ''),
      )
      .value;

  void _showError(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyLaunchError(error))));
    }
  }

  Future<void> _recordUse(String? appId) async {
    if (appId == null) return;
    try {
      await _preferences?.recordUse(appId);
      if (mounted) setState(() {});
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _appMenu({
    required String name,
    AppInfo? app,
    List<WindowInfo> windows = const [],
    List<AppSessionInfo> sessions = const [],
  }) async {
    if (_busy) return;
    final running = windows.isNotEmpty || sessions.isNotEmpty;
    final favourite = app != null && (_preferences?.isFavourite(app) ?? false);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(name), subtitle: const Text('App actions')),
            if (app != null)
              ListTile(
                leading: Icon(favourite ? Icons.star : Icons.star_border),
                title: Text(
                  favourite ? 'Remove from favourites' : 'Add to favourites',
                ),
                enabled: _preferences != null,
                onTap: () => Navigator.pop(context, 'favourite'),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close app'),
              enabled: running,
              onTap: () => Navigator.pop(context, 'close'),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('Restart app'),
              subtitle: app == null
                  ? const Text('App is not in the installed app list')
                  : null,
              enabled: running && app != null,
              onTap: () => Navigator.pop(context, 'restart'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'favourite') {
      try {
        await _preferences?.toggleFavourite(app!);
        if (mounted) setState(() {});
      } catch (error) {
        _showError(error);
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final client = ref.read(activeClientProvider);
      if (client == null || client.status != RpcStatus.connected) {
        throw StateError('Connect to your PC to manage apps.');
      }
      if (windows.isNotEmpty && !client.supports('window.close')) {
        throw StateError(
          'Update and restart the PC host to close or restart desktop apps.',
        );
      }
      for (final session in sessions) {
        final result = await client.requestMap('appSession.close', {
          'sessionId': session.sessionId,
        });
        if (result['ok'] != true) throw StateError('Could not close $name.');
      }
      for (final window in windows) {
        final result = await client.requestMap('window.close', {
          'windowId': window.windowId,
        });
        if (result['ok'] != true) throw StateError('Could not close $name.');
      }
      // A normal close can be blocked by an application's save dialog.
      if (windows.isNotEmpty) {
        final ids = windows.map((w) => w.windowId).toSet();
        var closed = false;
        for (var attempt = 0; attempt < 20; attempt++) {
          final current = await client.requestList('window.list');
          if (!current.any((w) => ids.contains((w as Map)['windowId']))) {
            closed = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (!closed) {
          throw StateError(
            '$name is still open. Check the PC for an unsaved-work dialog, then try again.',
          );
        }
      }
      await Future.wait([
        ref.read(windowsProvider.notifier).refresh(),
        ref.read(appSessionsProvider.notifier).refresh(),
      ]);
      if (!mounted) return;
      if (action == 'restart') {
        _recordUse(app!.appId);
        _launchApp(app, const [], const [], [app]);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$name closed')));
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static final _browserRe = RegExp(
    r'brave|chrom(e|ium)|msedge|microsoft.edge|nexus\.chrome',
    caseSensitive: false,
  );

  bool _isBrowserApp(AppInfo a) =>
      _browserRe.hasMatch(a.appId) || _browserRe.hasMatch(a.wmClass ?? '');

  bool _isBrowserAppId(String appId) => _browserRe.hasMatch(appId);

  bool _isBrowserWindow(WindowInfo w, List<AppInfo> apps) {
    if (w.appId != null && _browserRe.hasMatch(w.appId!)) return true;
    if (_browserRe.hasMatch(w.wmClass)) return true;
    for (final a in apps) {
      if (windowMatchesApp(w, a) && _isBrowserApp(a)) return true;
    }
    return false;
  }

  void _openWindow(WindowInfo w, List<AppInfo> apps) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MirrorScreen(
          target: MirrorTarget(
            windowId: w.windowId,
            title: bestWindowName(w, apps),
            isBrowser: _isBrowserWindow(w, apps),
          ),
        ),
      ),
    );
  }

  void _attachSession(AppSessionInfo s) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MirrorScreen(
          target: MirrorTarget(
            sessionId: s.sessionId,
            title: s.name,
            isBrowser: _isBrowserAppId(s.appId),
          ),
        ),
      ),
    );
  }

  void _launchApp(
    AppInfo a,
    List<AppSessionInfo> sessions,
    List<WindowInfo> windows,
    List<AppInfo> apps,
  ) {
    // 1. Already running in a virtual session → re-attach (like switching apps).
    for (final s in sessions) {
      if (s.appId == a.appId) {
        _attachSession(s);
        return;
      }
    }
    // 2. Already running as a desktop window → open and focus that window.
    for (final w in windows) {
      if (windowMatchesApp(w, a)) {
        _openWindow(w, apps);
        return;
      }
    }
    // 3. Launch the app. Virtual profile apps go to a virtual session;
    // system desktop apps launch on the real desktop and are adopted into portrait.
    if (a.appId.startsWith('nexus.')) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MirrorScreen(
            target: MirrorTarget(
              sessionAppId: a.appId,
              title: a.name,
              isBrowser: _isBrowserApp(a),
            ),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MirrorScreen(
            target: MirrorTarget(
              appId: a.appId,
              wmClass: a.wmClass,
              title: a.name,
              isBrowser: _isBrowserApp(a),
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final windowsAsync = ref.watch(windowsProvider);
    final appsAsync = ref.watch(appsProvider);
    final sessionsAsync = ref.watch(appSessionsProvider);
    final windows = windowsAsync.value ?? [];
    final apps = appsAsync.value ?? [];
    final sessions = sessionsAsync.value ?? [];
    final preferences = ref
        .watch(
          launcherPreferencesProvider(
            ref.watch(connectionProvider).hostUrl ?? '',
          ),
        )
        .value;
    final q = _search.trim().toLowerCase();
    final filteredApps = q.isEmpty
        ? apps
        : apps.where((a) => a.name.toLowerCase().contains(q)).toList();

    final recent =
        preferences?.recentlyUsed(apps).take(4).toList() ?? <AppInfo>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your PC'),
        actions: [
          IconButton(
            tooltip: 'PC settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const PcScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            ref.read(appsProvider.notifier).refresh(),
            ref.read(windowsProvider.notifier).refresh(),
            ref.read(appSessionsProvider.notifier).refresh(),
          ]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _header(context),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Apps'),
                      subtitle: Text(
                        _expanded ? 'Favourites' : 'Recently opened',
                      ),
                      trailing: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                      onTap: () => setState(() {
                        _expanded = !_expanded;
                        _search = '';
                      }),
                    ),
                    if (_busy) const LinearProgressIndicator(),
                    if (preferences == null) const Text('Loading app menu…'),
                    if (!_expanded) ...[
                      if (recent.isEmpty)
                        const Text(
                          'Apps you open will appear here. Expand to choose a favourite.',
                        ),
                      _appGrid(recent, windows, sessions),
                    ] else ...[
                      _appGrid(
                        apps
                            .where((a) => preferences?.isFavourite(a) ?? false)
                            .toList(),
                        windows,
                        sessions,
                      ),
                      for (final name in LauncherPreferences.defaultFavourites)
                        if (!apps.any(
                          (a) => LauncherPreferences.defaultName(a) == name,
                        ))
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.star_outline),
                            title: Text(name),
                            subtitle: const Text('Not available on this PC'),
                          ),
                      const SizedBox(height: 12),
                      TextField(
                        onChanged: (value) => setState(() => _search = value),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search apps to add…',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (q.isNotEmpty && filteredApps.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No matching apps on this PC.'),
                        ),
                      if (q.isNotEmpty)
                        for (final app in filteredApps)
                          ListTile(
                            leading: AppIconTile(
                              icon: app.icon,
                              name: app.name,
                              size: 36,
                            ),
                            title: Text(app.name),
                            onTap: () {
                              if (!_busy) {
                                _recordUse(app.appId);
                                _launchApp(app, sessions, windows, apps);
                              }
                            },
                            trailing: IconButton(
                              tooltip: preferences?.isFavourite(app) == true
                                  ? 'Remove from favourites'
                                  : 'Add to favourites',
                              icon: Icon(
                                preferences?.isFavourite(app) == true
                                    ? Icons.star
                                    : Icons.star_border,
                              ),
                              onPressed: preferences == null
                                  ? null
                                  : () async {
                                      try {
                                        await preferences.toggleFavourite(app);
                                        if (mounted) setState(() {});
                                      } catch (error) {
                                        _showError(error);
                                      }
                                    },
                            ),
                          ),
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('Long-press an app for actions'),
                      ),
                    ],
                    if (appsAsync.isLoading) const LinearProgressIndicator(),
                    if (appsAsync.hasError)
                      const Text('Could not load apps. Pull down to retry.'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const PcCharts(),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final host = ref.watch(connectionProvider).hostUrl ?? '';
    final status = ref.watch(connectionStatusProvider);
    final label = Uri.tryParse(host)?.host ?? 'PC';
    final statusColor = switch (status) {
      RpcStatus.connected => const Color(0xFF4ADE80),
      RpcStatus.connecting => const Color(0xFFF0C040),
      RpcStatus.disconnected => const Color(0xFFEE5555),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new, size: 18),
            onPressed: () {
              ref.read(connectionProvider.notifier).disconnect();
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
    );
  }

  Widget _appGrid(
    List<AppInfo> apps,
    List<WindowInfo> windows,
    List<AppSessionInfo> sessions,
  ) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 88,
        mainAxisSpacing: 14,
        crossAxisSpacing: 8,
        childAspectRatio: 0.78,
      ),
      itemCount: apps.length,
      itemBuilder: (_, i) {
        final a = apps[i];
        final running =
            sessions.any((s) => s.appId == a.appId) ||
            windows.any((w) => windowMatchesApp(w, a));
        return InkWell(
          onTap: () {
            if (_busy) return;
            _recordUse(a.appId);
            _launchApp(a, sessions, windows, apps);
          },
          onLongPress: () => _appMenu(
            name: a.name,
            app: a,
            windows: windows.where((w) => windowMatchesApp(w, a)).toList(),
            sessions: sessions.where((s) => s.appId == a.appId).toList(),
          ),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AppIconTile(icon: a.icon, name: a.name),
                  if (running)
                    const Positioned(
                      bottom: -3,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Icon(
                          Icons.circle,
                          size: 5,
                          color: Color(0xFF4ADE80),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
