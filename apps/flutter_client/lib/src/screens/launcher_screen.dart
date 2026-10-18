// Mobile PC tab: running apps, saved favourites, and frequently opened apps.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../state/launcher_preferences.dart';
import '../widgets/app_icon.dart';
import 'agent_screen.dart';
import '../workspace/files_screen.dart';
import 'mirror_screen.dart';
import 'system_screen.dart';
import 'terminal_screen.dart';

class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});

  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  String _search = '';
  int _menu = 0;
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

  AppInfo? _appForWindow(WindowInfo window, List<AppInfo> apps) {
    for (final app in apps) {
      if (windowMatchesApp(window, app)) return app;
    }
    return null;
  }

  Future<void> _appMenu({
    required String name,
    AppInfo? app,
    List<WindowInfo> windows = const [],
    List<AppSessionInfo> sessions = const [],
  }) async {
    if (_busy) return;
    final running = windows.isNotEmpty || sessions.isNotEmpty;
    final favourite = _preferences?.favourites.contains(app?.appId) ?? false;
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
        await _preferences?.toggleFavourite(app!.appId);
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

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _header(context),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('1. Running apps'),
                      selected: _menu == 0,
                      onSelected: (_) => setState(() => _menu = 0),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text(
                        '2. Favourites / most used',
                        maxLines: 2,
                      ),
                      selected: _menu == 1,
                      onSelected: (_) => setState(() => _menu = 1),
                    ),
                  ),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Long-press an app for actions',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: const Color(0xFF2A6AFF),
                backgroundColor: const Color(0xFF161622),
                onRefresh: () async {
                  await Future.wait([
                    ref.read(appsProvider.notifier).refresh(),
                    ref.read(windowsProvider.notifier).refresh(),
                    ref.read(appSessionsProvider.notifier).refresh(),
                  ]);
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: [
                    if (_menu == 0) ...[
                      _sectionTitle('Running apps'),
                      if (windowsAsync.isLoading || sessionsAsync.isLoading)
                        const Center(child: CircularProgressIndicator()),
                      if (windowsAsync.hasError || sessionsAsync.hasError)
                        const Text(
                          'Could not load running apps. Pull down to retry.',
                        ),
                      if (windows.isEmpty && sessions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No running apps. Open Favourites / most used to launch an app.',
                          ),
                        ),
                      for (final session in sessions)
                        ListTile(
                          leading: AppIconTile(
                            icon: session.icon,
                            name: session.name,
                            size: 40,
                          ),
                          title: Text(session.name),
                          subtitle: const Text('Phone session'),
                          onTap: () {
                            _recordUse(session.appId);
                            _attachSession(session);
                          },
                          onLongPress: () => _appMenu(
                            name: session.name,
                            app: apps
                                .where((a) => a.appId == session.appId)
                                .firstOrNull,
                            sessions: [session],
                          ),
                        ),
                      for (final window in windows)
                        ListTile(
                          leading: AppIconTile(
                            icon: window.icon,
                            name: bestWindowName(window, apps),
                            size: 40,
                          ),
                          title: Text(bestWindowName(window, apps)),
                          subtitle: Text(
                            window.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            _recordUse(_appForWindow(window, apps)?.appId);
                            _openWindow(window, apps);
                          },
                          onLongPress: () => _appMenu(
                            name: bestWindowName(window, apps),
                            app: _appForWindow(window, apps),
                            windows: [window],
                          ),
                        ),
                    ] else ...[
                      _sectionTitle('Favourites'),
                      if (preferences == null)
                        const Text('Loading favourites…')
                      else if (!apps.any(
                        (a) => preferences.favourites.contains(a.appId),
                      ))
                        const Text(
                          'Long-press an app below to add a favourite.',
                        ),
                      _appGrid(
                        apps
                            .where(
                              (a) =>
                                  preferences?.favourites.contains(a.appId) ??
                                  false,
                            )
                            .toList(),
                        windows,
                        sessions,
                      ),
                      const SizedBox(height: 16),
                      _sectionTitle('Most used'),
                      if (preferences == null ||
                          preferences.mostUsed(apps).isEmpty)
                        const Text(
                          'Apps you open from this phone will appear here.',
                        ),
                      _appGrid(
                        preferences?.mostUsed(apps).take(8).toList() ?? [],
                        windows,
                        sessions,
                      ),
                      const SizedBox(height: 16),
                      _appsHeader(),
                      if (appsAsync.isLoading && filteredApps.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (filteredApps.isEmpty &&
                          appsAsync.hasError &&
                          q.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 32),
                          child: Center(
                            child: Column(
                              children: [
                                Text(
                                  'Could not load apps: ${friendlyLaunchError(appsAsync.error!)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white54,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      ref.read(appsProvider.notifier).refresh(),
                                  icon: const Icon(Icons.refresh, size: 16),
                                  label: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        _appGrid(filteredApps, windows, sessions),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            _dock(context),
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

  Widget _sectionTitle(String s, {bool isBeta = false}) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 4, 0, 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
        if (isBeta) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            decoration: BoxDecoration(
              color: const Color(0xFF2A6AFF).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: const Color(0xFF2A6AFF).withValues(alpha: 0.5),
                width: 0.8,
              ),
            ),
            child: const Text(
              'BETA',
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: Color(0xFF7AA2FF),
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _appsHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _sectionTitle('All apps'),
          const Spacer(),
          SizedBox(
            width: 180,
            height: 38,
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search apps…',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
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

  Widget _dock(BuildContext context) {
    void push(Widget screen) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    final items = <(IconData, String, VoidCallback?, bool)>[
      (Icons.terminal, 'Terminal', () => push(const TerminalScreen()), false),
      (Icons.folder, 'Files', () => push(const WorkspaceFilesScreen()), false),
      (Icons.memory, 'System', () => push(const SystemScreen()), false),
      (Icons.desktop_windows, 'Desktop', () => _openDesktop(context), true),
      (Icons.auto_awesome, 'Agents', () => push(const AgentScreen()), false),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF12121C),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF1E1E30)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: items
            .map(
              (it) => InkWell(
                onTap: it.$3,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(
                            it.$1,
                            size: 20,
                            color: it.$3 == null
                                ? Colors.white.withValues(alpha: 0.25)
                                : Colors.white.withValues(alpha: 0.75),
                          ),
                          if (it.$4)
                            Positioned(
                              top: -4,
                              right: -12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2A6AFF),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: const Text(
                                  'BETA',
                                  style: TextStyle(
                                    fontSize: 6.5,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        it.$4 ? '${it.$2} (Beta)' : it.$2,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  void _openDesktop(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const MirrorScreen(target: MirrorTarget()),
      ),
    );
  }
}
