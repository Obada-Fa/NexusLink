import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/agent_screen.dart';
import '../services/notification_service.dart';
import '../screens/terminal_screen.dart';
import '../screens/launcher_screen.dart';
import '../state/connection.dart';
import '../rpc/rpc_client.dart';
import 'files_screen.dart';
import 'metrics.dart';
import 'project.dart';
import 'platform_bridge.dart';
import 'documents.dart';

class WorkspaceShell extends ConsumerStatefulWidget {
  const WorkspaceShell({super.key});
  @override
  ConsumerState<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends ConsumerState<WorkspaceShell>
    with WidgetsBindingObserver {
  final _keys = List.generate(4, (_) => GlobalKey<NavigatorState>());
  final _visited = <int>{0};
  bool _foreground = true;
  RpcClient? _metricsClient;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      PlatformBridge.channel.setMethodCallHandler((call) async {
        if (call.method == 'openTask' && call.arguments is Map) {
          final args = Map<String, dynamic>.from(call.arguments);
          final host = args['host'] as String?;
          ref
              .read(pendingTaskProvider.notifier)
              .select(args['taskId'] as String?);
          ref.read(workspaceTabProvider.notifier).select(0);
          if (host != null && host != ref.read(connectionProvider).hostUrl) {
            try {
              await ref.read(connectionProvider.notifier).connect(host);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Connect to the alert’s PC: $e')),
                );
              }
            }
          }
        }
      });
    }
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    ref
        .read(workspaceSettingsProvider.notifier)
        .set('stats', prefs.getBool('workspace.stats') ?? true);
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
      _metricsClient = client;
    }
    final tab = ref.read(workspaceTabProvider);
    final show = ref.read(workspaceSettingsProvider)['stats'] == true;
    client?.demand(
      'shell',
      _foreground && (show || tab == 3) ? (tab == 3 ? 2000 : 5000) : 0,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _metricsClient?.demand('shell', 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(workspaceTabProvider);
    _visited.add(tab);
    ref.listen(activeClientProvider, (_, _) => _demand());
    ref.listen(workspaceTabProvider, (_, _) => _demand());
    ref.listen(workspaceSettingsProvider, (_, _) => _demand());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _demand();
    });
    final settings = ref.watch(workspaceSettingsProvider);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: tab == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && tab != 0) {
          ref.read(workspaceTabProvider.notifier).select(0);
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: tab,
          children: [
            for (var i = 0; i < 4; i++)
              _visited.contains(i)
                  ? TickerMode(
                      enabled: tab == i,
                      child: NavigatorPopHandler<Object?>(
                        enabled: tab == i,
                        onPopWithResult: (_) =>
                            _keys[i].currentState?.maybePop(),
                        child: Navigator(
                          key: _keys[i],
                          onGenerateRoute: (_) => MaterialPageRoute(
                            builder: (_) => switch (i) {
                              0 => const AgentScreen(),
                              1 => const WorkspaceFilesScreen(),
                              2 => const TerminalScreen(),
                              _ => const PcScreen(),
                            },
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: keyboard
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (settings['stats'] == true) const PcStatsStrip(),
                  NavigationBar(
                    selectedIndex: tab,
                    onDestinationSelected: (index) =>
                        ref.read(workspaceTabProvider.notifier).select(index),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.auto_awesome_outlined),
                        label: 'Agents',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.folder_outlined),
                        label: 'Files',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.terminal),
                        label: 'Terminal',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.computer_outlined),
                        label: 'PC',
                      ),
                    ],
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
    final fresh =
        data != null &&
        DateTime.now().millisecondsSinceEpoch -
                (data['timestamp'] as num? ?? 0) <
            15000;
    final connected = status == RpcStatus.connected;
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

class _PcScreenState extends ConsumerState<PcScreen> {
  Map<String, dynamic>? _info;
  bool _live = false, _bubble = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await ref
          .read(activeClientProvider)
          ?.requestMap('system.getInfo');
      dynamic live;
      if (Platform.isAndroid) live = await PlatformBridge.call('live.status');
      if (mounted) {
        setState(() {
          _info = info;
          _live = live?['running'] == true;
          _bubble = live?['bubble'] == true;
        });
      }
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
      if (mounted) {
        setState(() {
          _live = enabled;
          if (bubble != null) _bubble = bubble;
        });
      }
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
        title: const Text('Your PC'),
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
              subtitle: const Text(
                'Keep task status in an ongoing Android notification',
              ),
              value: _live,
              onChanged: (v) => _setLive(v),
            ),
            SwitchListTile(
              title: const Text('Floating status bubble'),
              subtitle: const Text('Optional indicator over other apps'),
              value: _bubble,
              onChanged: (value) async {
                if (value) {
                  final status = await PlatformBridge.call('live.status');
                  if (status['overlay'] != true) {
                    await PlatformBridge.call('live.permission');
                    return;
                  }
                }
                await _setLive(value || _live, bubble: value);
              },
            ),
          ],
          const Divider(),
          SwitchListTile(
            title: const Text('Experimental streaming'),
            subtitle: const Text(
              'Optional desktop viewer; not needed for coding',
            ),
            value: settings['experimental'] == true,
            onChanged: (v) => ref
                .read(workspaceSettingsProvider.notifier)
                .set('experimental', v),
          ),
          if (settings['experimental'] == true)
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Open experimental desktop tools'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _ExperimentalScreen()),
              ),
            ),
          const Divider(),
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
        ],
      ),
    );
  }
}

class _ExperimentalScreen extends ConsumerStatefulWidget {
  const _ExperimentalScreen();
  @override
  ConsumerState<_ExperimentalScreen> createState() =>
      _ExperimentalScreenState();
}

class _ExperimentalScreenState extends ConsumerState<_ExperimentalScreen> {
  RpcClient? _client;
  @override
  void initState() {
    super.initState();
    _client = ref.read(activeClientProvider);
    _client?.demand('windows', 5000);
  }

  @override
  void dispose() {
    _client?.demand('windows', 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const LauncherScreen();
}
