// What tapping an app does, and the per-app actions (favourite, info,
// restart, quit, force stop), shared by Desktop, Apps, Running and App info so
// an app behaves the same everywhere.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../screens/mirror_screen.dart';
import '../state/app_groups.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../state/launcher_preferences.dart';
import '../theme/nexus_theme.dart';
import '../widgets/app_icon.dart';
import 'app_info.dart';
import 'pc_actions.dart';
import 'pc_ui.dart';

final _browserRe = RegExp(
  r'brave|chrom(e|ium)|msedge|microsoft.edge|nexus\.chrome|firefox',
  caseSensitive: false,
);

bool _isBrowser(String? s) => s != null && _browserRe.hasMatch(s);

LauncherPreferences? launcherPrefs(WidgetRef ref) => ref
    .read(
      launcherPreferencesProvider(ref.read(connectionProvider).hostUrl ?? ''),
    )
    .value;

/// Tests replace the full-screen viewer with a stand-in.
@visibleForTesting
Widget Function(MirrorTarget target)? debugViewerBuilder;

/// The viewer opens above the tab bar; Back returns to the same destination,
/// search and scroll position (the launcher stays mounted underneath).
Future<T?> _pushViewer<T>(BuildContext context, MirrorTarget target) =>
    Navigator.of(context, rootNavigator: true).push<T>(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'viewer'),
        builder: (_) =>
            debugViewerBuilder?.call(target) ?? MirrorScreen(target: target),
      ),
    );

void openWindow(BuildContext context, WindowInfo w, List<AppInfo> apps) {
  final app = apps.where((a) => windowMatchesApp(w, a)).firstOrNull;
  _pushViewer<void>(
    context,
    MirrorTarget(
      windowId: w.windowId,
      title: bestWindowName(w, apps),
      isBrowser:
          _isBrowser(w.appId) ||
          _isBrowser(w.wmClass) ||
          _isBrowser(app?.appId) ||
          _isBrowser(app?.wmClass),
    ),
  );
}

void attachSession(BuildContext context, AppSessionInfo s) => _pushViewer<void>(
  context,
  MirrorTarget(
    sessionId: s.sessionId,
    title: s.name,
    isBrowser: _isBrowser(s.appId),
  ),
);

void openDesktop(BuildContext context, {required bool viewOnly}) =>
    _pushViewer<void>(context, MirrorTarget.desktop(viewOnly: viewOnly));

/// Starts [app]: virtual-profile apps in a phone-shaped session, desktop apps
/// on the PC's desktop (adopted into portrait by the viewer).
void launchApp(BuildContext context, AppInfo app) => _pushViewer<void>(
  context,
  app.appId.startsWith('nexus.')
      ? MirrorTarget(
          sessionAppId: app.appId,
          title: app.name,
          isBrowser: _isBrowser(app.appId) || _isBrowser(app.wmClass),
        )
      : MirrorTarget(
          appId: app.appId,
          wmClass: app.wmClass,
          title: app.name,
          isBrowser: _isBrowser(app.appId) || _isBrowser(app.wmClass),
        ),
);

void resumeItem(BuildContext context, OpenItem item, List<AppInfo> apps) =>
    switch (item) {
      WindowItem(:final window) => openWindow(context, window, apps),
      SessionItem(:final session) => attachSession(context, session),
    };

/// The one tap behaviour: closed → launch; one window → resume it; several
/// → choose by title; an agent app with nothing to show → its info.
bool _samePc(WidgetRef ref, RpcClient? client) =>
    identical(ref.read(activeClientProvider), client) &&
    (client == null || ref.read(connectionStatusProvider) == RpcStatus.connected);

Future<void> openEntry(
  BuildContext context,
  WidgetRef ref,
  AppEntry entry,
  List<AppInfo> apps,
) async {
  final client = ref.read(activeClientProvider);
  final app = entry.app;
  if (app != null) unawaitedRecord(ref, app.appId);
  switch (openActionFor(entry)) {
    case ResumeItem(:final item):
      resumeItem(context, item, apps);
    case ChooseItem(:final items):
      final picked = await chooseOpenItem(context, entry, items);
      if (picked != null && context.mounted && _samePc(ref, client)) {
        resumeItem(context, picked, apps);
      }
    case ShowInfo():
      await openAppInfo(context, entry.key);
    case LaunchApp():
      if (app != null) {
        launchApp(context, app);
      } else if (entry.agentLauncher != null) {
        await startAgentApp(context, ref, entry.agentLauncher!, entry.name);
      }
  }
}

void unawaitedRecord(WidgetRef ref, String appId) {
  launcherPrefs(ref)?.recordUse(appId).catchError((_) {});
}

