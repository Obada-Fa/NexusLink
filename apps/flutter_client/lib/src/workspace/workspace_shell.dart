import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chats/chat_library_screen.dart';
import '../services/notification_service.dart';
import '../screens/terminal_screen.dart';
import '../screens/launcher_screen.dart';
import '../state/connection.dart';
import '../rpc/rpc_client.dart';
import 'files_screen.dart';
import 'metrics.dart';
import '../monitor/monitor_provider.dart';
import '../pc/phone_approvals_section.dart';
import '../pc/remote_access_section.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'project.dart';
import 'platform_bridge.dart';
import 'documents.dart';

/// Global ids of the NexusLink workspace tabs. They stay stable so existing
/// screens can keep selecting a tab through [workspaceTabProvider]; each
/// module shows only its own tabs (agents: monitor; terminal: terminal +
/// files; desktop: PC).
abstract final class WorkspaceTabs {
  static const monitor = 0;
  static const files = 1;
  static const terminal = 2;
  static const pc = 3;
  static const all = [monitor, files, terminal, pc];
}

/// Hosts one module's NexusLink screens. Tabs are global [WorkspaceTabs] ids;
/// when a screen selects a tab this host does not show (e.g. Mission Control
/// opening PC vitals), [onForeignTab] lets the shell open the module that owns
/// it.
class WorkspaceShell extends ConsumerStatefulWidget {
  const WorkspaceShell({
    super.key,
    this.tabs = WorkspaceTabs.all,
    this.onForeignTab,
  });
  final List<int> tabs;
  final void Function(int tab)? onForeignTab;
  @override
  ConsumerState<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends ConsumerState<WorkspaceShell>
    with WidgetsBindingObserver {
  final _visited = <int>{};
  bool _foreground = true;
  RpcClient? _metricsClient;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!widget.tabs.contains(ref.read(workspaceTabProvider))) {
      // Providers can't change while the tree builds.
      Future.microtask(() {
        if (mounted) {
          ref.read(workspaceTabProvider.notifier).select(widget.tabs.first);
        }
      });
    }
    _loadSettings();
  }

  int get _tab {
    final tab = ref.read(workspaceTabProvider);
    return widget.tabs.contains(tab) ? tab : widget.tabs.first;
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    ref
        .read(workspaceSettingsProvider.notifier)
        .set('stats', prefs.getBool('workspace.stats') ?? false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _demand();
    if (!_foreground) ref.read(documentRepositoryProvider).flush();
  }

  void _demand() {
    final client = ref.read(activeClientProvider);
    if (!identical(client, _metricsClient)) {
      _metricsClient?.demand('shell', 0);
      _metricsClient?.demand('windows', 0);
      _metricsClient?.demand('monitor:strip', 0);
      _metricsClient = client;
    }
    final tab = _tab;
    final show = ref.read(workspaceSettingsProvider)['stats'] == true;
    client?.demand('windows', _foreground && tab == 3 ? 5000 : 0);
    if (hostSupportsMonitor(client)) {
      // Rich vitals for the strip; the PC tab drives its own faster demand.
      client?.demand('shell', 0);
      client?.demand('monitor:strip', _foreground && show && tab != 3 ? 5000 : 0);
    } else {
      client?.demand(
        'shell',
        _foreground && (show || tab == 3) ? (tab == 3 ? 2000 : 5000) : 0,
      );
    }
  }

  void _onTabChanged(int? previous, int next) {
    _demand();
    if (widget.tabs.contains(next)) return;
    // Only the module on top reacts; one being pushed or popped stays quiet.
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      widget.onForeignTab?.call(next);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _metricsClient?.demand('shell', 0);
    _metricsClient?.demand('windows', 0);
    _metricsClient?.demand('monitor:strip', 0);
    super.dispose();
  }

  static const _destinations = {
    WorkspaceTabs.monitor: NavigationDestination(
      icon: Icon(Icons.radar),
      label: 'Monitor',
    ),
    WorkspaceTabs.files: NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      label: 'Files',
    ),
    WorkspaceTabs.terminal: NavigationDestination(
      icon: Icon(Icons.terminal),
      label: 'Terminal',
    ),
    WorkspaceTabs.pc: NavigationDestination(
      icon: Icon(Icons.computer_outlined),
      label: 'PC',
    ),
  };

  static Widget _screen(int tab) => switch (tab) {
    WorkspaceTabs.monitor => const ChatLibraryScreen(),
    WorkspaceTabs.files => const WorkspaceFilesScreen(),
    WorkspaceTabs.terminal => const TerminalScreen(),
    _ => const LauncherScreen(),
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(workspaceTabProvider);
    final tab = _tab;
    final tabs = widget.tabs;
    _visited.add(tab);
    ref.listen(activeClientProvider, (_, _) => _demand());
    ref.listen(workspaceTabProvider, _onTabChanged);
    ref.listen(workspaceSettingsProvider, (_, _) => _demand());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _demand();
    });
    final settings = ref.watch(workspaceSettingsProvider);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final showStrip = settings['stats'] == true && tab != WorkspaceTabs.pc;
    return PopScope(
      canPop: tab == tabs.first,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && tab != tabs.first) {
          ref.read(workspaceTabProvider.notifier).select(tabs.first);
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: tabs.indexOf(tab),
          children: [
            for (final t in tabs)
              _visited.contains(t)
                  ? TickerMode(enabled: tab == t, child: _screen(t))
                  : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: keyboard || (tabs.length < 2 && !showStrip)
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showStrip) const PcStatsStrip(),
                  if (tabs.length > 1)
                    NavigationBar(
                      selectedIndex: tabs.indexOf(tab),
                      onDestinationSelected: (index) => ref
                          .read(workspaceTabProvider.notifier)
                          .select(tabs[index]),
                      destinations: [for (final t in tabs) _destinations[t]!],
                    ),
                ],
              ),
      ),
    );
  }
}

