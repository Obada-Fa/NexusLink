// The first screen: the current target with one tile per module it can run,
// the live bar, and a way to switch devices. With no current target it is
// the device picker.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/rpc_client.dart';
import '../session/target.dart';
import '../state/connection.dart';
import '../state/last_host.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import '../workspace/platform_bridge.dart';
import '../workspace/project.dart';
import 'auto_connect.dart';
import 'capabilities.dart';
import 'device_picker.dart';
import 'live_bar.dart';
import 'module.dart';
import 'module_extras.dart';
import 'module_registry.dart';
import 'shell_controller.dart';
import 'shell_navigator.dart';
import 'target_actions.dart';
import 'tiles.dart';

const _homeRouteName = '/';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.probeEvery = const Duration(seconds: 30)});

  /// While home is visible, re-probe reachability this often (stands in for
  /// network-change events, which need a plugin the app doesn't have).
  final Duration probeEvery;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  Timer? _probeTimer;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ShellNavigator.instance.attach(_openModule);
    if (Platform.isAndroid) {
      PlatformBridge.channel.setMethodCallHandler((call) async {
        if (call.method == 'openTask' && call.arguments is Map) {
          await _openTask(Map<String, dynamic>.from(call.arguments as Map));
        }
      });
    }
    _probeTimer = Timer.periodic(widget.probeEvery, (_) {
      if (_foreground && ModalRoute.of(context)?.isCurrent == true) {
        ref.read(shellProvider.notifier).probe();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _coldStart());
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    ShellNavigator.instance.detach(_openModule);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) ref.read(shellProvider.notifier).probe();
  }

  Future<void> _coldStart() async {
    final shell = ref.read(shellProvider.notifier);
    await shell.load();
    if (!mounted) return;
    if (Platform.isAndroid) {
      try {
        final link = await PlatformBridge.call('live.pendingTask');
        if (!mounted) return;
        if (link is Map && link['host'] is String) {
          await _openTask(Map<String, dynamic>.from(link), coldStart: true);
          return;
        }
      } catch (_) {}
    }
    await shell.autoConnect();
  }

  /// A tapped agent notification: switch to its PC and open Agents.
  Future<void> _openTask(
    Map<String, dynamic> args, {
    bool coldStart = false,
  }) async {
    final shell = ref.read(shellProvider.notifier);
    if (coldStart) resetAutoConnect();
    final host = args['host'] as String?;
    ref.read(pendingTaskProvider.notifier).select(args['taskId'] as String?);
    if (host != null) {
      final url = normalizeHostWsUrl(host);
      final target = shell.targetForUrl(url);
      if (target != null) {
        await shell.select(target.id);
      } else {
        // An alert from a PC this phone hasn't saved yet: save it, as the
        // old connect screen did after a successful connect.
        try {
          await shell.addNexusLink(url);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Connect to the alert’s PC: $e')),
            );
          }
        }
      }
    }
    _openModule('agents');
  }

  void _openModule(String moduleId) {
    if (!mounted) return;
    final module = ref
        .read(moduleListProvider)
        .where((m) => m.id == moduleId)
        .firstOrNull;
    final ctx = ref.read(moduleContextProvider);
    if (module == null || ctx == null) return;
    _ensureConnected(module, ctx);
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.settings.name == _homeRouteName || r.isFirst);
    nav.push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: 'module:${module.id}'),
        builder: (_) => _ModuleRoute(module: module),
      ),
    );
  }

  /// Opening a NexusLink module dials the shared connection if it is idle.
  void _ensureConnected(NexusModule module, ModuleContext ctx) {
    if (!module.utilitiesFor(ctx).contains(UtilityIds.nexuslink)) return;
    final conn = ref.read(connectionProvider);
    final url = nexusLinkUrlOf(ctx.target);
    if (url == null) return;
    if (conn.hostUrl == url && conn.status != RpcStatus.disconnected) return;
    if (conn.authRequired) return;
    unawaited(
      ref.read(shellProvider.notifier).connectCurrent().catchError((_) {}),
    );
  }

  void _onTile(HomeTile tile, ModuleContext ctx) {
    final blocked = moduleBlockedReason(tile.module, ctx);
    if (blocked != null) {
      _explainBlocked(tile.module, blocked);
    } else if (tile.status == TileStatus.offline) {
      _explainOffline(tile.module, ctx);
    } else {
      _openModule(tile.module.id);
    }
  }

  Future<void> _explainOffline(NexusModule module, ModuleContext ctx) async {
    final utilities = module.utilitiesFor(ctx).map(utilityName).join(' and ');
    final conn = ref.read(connectionProvider);
    final lastError = conn.hostUrl == nexusLinkUrlOf(ctx.target)
        ? conn.lastError
        : null;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(module.icon, color: NX.textDim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${module.title} is offline',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '${ctx.target.name} isn’t answering on $utilities. Check that '
                'the PC is on and Nexus Utilities is running, and that this '
                'phone is on the same network or Tailscale.',
                style: const TextStyle(color: NX.textDim, height: 1.35),
              ),
              if (lastError != null) ...[
                const SizedBox(height: 10),
                Text(
                  lastError,
                  style: const TextStyle(color: NX.waiting, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, 'retry'),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, 'wake'),
                icon: const Icon(Icons.power_settings_new),
                label: Text(
                  ctx.target.wake == null ? 'Set up wake' : 'Wake PC',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    final shell = ref.read(shellProvider.notifier);
    if (action == 'retry') {
      if (module.utilitiesFor(ctx).contains(UtilityIds.nexuslink)) {
        unawaited(shell.connectCurrent().catchError((_) {}));
      }
      await shell.probe(force: true);
    } else if (action == 'wake') {
      await _wake(ctx.target);
    }
  }

  /// A module that can't run for a reason other than reachability (e.g. its
  /// pairing secret is gone): say why and offer a fresh scan.
  Future<void> _explainBlocked(NexusModule module, String reason) async {
    final scan = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(module.icon, color: NX.textDim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${module.title} can’t start',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                reason,
                style: const TextStyle(color: NX.textDim, height: 1.35),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan QR to pair again'),
              ),
            ],
          ),
        ),
      ),
    );
    if (scan == true && mounted) await startPairing(context, ref);
  }

  Future<void> _wake(SavedTarget target) async {
    if (target.wake == null) {
      await openWakeSettings(context, ref, target);
      return;
    }
    await ref.read(wakeFlowProvider.notifier).wake(target);
  }

  Future<void> _openPicker({SavedTarget? pairAgain}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'devices'),
          builder: (_) => DevicePickerScreen(pairAgain: pairAgain),
        ),
      );

  Future<void> _disconnect() async {
    if (Platform.isAndroid) {
      try {
        await PlatformBridge.call('live.stop');
      } catch (_) {}
    }
    ref.read(connectionProvider.notifier).disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellProvider);
    if (!shell.loaded) {
      return const Scaffold(body: Center(child: NexusMark(size: 64)));
    }
    final target = shell.current;
    if (target == null) return const DevicePickerScreen(isRoot: true);
    return _HomeView(
      target: target,
      onOpenPicker: () => _openPicker(),
      onPairAgain: () => _openPicker(pairAgain: target),
      onScanAgain: () => startPairing(context, ref),
      onTile: _onTile,
      onWake: () => _wake(target),
      onWakeSettings: () => openWakeSettings(context, ref, target),
      onEdit: () => editTarget(context, ref, target),
      onDisconnect: _disconnect,
    );
  }
}