/// Bottom sheet listing an app's windows and phone sessions by title.
Future<OpenItem?> chooseOpenItem(
  BuildContext context,
  AppEntry entry,
  List<OpenItem> items,
) => showModalBottomSheet<OpenItem>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheet).height * .7,
      ),
      child: ListView(
        key: const ValueKey('choose-window'),
        shrinkWrap: true,
        children: [
          ListTile(
            leading: AppIconTile(icon: entry.icon, name: entry.name, size: 32),
            title: Text(
              entry.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Choose a window'),
          ),
          const Divider(height: 1, color: NX.line),
          for (final item in items)
            ListTile(
              minTileHeight: 52,
              leading: Icon(
                item is SessionItem
                    ? Icons.smartphone_rounded
                    : Icons.web_asset_rounded,
                color: NX.textDim,
              ),
              title: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: item is SessionItem
                  ? const Text('On your phone')
                  : null,
              onTap: () => Navigator.pop(sheet, item),
            ),
        ],
      ),
    ),
  ),
);

Future<void> startAgentApp(
  BuildContext context,
  WidgetRef ref,
  String appId,
  String name,
) async {
  showPcMessage(context, 'Starting $name…');
  String message;
  try {
    message = await ref.read(monitorProvider.notifier).launch(appId);
  } catch (error) {
    message = pcActionError(error);
  }
  if (context.mounted) showPcMessage(context, message);
}

// ---------------------------------------------------------------------------
// Restart / quit / force stop

enum AppCommand { restart, quit, kill }

/// Which commands this entry supports right now.
Set<AppCommand> commandsFor(AppEntry entry) {
  final agent = entry.agent;
  if (agent != null) {
    return {
      if (agent.can('restart')) AppCommand.restart,
      if (agent.can('quit')) AppCommand.quit,
      if (agent.can('kill')) AppCommand.kill,
    };
  }
  if (entry.openCount == 0) return const {};
  return {if (entry.app != null) AppCommand.restart, AppCommand.quit};
}

({
  String title,
  String body,
  String confirm,
  String progress,
  IconData icon,
  bool destructive,
})
_agentSpec(AgentApp app, AppCommand c) {
  final name = app.name;
  return switch (c) {
    AppCommand.restart => (
      title: 'Restart $name?',
      body:
          'NexusLink closes $name gracefully. If it’s frozen and still open after 6 seconds, it’s force-stopped. Then it opens again.\n\nUnsaved work in $name may be lost.',
      confirm: 'Restart',
      progress: 'Restarting $name…',
      icon: Icons.restart_alt_rounded,
      destructive: false,
    ),
    AppCommand.quit => (
      title: 'Quit $name?',
      body:
          'Closes its windows as if you clicked ×. If it’s still running after 6 seconds, it’s stopped.',
      confirm: 'Quit',
      progress: 'Quitting $name…',
      icon: Icons.logout_rounded,
      destructive: false,
    ),
    AppCommand.kill when app.isDesktop => (
      title: 'Force stop $name?',
      body:
          'Ends all ${app.processCount} of its processes immediately, without letting it save. Use this when Quit doesn’t work.',
      confirm: 'Force stop',
      progress: 'Force-stopping $name…',
      icon: Icons.dangerous_outlined,
      destructive: true,
    ),
    AppCommand.kill => (
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
}

/// Shown while an agent app action runs (app id → progress text), so rows and
/// App info can show a spinner.
final appProgress = ValueNotifier<Map<String, String>>(const {});

void _setProgress(String key, String? text) {
  final next = {...appProgress.value};
  if (text == null) {
    next.remove(key);
  } else {
    next[key] = text;
  }
  appProgress.value = next;
}

/// Confirms, runs and reports an agent app action (restart, quit, kill).
Future<void> runAgentCommand(
  BuildContext context,
  WidgetRef ref,
  AgentApp app,
  AppCommand c,
) async {
  final client = ref.read(activeClientProvider);
  final spec = _agentSpec(app, c);
  final ok = await confirmPcAction(
    context,
    title: spec.title,
    body: spec.body,
    confirm: spec.confirm,
    icon: spec.icon,
    destructive: spec.destructive,
  );
  if (!ok || !context.mounted || !_samePc(ref, client)) return;
  if (appProgress.value.containsKey(app.id)) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  _setProgress(app.id, spec.progress);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(spec.progress)));
  String message;
  try {
    message = await ref
        .read(monitorProvider.notifier)
        .appAction(app, c == AppCommand.kill ? 'kill' : c.name);
  } catch (error) {
    message = pcActionError(error);
  }
  _setProgress(app.id, null);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Restart / quit / force stop for any entry: agent apps through the monitor,
/// other apps by closing their windows and sessions (then relaunching).
Future<void> runAppCommand(
  BuildContext context,
  WidgetRef ref,
  AppEntry entry,
  AppCommand c,
) async {
  final client = ref.read(activeClientProvider);
  final agent = entry.agent;
  if (agent != null) return runAgentCommand(context, ref, agent, c);
  if (c == AppCommand.restart) {
    final ok = await confirmPcAction(
      context,
      title: 'Restart ${entry.name}?',
      body:
          'Closes ${entry.name} on the PC (it may ask you to save there first), then opens it again here.',
      confirm: 'Restart',
      icon: Icons.restart_alt_rounded,
    );
    if (!ok || !context.mounted || !_samePc(ref, client)) return;
  }
  final closed = await closeApp(
    context,
    ref,
    name: entry.name,
    windows: entry.windows,
    sessions: entry.sessions,
  );
  if (!closed || !context.mounted || !_samePc(ref, client)) return;
  final app = entry.app;
  if (c == AppCommand.restart && app != null) {
    launchApp(context, app);
  } else {
    showPcMessage(context, '${entry.name} closed');
  }
}

/// Gracefully closes [windows] and [sessions]. A normal close can be held up
/// by an unsaved-work dialog on the PC; that is reported, not forced.
Future<bool> closeApp(
  BuildContext context,
  WidgetRef ref, {
  required String name,
  List<WindowInfo> windows = const [],
  List<AppSessionInfo> sessions = const [],
}) async {
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
    return true;
  } catch (error) {
    if (context.mounted) showPcMessage(context, friendlyLaunchError(error));
    return false;
  }
}