class PcStatsStrip extends ConsumerWidget {
  const PcStatsStrip({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionStatusProvider);
    final data = ref.watch(metricsProvider);
    final vitals = ref.watch(monitorProvider.select((s) => s.snapshot?.vitals));
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh =
        data != null && now - (data['timestamp'] as num? ?? 0) < 15000;
    final connected = status == RpcStatus.connected;
    if (connected && vitals != null && now - vitals.timestamp < 15000) {
      Widget stat(String label, double? pct, {String? extra}) => Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: NX.heat(pct ?? 0))),
            const SizedBox(width: 4),
            Text('$label ${pct == null ? '—' : '${pct.round()}%'}${extra ?? ''}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, fontFeatures: NX.tabular)),
          ],
        ),
      );
      return Semantics(
        button: true,
        label: 'Open PC statistics',
        child: InkWell(
          onTap: () => ref.read(workspaceTabProvider.notifier).select(3),
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            color: NX.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const LiveDot(color: NX.working, size: 6, pulse: false),
                const SizedBox(width: 4),
                Expanded(child: Text(vitals.hostname, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: NX.textDim))),
                stat('CPU', vitals.cpu, extra: vitals.cpuTempC == null ? null : ' ${vitals.cpuTempC!.round()}°'),
                stat('GPU', vitals.mainGpu?.busy),
                stat('RAM', vitals.ramPercent),
              ],
            ),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Open PC statistics',
      child: InkWell(
        onTap: () => ref.read(workspaceTabProvider.notifier).select(3),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: LayoutBuilder(
              builder: (context, size) => Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 7,
                    color: connected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      connected
                          ? 'PC connected'
                          : status == RpcStatus.connecting
                          ? 'Reconnecting…'
                          : 'PC offline',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (connected && fresh) ...[
                    Text(
                      'CPU ${(data['cpuPercent'] as num?)?.toStringAsFixed(0) ?? '—'}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'RAM ${(data['ramUsedGb'] as num?)?.toStringAsFixed(1) ?? '—'}${size.maxWidth > 350 && MediaQuery.textScalerOf(context).scale(1) < 1.3 ? ' / ${((data['ramTotalBytes'] as num? ?? 0) / 1073741824).toStringAsFixed(0)}' : ''} GB',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PcScreen extends ConsumerStatefulWidget {
  const PcScreen({super.key});
  @override
  ConsumerState<PcScreen> createState() => _PcScreenState();
}

class _PcScreenState extends ConsumerState<PcScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _info;
  bool _live = false, _bubble = false;
  Map<String, dynamic> _liveStatus = {};
  String? _error;
  bool _awaitingOverlayPermission = false;
  bool _resuming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _handleResume();
    }
  }

  Future<void> _handleResume() async {
    if (_resuming) return;
    _resuming = true;
    try {
      await _loadLiveStatus();
      if (!mounted || !_awaitingOverlayPermission || !Platform.isAndroid) {
        return;
      }
      if (_liveStatus['overlay'] == true) {
        _awaitingOverlayPermission = false;
        await _setLive(true, bubble: true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Choose Nexus in Display over other apps and allow access. If Android explicitly shows Restricted setting, check App info for Allow restricted settings, then return to overlay settings.',
            ),
            action: SnackBarAction(
              label: 'App info',
              onPressed: () => _openLiveSettings('live.appInfo'),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _resuming = false;
    }
  }

  Future<void> _openLiveSettings(String method) async {
    try {
      await PlatformBridge.call(method);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not open Android settings: $e');
      }
    }
  }

  Future<void> _loadLiveStatus() async {
    if (!Platform.isAndroid) return;
    final live = await PlatformBridge.call('live.status');
    if (!mounted) return;
    setState(() {
      _liveStatus = Map<String, dynamic>.from(live as Map);
      _live = _liveStatus['monitoringRequested'] == true;
      _bubble = _liveStatus['bubbleRequested'] == true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    // Phone permissions must remain readable even when the PC is offline.
    try {
      await _loadLiveStatus();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    try {
      final info = await ref
          .read(activeClientProvider)
          ?.requestMap('system.getInfo');
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _setLive(bool enabled, {bool? bubble}) async {
    try {
      if (enabled) {
        await NotificationService.instance.requestPermissions();
        await PlatformBridge.call('live.start', {
          'host': ref.read(connectionProvider).hostUrl,
          'bubble': bubble ?? _bubble,
        });
      } else {
        await PlatformBridge.call('live.stop');
      }
      await _loadLiveStatus();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(metricsProvider);
    final settings = ref.watch(workspaceSettingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.amber)),
          const _SettingsGroup('This PC'),
          Text(
            _info?['hostname'] ?? 'PC',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(ref.watch(connectionProvider).hostUrl ?? ''),
          const SizedBox(height: 16),
          if (data != null) ...[
            ListTile(
              title: const Text('CPU'),
              subtitle: LinearProgressIndicator(
                value: ((data['cpuPercent'] as num? ?? 0) / 100).clamp(0, 1),
              ),
              trailing: Text(
                '${(data['cpuPercent'] as num?)?.toStringAsFixed(0)}%',
              ),
            ),
            ListTile(
              title: const Text('Memory'),
              subtitle: LinearProgressIndicator(
                value: ((data['ramPercent'] as num? ?? 0) / 100).clamp(0, 1),
              ),
              trailing: Text('${data['ramUsedGb']} GB'),
            ),
            if (data['diskFreeBytes'] != null)
              ListTile(
                title: const Text('Disk available'),
                trailing: Text(
                  '${((data['diskFreeBytes'] as num) / 1073741824).toStringAsFixed(1)} GB',
                ),
              ),
          ],
          if (_info != null) ...[
            ListTile(
              title: const Text('CPU model'),
              subtitle: Text('${_info!['cpuModel']}'),
            ),
            ListTile(
              title: const Text('Operating system'),
              subtitle: Text('${_info!['os']}'),
            ),
          ],
          // Access and repair for this PC (moved here from PC details).
          const MonitorDemand(
            owner: 'pc-settings',
            intervalMs: 5000,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PhoneApprovalsSection(key: ValueKey('pc-approvals')),
                RemoteAccessSection(key: ValueKey('pc-remote')),
                SizedBox(height: 12),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.link_off),
            title: const Text('Disconnect PC'),
            subtitle: const Text('PC agents and shells keep running'),
            onTap: () async {
              if (Platform.isAndroid) await PlatformBridge.call('live.stop');
              ref.read(connectionProvider.notifier).disconnect();
              if (context.mounted) {
                Navigator.of(
                  context,
                  rootNavigator: true,
                ).popUntil((route) => route.isFirst);
              }
            },
          ),
          const _SettingsGroup('This phone'),
          SwitchListTile(
            title: const Text('PC status strip'),
            subtitle: const Text('CPU and memory above navigation'),
            value: settings['stats'] == true,
            onChanged: (value) async {
              ref.read(workspaceSettingsProvider.notifier).set('stats', value);
              (await SharedPreferences.getInstance()).setBool(
                'workspace.stats',
                value,
              );
            },
          ),
          if (Platform.isAndroid) ...[
            SwitchListTile(
              title: const Text('Live activity'),
              subtitle: Text(
                'Monitoring: ${_liveStatus['connectionState'] ?? 'stopped'} · Notifications: ${_liveStatus['notificationPermission'] == true && _liveStatus['notificationChannelAvailable'] == true ? 'available' : 'unavailable'}',
              ),
              value: _live,
              onChanged: (v) => _setLive(v),
            ),
            SwitchListTile(
              title: const Text('Floating pet monitor'),
              subtitle: Text(
                _liveStatus['bubbleVisible'] == true
                    ? 'Visible · Running and recent conversations, updated live'
                    : (_liveStatus['overlay'] != true
                          ? 'Display over other apps permission needed'
                          : _bubble
                          ? 'Ready in the background · Hidden while this app is open or the phone is locked'
                          : 'Off · Follow important PC updates with your pet'),
              ),
              value: _bubble,
              onChanged: (value) async {
                if (value) {
                  final status = await PlatformBridge.call('live.status');
                  if (status['overlay'] != true) {
                    if (!context.mounted) return;
                    final proceed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Allow floating pet'),
                        content: const Text(
                          'In Android Settings, choose Nexus (or Nexus Test) and enable Display over other apps. This is separate from notification bubbles. Return here, then go to your home screen to see the bubble.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Later'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Open settings'),
                          ),
                        ],
                      ),
                    );
                    if (proceed != true) return;
                    _awaitingOverlayPermission = true;
                    await _openLiveSettings('live.permission');
                    return;
                  }
                }
                _awaitingOverlayPermission = false;
                await _setLive(value || _live, bubble: value);
              },
            ),
            SwitchListTile(
              title: const Text('Notification actions'),
              subtitle: Text(
                ref
                            .read(activeClientProvider)
                            ?.supports('activity.actions.v1') ==
                        true
                    ? 'Allow approve, deny, and text reply from notifications'
                    : 'Update the PC host to enable watch actions',
              ),
              value: _liveStatus['notificationActionsEnabled'] == true,
              onChanged:
                  ref
                          .read(activeClientProvider)
                          ?.supports('activity.actions.v1') ==
                      true
                  ? (value) async {
                      await PlatformBridge.call('live.configureActions', {
                        'enabled': value,
                        'locked':
                            value &&
                            _liveStatus['actionsAllowedLocked'] == true,
                      });
                      await _load();
                    }
                  : null,
            ),
            SwitchListTile(
              title: const Text('Allow actions while phone is locked'),
              subtitle: const Text(
                'Permits notification actions without unlocking the phone. This does not verify who is wearing the watch.',
              ),
              value: _liveStatus['actionsAllowedLocked'] == true,
              onChanged:
                  ref
                          .read(activeClientProvider)
                          ?.supports('activity.actions.v1') ==
                      true
                  ? (value) async {
                      await PlatformBridge.call('live.configureActions', {
                        'enabled':
                            value ||
                            _liveStatus['notificationActionsEnabled'] == true,
                        'locked': value,
                      });
                      await _load();
                    }
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.watch_outlined),
              title: const Text('Send test notification'),
              subtitle: const Text(
                'In Mobvoi Health, enable notifications for this installed Nexus app. Check the watch itself for delivery.',
              ),
              onTap: () async {
                final status = await PlatformBridge.call(
                  'live.testNotification',
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        status['posted'] == true
                            ? 'Posted on the phone. Confirm delivery on the TicWatch.'
                            : 'Phone notifications are unavailable. Check notification permission and channel settings.',
                      ),
                    ),
                  );
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// A settings group header: what the settings below affect.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: NX.textFaint,
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.4,
      ),
    ),
  );
}
