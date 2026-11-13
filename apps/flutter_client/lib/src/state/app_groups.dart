// One entry per app, whatever is open: launcher apps, their desktop windows,
// the phone's virtual app sessions, and the agent apps the monitor reports.
// Desktop's resume list, Apps, Running and the tap behaviour all read this,
// so an app behaves the same wherever it is tapped.

import '../monitor/monitor_models.dart';
import '../rpc/models.dart';

/// Something open that a tap can resume.
sealed class OpenItem {
  const OpenItem();
  String get title;
}

class WindowItem extends OpenItem {
  const WindowItem(this.window, this.appName);
  final WindowInfo window;
  final String appName;
  @override
  String get title => window.title.trim().isEmpty ? appName : window.title;
}

class SessionItem extends OpenItem {
  const SessionItem(this.session);
  final AppSessionInfo session;
  @override
  String get title => session.name;
}

class AppEntry {
  AppEntry({
    required this.key,
    required this.name,
    this.app,
    this.icon,
    List<WindowInfo>? windows,
    List<AppSessionInfo>? sessions,
    this.agent,
    this.agentLauncher,
    this.identified = true,
  }) : windows = windows ?? [],
       sessions = sessions ?? [];

  /// Stable id: the launcher app id, `agent:<id>`, `id:<appId>` or
  /// `window:<windowId>`.
  final String key;
  final String name;
  final AppInfo? app;
  final String? icon;
  final List<WindowInfo> windows;
  final List<AppSessionInfo> sessions;

  /// The desktop agent app the monitor reports for this entry (state, usage,
  /// restart/quit/kill).
  AgentApp? agent;

  /// An agent app that isn't in the launcher list but the monitor can start.
  final String? agentLauncher;

  /// False for a window no app could be found for; it is listed by title.
  final bool identified;

  bool get running =>
      windows.isNotEmpty || sessions.isNotEmpty || agent != null;
  int get openCount => windows.length + sessions.length;
  bool get stuck => agent?.state == 'stuck';
  bool get launchable => app != null || agentLauncher != null;

  /// Phone sessions first: they are already sized for the phone.
  List<OpenItem> get items => [
    for (final s in sessions) SessionItem(s),
    for (final w in windows) WindowItem(w, name),
  ];

  /// "Inbox — Mail", "2 windows", "On your phone", "2 windows · 1 on phone".
  String? get detail {
    if (openCount == 0) return null;
    if (openCount == 1) {
      if (sessions.isNotEmpty) return 'On your phone';
      final t = windows.first.title.trim();
      return t.isEmpty || t == name ? null : t;
    }
    final w = windows.length, s = sessions.length;
    if (s == 0) return '$w windows';
    if (w == 0) return '$s on your phone';
    return '$w window${w == 1 ? '' : 's'} · $s on your phone';
  }
}

class RunningApps {
  const RunningApps({
    this.apps = const [],
    this.unidentified = const [],
    this.terminals = const [],
  });

  /// Apps with something open, in the order their first window/session came.
  final List<AppEntry> apps;

  /// Windows no app was found for, one entry each, named by title.
  final List<AppEntry> unidentified;

  /// Agents running in terminals (no window of their own).
  final List<AgentApp> terminals;

  int get count => apps.length + unidentified.length + terminals.length;
  bool get isEmpty => count == 0;