// ---------------------------------------------------------------------------
// The one app menu

String commandLabel(AppEntry entry, AppCommand c) => switch (c) {
  AppCommand.restart => 'Restart',
  AppCommand.quit => 'Quit',
  AppCommand.kill => entry.agent?.isDesktop == false ? 'Stop' : 'Force stop',
};

IconData commandIcon(AppCommand c) => switch (c) {
  AppCommand.restart => Icons.restart_alt_rounded,
  AppCommand.quit => Icons.logout_rounded,
  AppCommand.kill => Icons.dangerous_outlined,
};

/// Favourites, App info and the supported actions, in one sheet.
Future<void> showAppMenu(
  BuildContext context,
  WidgetRef ref,
  AppEntry entry, {
  VoidCallback? onChanged,
}) async {
  final client = ref.read(activeClientProvider);
  final prefs = launcherPrefs(ref);
  final app = entry.app;
  final favourite = app != null && (prefs?.isFavourite(app) ?? false);
  final commands = commandsFor(entry);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          key: const ValueKey('app-menu'),
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: AppIconTile(
                icon: entry.icon,
                name: entry.name,
                size: 36,
              ),
              title: Text(
                entry.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                appStateText(entry),
                style: TextStyle(color: entry.stuck ? NX.waiting : NX.textDim),
              ),
            ),
            const Divider(height: 1, color: NX.line),
            if (app != null && prefs != null)
              ListTile(
                leading: Icon(
                  favourite ? Icons.star_rounded : Icons.star_border_rounded,
                ),
                title: Text(
                  favourite ? 'Remove from favourites' : 'Add to favourites',
                ),
                onTap: () => Navigator.pop(sheet, 'favourite'),
              ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('App info'),
              onTap: () => Navigator.pop(sheet, 'info'),
            ),
            for (final c in AppCommand.values)
              if (commands.contains(c))
                ListTile(
                  leading: Icon(
                    commandIcon(c),
                    color: c == AppCommand.kill ? NX.waiting : null,
                  ),
                  title: Text(commandLabel(entry, c)),
                  onTap: () => Navigator.pop(sheet, c.name),
                ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted || !_samePc(ref, client)) return;
  switch (choice) {
    case 'favourite':
      try {
        await prefs?.toggleFavourite(app!);
      } catch (error) {
        if (context.mounted) showPcMessage(context, friendlyLaunchError(error));
      }
      onChanged?.call();
    case 'info':
      await openAppInfo(context, entry.key);
    default:
      await runAppCommand(
        context,
        ref,
        entry,
        AppCommand.values.byName(choice),
      );
  }
}

String appStateText(AppEntry entry) {
  if (entry.stuck) return 'Not responding';
  if (!entry.running) return entry.launchable ? 'Not running' : 'Closed';
  final n = entry.openCount;
  if (n == 0) return 'Running';
  if (n == 1) return entry.sessions.isNotEmpty ? 'On your phone' : 'Running';
  return 'Running · $n open';
}