/// Keeps the module's entry in step with the current target.
class _ModuleRoute extends ConsumerWidget {
  const _ModuleRoute({required this.module});
  final NexusModule module;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctx = ref.watch(moduleContextProvider);
    if (ctx == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Pick a device first.')),
      );
    }
    return module.buildEntry(context, ctx);
  }
}

class _HomeView extends ConsumerWidget {
  const _HomeView({
    required this.target,
    required this.onOpenPicker,
    required this.onPairAgain,
    required this.onScanAgain,
    required this.onTile,
    required this.onWake,
    required this.onWakeSettings,
    required this.onEdit,
    required this.onDisconnect,
  });
  final SavedTarget target;
  final VoidCallback onOpenPicker;
  final VoidCallback onPairAgain;
  final VoidCallback onScanAgain;
  final void Function(HomeTile, ModuleContext) onTile;
  final VoidCallback onWake;
  final VoidCallback onWakeSettings;
  final VoidCallback onEdit;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellProvider);
    final ctx = ref.watch(moduleContextProvider)!;
    final modules = ref.watch(moduleListProvider);
    final connecting = ref.watch(nexusLinkConnectingProvider);
    final conn = ref.watch(connectionProvider);
    final wake = ref.watch(wakeFlowProvider);
    final tiles = homeTiles(
      modules,
      ctx,
      nexusLinkConnecting: connecting,
      probedOnce: shell.probedOnce,
    );
    final visible = [for (final t in tiles) t.module];
    final url = nexusLinkUrlOf(target);
    final nexusConnected =
        url != null &&
        conn.hostUrl == url &&
        conn.status == RpcStatus.connected;
    final missing = _missingUtilities(modules, target);
    final wakeHere = wake?.targetId == target.id ? wake : null;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () => ref.read(shellProvider.notifier).probe(force: true),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(NX.pad, 10, 6, 0),
                  child: Row(
                    children: [
                      const NexusMark(size: 28),
                      const SizedBox(width: 10),
                      const Text(
                        'Nexus',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.3,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Devices',
                        onPressed: onOpenPicker,
                        icon: const Icon(Icons.devices_other_rounded),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(NX.pad, 10, NX.pad, 0),
                  child: _TargetHero(
                    target: target,
                    ctx: ctx,
                    status: _heroStatus(
                      nexusConnected: nexusConnected,
                      connecting: connecting,
                      ctx: ctx,
                      shell: shell,
                      waking: wakeHere?.active == true
                          ? wakeHere!.message
                          : null,
                    ),
                    onSwitch: onOpenPicker,
                    menu: _HeroMenu(
                      target: target,
                      nexusConnected: nexusConnected || connecting,
                      onEdit: onEdit,
                      onWake: onWake,
                      onWakeSettings: onWakeSettings,
                      onDisconnect: onDisconnect,
                      onConnect: () => ref
                          .read(shellProvider.notifier)
                          .connectCurrent()
                          .catchError((_) {}),
                      onSwitch: onOpenPicker,
                    ),
                  ),
                ),
              ),
              if (shell.pairAgainTargetId == target.id)
                SliverToBoxAdapter(
                  child: _Banner(
                    key: const ValueKey('pair-again-banner'),
                    color: NX.waiting,
                    icon: Icons.link_off,
                    text: pairAgainText(target, shell.pairAgainUtilities),
                    actions: [
                      if (!shell.pairAgainUtilities.contains(
                        UtilityIds.nexuslink,
                      ))
                        TextButton(
                          onPressed: () => ref
                              .read(shellProvider.notifier)
                              .dismissPairAgain(),
                          child: const Text('Later'),
                        ),
                      TextButton(
                        onPressed: onScanAgain,
                        child: const Text('Scan QR'),
                      ),
                      if (shell.pairAgainUtilities.contains(
                            UtilityIds.nexuslink,
                          ) ||
                          shell.pairAgainUtilities.isEmpty)
                        TextButton(
                          onPressed: onPairAgain,
                          child: const Text('Type code'),
                        ),
                    ],
                  ),
                ),
              if (wakeHere?.error != null)
                SliverToBoxAdapter(
                  child: _Banner(
                    color: NX.failed,
                    icon: Icons.power_off_outlined,
                    text: wakeHere!.error!,
                    actions: [
                      TextButton(
                        onPressed: () =>
                            ref.read(wakeFlowProvider.notifier).clearError(),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                ),
              SliverToBoxAdapter(child: LiveBar(modules: visible, ctx: ctx)),
              SliverToBoxAdapter(
                child: NxSectionHeader(
                  'Utilities',
                  count: tiles.length,
                  trailing: shell.probing
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.6),
                        )
                      : null,
                ),
              ),
              if (tiles.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: NX.pad),
                    child: NxCard(
                      child: Text(
                        'Nothing on ${target.name} works with this phone yet. '
                        'Scan the QR code from Nexus Utilities to pair it.',
                        style: const TextStyle(color: NX.textDim),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: NX.pad),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 240,
                          mainAxisSpacing: NX.gap,
                          crossAxisSpacing: NX.gap,
                          mainAxisExtent: 156,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => ModuleTile(
                        tile: tiles[i],
                        ctx: ctx,
                        checkingLabel:
                            connecting &&
                                tiles[i].module
                                    .utilitiesFor(ctx)
                                    .contains(UtilityIds.nexuslink)
                            ? 'Connecting…'
                            : 'Checking…',
                        onTap: () => onTile(tiles[i], ctx),
                      ),
                      childCount: tiles.length,
                    ),
                  ),
                ),
              if (missing.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      NX.pad,
                      NX.gap,
                      NX.pad,
                      0,
                    ),
                    child: NxCard(
                      onTap: onScanAgain,
                      child: Row(
                        children: [
                          const Icon(Icons.add_circle_outline, color: NX.accent),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Add ${missing.map(utilityName).join(' and ')}: '
                              'scan the QR code from Nexus Utilities.',
                              style: const TextStyle(color: NX.textDim),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }

  /// Utilities the target hasn't paired that a compiled-in module could use.
  static List<String> _missingUtilities(
    List<NexusModule> modules,
    SavedTarget target,
  ) => [
    for (final u in UtilityIds.all)
      if (!target.has(u) &&
          modulesFor(
            modules,
            capabilities: [
              for (final id in phase1Capabilities[u] ?? const <String>[])
                Capability(id, utility: u),
            ],
          ).isNotEmpty)
        u,
  ];

  static _HeroStatus _heroStatus({
    required bool nexusConnected,
    required bool connecting,
    required ModuleContext ctx,
    required ShellState shell,
    String? waking,
  }) {
    if (waking != null) return _HeroStatus(waking, NX.waiting, live: true);
    if (nexusConnected) return const _HeroStatus('Connected', NX.working);
    if (connecting) {
      return const _HeroStatus('Connecting…', NX.waiting, live: true);
    }
    if (ctx.reachable.isNotEmpty) {
      return const _HeroStatus('Online', NX.working);
    }
    if (!shell.probedOnce) {
      return const _HeroStatus('Checking…', NX.waiting, live: true);
    }
    return const _HeroStatus('Offline', NX.idle);
  }
}

class _HeroStatus {
  const _HeroStatus(this.label, this.color, {this.live = false});
  final String label;
  final Color color;
  final bool live;
}

class _TargetHero extends StatelessWidget {
  const _TargetHero({
    required this.target,
    required this.ctx,
    required this.status,
    required this.onSwitch,
    required this.menu,
  });
  final SavedTarget target;
  final ModuleContext ctx;
  final _HeroStatus status;
  final VoidCallback onSwitch;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final address = targetAddressLabel(target);
    return NxCard(
      key: const ValueKey('target-hero'),
      accent: status.color == NX.working ? NX.accent : null,
      padding: const EdgeInsets.fromLTRB(16, 16, 4, 16),
      onTap: onSwitch,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TargetBadge(icon: target.icon, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            target.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.unfold_more_rounded,
                          size: 20,
                          color: NX.textFaint,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        LiveDot(
                          color: status.color,
                          size: 7,
                          pulse: status.live,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            address.isEmpty
                                ? status.label
                                : '${status.label} · $address',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: status.color == NX.idle
                                  ? NX.textDim
                                  : status.color,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              menu,
            ],
          ),
          const SizedBox(height: 12),
          UtilityPills(target: target, reachable: ctx.reachable),
        ],
      ),
    );
  }
}