  /// The running entry for a launcher app, if any.
  AppEntry? forApp(AppInfo app) =>
      apps.where((e) => e.app?.appId == app.appId).firstOrNull;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// The launcher app an agent app is, by id or by name.
AppInfo? appForAgent(String appId, String name, List<AppInfo> apps) =>
    apps.where((a) => a.appId == appId).firstOrNull ??
    apps.where((a) => _norm(a.name) == _norm(name)).firstOrNull;

AppInfo? _appForWindow(WindowInfo w, List<AppInfo> apps) {
  if (w.appId != null) {
    final exact = apps.where((a) => a.appId == w.appId).firstOrNull;
    if (exact != null) return exact;
  }
  return apps.where((a) => windowMatchesApp(w, a)).firstOrNull;
}

/// Groups everything open on the PC into one entry per app.
RunningApps groupRunning({
  required List<AppInfo> apps,
  required List<WindowInfo> windows,
  required List<AppSessionInfo> sessions,
  List<AgentApp> agents = const [],
}) {
  final byKey = <String, AppEntry>{};
  final unidentified = <AppEntry>[];
  final desktopAgents = agents.where((a) => a.isDesktop).toList();

  AppEntry entryFor(AppInfo app) => byKey.putIfAbsent(
    app.appId,
    () => AppEntry(key: app.appId, name: app.name, app: app, icon: app.icon),
  );

  for (final s in sessions) {
    if (s.status == 'exited') continue;
    final app = apps.where((a) => a.appId == s.appId).firstOrNull;
    final entry = app != null
        ? entryFor(app)
        : byKey.putIfAbsent(
            'id:${s.appId}',
            () => AppEntry(key: 'id:${s.appId}', name: s.name, icon: s.icon),
          );
    entry.sessions.add(s);
  }

  for (final w in windows) {
    final app = _appForWindow(w, apps);
    if (app != null) {
      entryFor(app).windows.add(w);
      continue;
    }
    final agent = desktopAgents
        .where((a) => a.windows.any((x) => x['id'] == w.windowId))
        .firstOrNull;
    if (agent != null) {
      byKey
          .putIfAbsent(
            'agent:${agent.id}',
            () => AppEntry(
              key: 'agent:${agent.id}',
              name: agent.name,
              icon: w.icon,
            ),
          )
          .windows
          .add(w);
      continue;
    }
    if (w.appId != null && w.appId!.isNotEmpty) {
      final key = 'id:${w.appId}';
      byKey
          .putIfAbsent(
            key,
            () =>
                AppEntry(key: key, name: bestWindowName(w, apps), icon: w.icon),
          )
          .windows
          .add(w);
      continue;
    }
    unidentified.add(
      AppEntry(
        key: 'window:${w.windowId}',
        name: w.title.trim().isEmpty ? bestWindowName(w, apps) : w.title,
        icon: w.icon,
        windows: [w],
        identified: false,
      ),
    );
  }

  // Attach each desktop agent to its entry (by its windows, then its app),
  // or give it an entry of its own so a frozen app is never hidden.
  for (final agent in desktopAgents) {
    final ids = {for (final x in agent.windows) x['id']};
    var entry = byKey.values
        .where((e) => e.windows.any((w) => ids.contains(w.windowId)))
        .firstOrNull;
    if (entry == null) {
      final app = appForAgent(agent.appId, agent.name, apps);
      entry = app != null
          ? byKey[app.appId] ?? entryFor(app)
          : byKey.putIfAbsent(
              'agent:${agent.id}',
              () => AppEntry(key: 'agent:${agent.id}', name: agent.name),
            );
    }
    entry.agent = agent;
  }

  return RunningApps(
    apps: byKey.values.toList(),
    unidentified: unidentified,
    terminals: agents.where((a) => !a.isDesktop).toList(),
  );
}

/// Every app the drawer offers, by name: launcher apps (with whatever they
/// have open) plus agent apps the monitor can start that aren't in the
/// launcher list.
List<AppEntry> drawerApps({
  required List<AppInfo> apps,
  required RunningApps running,
  List<AgentLauncher> launchers = const [],
}) {
  final out = <AppEntry>[
    for (final a in apps)
      running.forApp(a) ??
          AppEntry(key: a.appId, name: a.name, app: a, icon: a.icon),
  ];
  for (final l in launchers) {
    if (appForAgent(l.appId, l.name, apps) != null) continue;
    final open = running.apps
        .where((e) => e.agent?.appId == l.appId)
        .firstOrNull;
    if (open != null) {
      out.add(open);
      continue;
    }
    out.add(
      AppEntry(key: 'agent:${l.appId}', name: l.name, agentLauncher: l.appId),
    );
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// What a tap on an app does.
sealed class OpenAction {
  const OpenAction();
}

/// Nothing open: start it.
class LaunchApp extends OpenAction {
  const LaunchApp();
}

/// One thing open: go straight to it.
class ResumeItem extends OpenAction {
  const ResumeItem(this.item);
  final OpenItem item;
}

/// Several open: let the user pick by title.
class ChooseItem extends OpenAction {
  const ChooseItem(this.items);
  final List<OpenItem> items;
}

/// Running but nothing to show (an agent app without a visible window):
/// open its app info.
class ShowInfo extends OpenAction {
  const ShowInfo();
}

OpenAction openActionFor(AppEntry entry) {
  final items = entry.items;
  if (items.length == 1) return ResumeItem(items.single);
  if (items.length > 1) return ChooseItem(items);
  if (entry.launchable && entry.agent == null) return const LaunchApp();
  if (entry.agent != null) return const ShowInfo();
  return const LaunchApp();
}
