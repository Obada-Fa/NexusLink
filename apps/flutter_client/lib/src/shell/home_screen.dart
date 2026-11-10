// The first screen: the current target with one tile per module it can run,
// the live bar, and a way to switch devices. With no current target it is
// the device picker.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/approvals.dart';
import '../rpc/rpc_client.dart';
import '../session/target.dart';
import '../state/connection.dart';
import '../state/last_host.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import '../workspace/platform_bridge.dart';
import '../workspace/project.dart';
import 'auto_connect.dart';
import 'device_picker.dart';
import '../modules/remote/remote_module.dart';
import 'home_art.dart';
import 'home_dock.dart';
import 'home_media.dart';
import 'live_bar.dart';
import 'module.dart';
import 'module_extras.dart';
import '../state/last_cwd.dart';
import 'resume_store.dart';
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
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() => _foreground = foreground);
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

  int _notificationGeneration = 0;

  /// A tapped agent notification: switch to its PC and open Agents.
  Future<void> _openTask(
    Map<String, dynamic> args, {
    bool coldStart = false,
  }) async {
    final shell = ref.read(shellProvider.notifier);
    final generation = ++_notificationGeneration;
    if (coldStart) resetAutoConnect();
    final host = args['host'];
    final link = taskLinkFromIntent(args);
    // A newer tap replaces any older link. The new one is only published
    // after the old screens are popped, so a chat list still showing (for
    // this PC or another) can't take it and then be closed under it.
    ref.read(pendingTaskProvider.notifier).select(null);
    if (host is String && host.trim().isNotEmpty) {
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
          if (mounted && generation == _notificationGeneration) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Connect to the alert’s PC: $e')),
            );
          }
          return;
        }
      }
    }
    if (!mounted || generation != _notificationGeneration) return;
    _openModule('agents', fromScratch: true);
    // The fresh Agents list takes it once connected to the link's PC.
    ref.read(pendingTaskProvider.notifier).select(link);
  }

  /// Module ids pushed above home, bottom to top.
  final _moduleStack = <String>[];

  /// Opens [moduleId] on top of whatever is showing, so Back returns there
  /// (a chat keeps its draft). A module already open is returned to instead
  /// of stacked twice. [fromScratch] (notification taps) starts from home.
  void _openModule(String moduleId, {bool fromScratch = false}) {
    if (!mounted) return;
    final module = ref
        .read(moduleListProvider)
        .where((m) => m.id == moduleId)
        .firstOrNull;
    final ctx = ref.read(moduleContextProvider);
    if (module == null || ctx == null) return;
    _ensureConnected(module, ctx);
    // Continue remembers where you went from Home. A module opened from
    // inside another one (chat → project files), or returned to, is a detour:
    // recording it would replace "Continue → that chat" with the detour.
    if (fromScratch || _moduleStack.isEmpty) {
      unawaited(
        ref
            .read(lastDestinationsProvider.notifier)
            .record(ctx.target.id, module.id)
            .catchError((_) {}),
      );
    }
    final nav = Navigator.of(context);
    if (fromScratch) {
      nav.popUntil((r) => r.settings.name == _homeRouteName || r.isFirst);
    } else if (_moduleStack.contains(module.id)) {
      nav.popUntil(
        (r) => r.settings.name == 'module:${module.id}' || r.isFirst,
      );
      return;
    }
    final below = fromScratch || _moduleStack.isEmpty
        ? null
        : _moduleStack.last;
    _moduleStack.add(module.id);
    nav
        .push(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: 'module:${module.id}'),
            builder: (_) => _ModuleRoute(module: module),
          ),
        )
        .whenComplete(() {
          _moduleStack.remove(module.id);
          // The module underneath shows its own tab again.
          final tab = below == null ? null : workspaceTabForModule(below);
          if (mounted && tab != null && _moduleStack.lastOrNull == below) {
            ref.read(workspaceTabProvider.notifier).select(tab);
          }
        });
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

  Future<void> _reconnect() async {
    final shell = ref.read(shellProvider.notifier);
    final target = ref.read(shellProvider).current;
    if (target != null && target.has(UtilityIds.nexuslink)) {
      unawaited(shell.connectCurrent().catchError((_) {}));
    }
    await shell.probe(force: true);
  }

  /// Everything about the current PC except switching: connection, wake,
  /// rename/remove and its address.
  Future<void> _openDeviceSettings(SavedTarget target) async {
    final conn = ref.read(connectionProvider);
    final url = nexusLinkUrlOf(target);
    final linked =
        url != null &&
        conn.hostUrl == url &&
        conn.status != RpcStatus.disconnected;
    final reachable = ref.read(moduleContextProvider)?.reachable;
    final address = targetAddressLabel(target);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                target.name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (address.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(address, style: const TextStyle(color: NX.textDim)),
              ],
              const SizedBox(height: 12),
              UtilityPills(target: target, reachable: reachable),
              const SizedBox(height: 12),
              if (!target.has(UtilityIds.remote))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('Add Remote'),
                  subtitle: const Text('Scan the QR code from Nexus Utilities'),
                  onTap: () => Navigator.pop(context, 'pair'),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Pair a utility'),
                onTap: () => Navigator.pop(context, 'pair'),
              ),

              if (target.has(UtilityIds.nexuslink))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(linked ? Icons.link_off : Icons.link),
                  title: Text(linked ? 'Disconnect' : 'Connect'),
                  onTap: () =>
                      Navigator.pop(context, linked ? 'disconnect' : 'connect'),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.power_settings_new),
                title: Text(target.wake == null ? 'Set up wake' : 'Wake PC'),
                onTap: () => Navigator.pop(context, 'wake'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Wake settings'),
                onTap: () => Navigator.pop(context, 'wakeSettings'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename or remove'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'pair':
        await startPairing(context, ref);
      case 'connect':
        await ref
            .read(shellProvider.notifier)
            .connectCurrent()
            .catchError((_) {});
      case 'disconnect':
        await _disconnect();
      case 'wake':
        await _wake(target);
      case 'wakeSettings':
        await openWakeSettings(context, ref, target);
      case 'edit':
        await editTarget(context, ref, target);
    }
  }

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
      visible: _foreground && (ModalRoute.isCurrentOf(context) ?? true),
      target: target,
      onOpenPicker: () => _openPicker(),
      onDeviceSettings: () => _openDeviceSettings(target),
      onPairAgain: () => _openPicker(pairAgain: target),
      onScanAgain: () => startPairing(context, ref),
      onTile: _onTile,
      onOpenModule: _openModule,
      onWake: () => _wake(target),
      onReconnect: _reconnect,
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
  final bool visible;
  const _HomeView({
    required this.visible,
    required this.target,
    required this.onOpenPicker,
    required this.onDeviceSettings,
    required this.onPairAgain,
    required this.onScanAgain,
    required this.onTile,
    required this.onOpenModule,
    required this.onWake,
    required this.onReconnect,
  });
  final SavedTarget target;
  final VoidCallback onOpenPicker;
  final VoidCallback onDeviceSettings;
  final VoidCallback onPairAgain;
  final VoidCallback onScanAgain;
  final void Function(HomeTile, ModuleContext) onTile;
  final void Function(String moduleId) onOpenModule;
  final VoidCallback onWake;
  final VoidCallback onReconnect;

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
    final availableModules = [for (final t in tiles) t.module];
    final url = nexusLinkUrlOf(target);
    final nexusConnected =
        url != null &&
        conn.hostUrl == url &&
        conn.status == RpcStatus.connected;
    final wakeHere = wake?.targetId == target.id ? wake : null;
    final waking = wakeHere?.active == true;
    final pairAgain = shell.pairAgainTargetId == target.id;
    final seenNow = nexusConnected || ctx.reachable.isNotEmpty;
    final seen = ref.watch(lastSeenProvider)[target.id];
    if (seenNow) {
      unawaited(
        ref.read(lastSeenProvider.notifier).seen(target.id).catchError((_) {}),
      );
    } else {
      unawaited(ref.read(lastSeenProvider.notifier).load(target.id));
    }
    final status = _heroStatus(
      nexusConnected: nexusConnected,
      connecting: connecting,
      ctx: ctx,
      shell: shell,
      waking: waking ? wakeHere!.message : null,
      lastSeen: seen,
    );
    final recovery = pairAgain
        ? null
        : homeRecovery(
            target,
            reachable: {
              ...ctx.reachable,
              if (nexusConnected) UtilityIds.nexuslink,
            },
            probedOnce: shell.probedOnce,
            busy: connecting || waking || shell.probing,
          );
    // Only live approvals from the connected PC count: they are current.
    final approvals = nexusConnected
        ? ref.watch(approvalsProvider).items
        : const <ExternalApproval>[];
    final last = ref.watch(lastDestinationsProvider)[target.id];
    final lastTile = last == null
        ? null
        : tiles.where((t) => t.module.id == last.moduleId).firstOrNull;
    final project = nexusConnected ? ref.watch(projectProvider) : null;
    unawaited(ref.read(lastDestinationsProvider.notifier).load(target.id));

    final tools = RefreshIndicator(
      onRefresh: () => ref.read(shellProvider.notifier).probe(force: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(NX.pad, 10, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _PcSelector(
                      target: target,
                      status: status,
                      onTap: onOpenPicker,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('device-settings'),
                    tooltip: 'Device settings',
                    onPressed: onDeviceSettings,
                    icon: const Icon(Icons.tune_rounded, color: NX.textDim),
                  ),
                ],
              ),
            ),
          ),
          if (pairAgain)
            SliverToBoxAdapter(
              child: _Banner(
                key: const ValueKey('pair-again-banner'),
                color: NX.waiting,
                icon: Icons.link_off,
                text: pairAgainText(target, shell.pairAgainUtilities),
                actions: [
                  if (!shell.pairAgainUtilities.contains(UtilityIds.nexuslink))
                    TextButton(
                      onPressed: () =>
                          ref.read(shellProvider.notifier).dismissPairAgain(),
                      child: const Text('Later'),
                    ),
                  TextButton(
                    onPressed: onScanAgain,
                    child: const Text('Scan QR'),
                  ),
                  if (shell.pairAgainUtilities.contains(UtilityIds.nexuslink) ||
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
          if (recovery != null)
            SliverToBoxAdapter(
              child: _Banner(
                key: const ValueKey('recovery-banner'),
                color: NX.waiting,
                icon: recovery.allDown
                    ? Icons.cloud_off_rounded
                    : Icons.report_gmailerrorred_rounded,
                title: recovery.title,
                text: recovery.body,
                actions: [
                  TextButton(
                    onPressed: onReconnect,
                    child: Text(recovery.allDown ? 'Reconnect' : 'Retry'),
                  ),
                  if (recovery.offerWake)
                    TextButton(onPressed: onWake, child: const Text('Wake PC')),
                ],
              ),
            ),
          SliverToBoxAdapter(
            child: HomeMedia(
              key: ValueKey(target.id),
              targetId: target.id,
              visible: visible,
              onOpenMedia: RemoteRuntime.openMedia,
            ),
          ),
          if (approvals.isNotEmpty || lastTile != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
                child: approvals.isNotEmpty
                    ? _AttentionCard(
                        approval: approvals.first,
                        more: approvals.length - 1,
                        pcName: target.name,
                        onTap: () {
                          ref
                              .read(pendingTaskProvider.notifier)
                              .select(
                                TaskLink(
                                  'chat:${approvals.first.chatId}',
                                  hostUrl: url!,
                                ),
                              );
                          onOpenModule('agents');
                        },
                      )
                    : lastTile != null
                    ? _ContinueCard(
                        module: lastTile.module,
                        at: last!.at,
                        project: continueLabel(
                          last,
                          project: _usesProject(lastTile.module.id)
                              ? project?.name
                              : null,
                        ),
                        onTap: () {
                          // Reopen the task, not just the tool.
                          if (last.chatId != null &&
                              last.moduleId == 'agents' &&
                              url != null) {
                            ref
                                .read(pendingTaskProvider.notifier)
                                .select(
                                  TaskLink('chat:${last.chatId}', hostUrl: url),
                                );
                          } else if (last.path != null &&
                              last.moduleId == 'files') {
                            ref
                                .read(pendingFolderProvider.notifier)
                                .select(last.path);
                          }
                          onTile(lastTile, ctx);
                        },
                      )
                    : const SizedBox.shrink(),
              ),
            ),

          if (tiles.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(NX.pad, 20, NX.pad, 0),
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
            for (final (_, groupTiles) in groupTiles(tiles))
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
                sliver: SliverToBoxAdapter(
                  child: ToolGrid(
                    children: [
                      for (final t in groupTiles)
                        ModuleTile(
                          tile: t,
                          ctx: ctx,
                          checkingLabel:
                              connecting &&
                                  t.module
                                      .utilitiesFor(ctx)
                                      .contains(UtilityIds.nexuslink)
                              ? 'Connecting…'
                              : 'Checking…',
                          onTap: () => onTile(t, ctx),
                        ),
                    ],
                  ),
                ),
              ),
          SliverToBoxAdapter(
            child: LiveBar(modules: availableModules, ctx: ctx),
          ),
          SliverToBoxAdapter(
            child: HomeDock(target: target, visible: visible, favourites: true),
          ),
          SliverToBoxAdapter(
            child: SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom),
          ),
        ],
      ),
    );
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const HomeWallpaper(),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(child: tools),
                HomeDock(target: target, visible: visible),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static bool _usesProject(String moduleId) =>
      const {'agents', 'terminal', 'files'}.contains(moduleId);

  static _HeroStatus _heroStatus({
    required bool nexusConnected,
    required bool connecting,
    required ModuleContext ctx,
    required ShellState shell,
    String? waking,
    DateTime? lastSeen,
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
    return _HeroStatus(offlineLabel(lastSeen), NX.idle);
  }
}