class _HeroMenu extends StatelessWidget {
  const _HeroMenu({
    required this.target,
    required this.nexusConnected,
    required this.onEdit,
    required this.onWake,
    required this.onWakeSettings,
    required this.onDisconnect,
    required this.onConnect,
    required this.onSwitch,
  });
  final SavedTarget target;
  final bool nexusConnected;
  final VoidCallback onEdit;
  final VoidCallback onWake;
  final VoidCallback onWakeSettings;
  final VoidCallback onDisconnect;
  final VoidCallback onConnect;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Device options',
    icon: const Icon(Icons.more_vert, color: NX.textDim),
    onSelected: (v) => switch (v) {
      'edit' => onEdit(),
      'wake' => onWake(),
      'wakeSettings' => onWakeSettings(),
      'disconnect' => onDisconnect(),
      'connect' => onConnect(),
      _ => onSwitch(),
    },
    itemBuilder: (_) => [
      if (target.has(UtilityIds.nexuslink))
        nexusConnected
            ? const PopupMenuItem(
                value: 'disconnect',
                child: ListTile(
                  leading: Icon(Icons.link_off),
                  title: Text('Disconnect'),
                ),
              )
            : const PopupMenuItem(
                value: 'connect',
                child: ListTile(
                  leading: Icon(Icons.link),
                  title: Text('Connect'),
                ),
              ),
      PopupMenuItem(
        value: 'wake',
        child: ListTile(
          leading: const Icon(Icons.power_settings_new),
          title: Text(target.wake == null ? 'Set up wake' : 'Wake PC'),
        ),
      ),
      const PopupMenuItem(
        value: 'wakeSettings',
        child: ListTile(
          leading: Icon(Icons.settings_outlined),
          title: Text('Wake settings'),
        ),
      ),
      const PopupMenuItem(
        value: 'edit',
        child: ListTile(
          leading: Icon(Icons.edit_outlined),
          title: Text('Rename or remove'),
        ),
      ),
      const PopupMenuItem(
        value: 'switch',
        child: ListTile(
          leading: Icon(Icons.devices_other_rounded),
          title: Text('Switch device'),
        ),
      ),
    ],
  );
}

/// The pair-again banner's text: the whole PC when NexusLink was refused,
/// else the utilities that were.
String pairAgainText(SavedTarget target, Set<String> utilities) {
  if (utilities.isEmpty || utilities.contains(UtilityIds.nexuslink)) {
    return 'This phone is no longer paired with ${target.name}.';
  }
  final names = [
    for (final u in UtilityIds.all)
      if (utilities.contains(u)) utilityName(u),
  ].join(' and ');
  return '${target.name} no longer accepts this phone for $names. '
      'Scan the QR code from Nexus Utilities to pair again.';
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.color,
    required this.icon,
    required this.text,
    required this.actions,
  });
  final Color color;
  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
    child: NxCard(
      accent: color,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: const TextStyle(fontSize: 13.5)),
              ),
            ],
          ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
        ],
      ),
    ),
  );
}