/// What Home's recovery banner says when part or all of a PC is down.
class HomeRecovery {
  const HomeRecovery({
    required this.title,
    required this.body,
    required this.allDown,
    required this.offerWake,
  });
  final String title;
  final String body;
  final bool allDown;
  final bool offerWake;
}

/// Null while checking, connecting or waking, or when every paired utility
/// answers. [reachable] includes NexusLink when its connection is up.
HomeRecovery? homeRecovery(
  SavedTarget target, {
  required Set<String> reachable,
  required bool probedOnce,
  required bool busy,
}) {
  if (!probedOnce || busy) return null;
  final paired = [
    for (final u in UtilityIds.all)
      if (target.has(u)) u,
  ];
  final down = [
    for (final u in paired)
      if (!reachable.contains(u)) u,
  ];
  if (down.isEmpty) return null;
  if (down.length == paired.length) {
    return HomeRecovery(
      title: '${target.name} is offline',
      body:
          'Check that the PC is on and Nexus Utilities is running, and that '
          'this phone is on the same network or Tailscale.',
      allDown: true,
      offerWake: target.wake != null,
    );
  }
  final names = down.map(utilityName).join(' and ');
  return HomeRecovery(
    title: '$names ${down.length == 1 ? 'isn’t' : 'aren’t'} answering',
    body:
        'Other tools on ${target.name} work. Check that $names '
        '${down.length == 1 ? 'is' : 'are'} running in Nexus Utilities.',
    allDown: false,
    offerWake: false,
  );
}

class _HeroStatus {
  const _HeroStatus(this.label, this.color, {this.live = false});
  final String label;
  final Color color;
  final bool live;
}

/// The one place to switch PCs: name and connection state.
class _PcSelector extends StatelessWidget {
  const _PcSelector({
    required this.target,
    required this.status,
    required this.onTap,
  });
  final SavedTarget target;
  final _HeroStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${target.name}, ${status.label}. Switch PC',
    excludeSemantics: true,
    child: InkWell(
      key: const ValueKey('pc-selector'),
      borderRadius: BorderRadius.circular(NX.radiusSm),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            target.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: NX.textDim,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
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
                            status.label,
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
            ],
          ),
        ),
      ),
    ),
  );
}

/// A verified pending request on the connected PC.
class _AttentionCard extends StatelessWidget {
  const _AttentionCard({
    required this.approval,
    required this.more,
    required this.pcName,
    required this.onTap,
  });
  final ExternalApproval approval;
  final int more;
  final String pcName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final verb = switch (approval.kind) {
      'question' => 'Answer question',
      'plan' => 'Review plan',
      _ => 'Review approval',
    };
    final cwd = approval.json['cwd'] as String?;
    final project = cwd == null
        ? pcName
        : cwd.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).lastOrNull ??
              pcName;
    return _ActionCard(
      key: const ValueKey('attention-card'),
      color: NX.waiting,
      icon: Icons.front_hand_outlined,
      eyebrow: more > 0 ? 'NEEDS YOU · ${more + 1}' : 'NEEDS YOU',
      title: '$verb · $project',
      subtitle: approval.title,
      onTap: onTap,
    );
  }
}

/// Back to the last tool used on this PC.
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.module,
    required this.at,
    required this.project,
    required this.onTap,
  });
  final NexusModule module;
  final DateTime at;
  final String? project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _ActionCard(
    key: const ValueKey('continue-card'),
    color: NX.accent,
    icon: module.icon,
    eyebrow: 'CONTINUE',
    title: project == null ? module.title : '${module.title} · $project',
    subtitle: 'Last opened ${shortAgo(at)}',
    onTap: onTap,
  );
}

/// What the Continue card names: the chat or folder you were in, else the
/// selected project (for project tools), else nothing.
String? continueLabel(LastDestination last, {String? project}) {
  final title = last.title?.trim();
  if (last.chatId != null && title != null && title.isNotEmpty) return title;
  final path = last.path;
  if (path != null && path.isNotEmpty) return folderDisplayName(path);
  return project;
}

/// The task a tapped notification names (`openTask` / `live.pendingTask`
/// arguments: `taskId`, `host`, `approval`, and since 1.0.47 `requestId`).
/// Older intents have no `requestId`; those without a PC or task open none.
TaskLink? taskLinkFromIntent(Map<String, dynamic> args) {
  final id = args['taskId'];
  final host = args['host'];
  if (id is! String || id.isEmpty || host is! String || host.trim().isEmpty) {
    return null;
  }
  final request = args['requestId'];
  final approval = args['approval'] == true;
  return TaskLink(
    id,
    hostUrl: normalizeHostWsUrl(host),
    approval: approval,
    requestId: approval && request is String && request.isNotEmpty
        ? request
        : null,
  );
}

/// "Offline · seen 2 h ago" once the PC has been reachable before.
String offlineLabel(DateTime? lastSeen, {DateTime? now}) => lastSeen == null
    ? 'Offline'
    : 'Offline · seen ${shortAgo(lastSeen, now: now)}';

/// "just now", "5 min ago", "3 h ago", "2 d ago".
String shortAgo(DateTime at, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.color,
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String eyebrow;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$title. $subtitle',
    excludeSemantics: true,
    child: NxCard(
      flat: true,
      color: const Color(0xff283642),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: NX.textDim, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right_rounded, color: color),
        ],
      ),
    ),
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
    this.title,
  });
  final Color color;
  final IconData icon;
  final String? title;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
    child: NxCard(
      flat: true,
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(text, style: const TextStyle(fontSize: 13.5)),
                  ],
                ),
              ),
            ],
          ),
          Wrap(alignment: WrapAlignment.end, children: actions),
        ],
      ),
    ),
  );
}
