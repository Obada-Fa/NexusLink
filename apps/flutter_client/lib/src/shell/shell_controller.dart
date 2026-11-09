// Session core wiring for the shell: saved targets, the current target, its
// reachability and the shared NexusLink connection.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/rpc_client.dart';
import '../session/store.dart';
import '../session/target.dart';
import '../state/connection.dart';
import '../state/last_host.dart';
import '../state/wake_config.dart';
import '../workspace/platform_bridge.dart';
import 'auto_connect.dart';
import 'capabilities.dart';
import 'module.dart';
import 'module_extras.dart';
import 'module_registry.dart';
import 'resume_store.dart';
import 'module_signals.dart';
import 'reachability.dart';

/// Auto-connect runs at most once per app run (cold start).
bool _autoConnectAttempted = false;

/// Called when the app reloads after a crash screen, and by tests.
void resetAutoConnect() => _autoConnectAttempted = false;

class ShellState {
  const ShellState({
    this.loaded = false,
    this.targets = const [],
    this.currentId,
    this.reachable = const {},
    this.probing = false,
    this.probedOnce = false,
    this.pairAgainTargetId,
    this.pairAgainUtilities = const {},
    this.error,
  });

  final bool loaded;
  final List<SavedTarget> targets;
  final String? currentId;

  /// Utilities of the current target that answered the last TCP probe.
  final Set<String> reachable;
  final bool probing;

  /// At least one probe of the current target finished.
  final bool probedOnce;

  /// A pairing of this target was refused: offer "Pair again".
  final String? pairAgainTargetId;

  /// Which utilities of [pairAgainTargetId] were refused (UtilityIds.*).
  final Set<String> pairAgainUtilities;
  final String? error;

  SavedTarget? get current =>
      targets.where((t) => t.id == currentId).firstOrNull;

  ShellState copyWith({
    bool? loaded,
    List<SavedTarget>? targets,
    String? currentId,
    bool clearCurrent = false,
    Set<String>? reachable,
    bool? probing,
    bool? probedOnce,
    String? pairAgainTargetId,
    Set<String>? pairAgainUtilities,
    bool clearPairAgain = false,
    String? error,
    bool clearError = false,
  }) => ShellState(
    loaded: loaded ?? this.loaded,
    targets: targets ?? this.targets,
    currentId: clearCurrent ? null : currentId ?? this.currentId,
    reachable: reachable ?? this.reachable,
    probing: probing ?? this.probing,
    probedOnce: probedOnce ?? this.probedOnce,
    pairAgainTargetId: clearPairAgain
        ? null
        : pairAgainTargetId ?? this.pairAgainTargetId,
    pairAgainUtilities: clearPairAgain
        ? const {}
        : pairAgainUtilities ?? this.pairAgainUtilities,
    error: clearError ? null : error ?? this.error,
  );
}

/// The compiled-in modules; overridable in tests.
final moduleListProvider = Provider<List<NexusModule>>((_) => moduleRegistry);

final reachabilityProberProvider = Provider<ReachabilityProber>(
  (_) => ReachabilityProber(),
);

/// Whether this phone holds a NexusLink pairing for a ws URL.
final nexusLinkCredentialCheckProvider =
    Provider<Future<bool> Function(String wsUrl)>(
      (_) => (url) async =>
          (await PlatformBridge.credential(url))?.isNotEmpty == true,
    );

final shellProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);

/// What modules get about the current target, or null without one.
final moduleContextProvider = Provider<ModuleContext?>((ref) {
  final shell = ref.watch(shellProvider);
  final target = shell.current;
  if (target == null) return null;
  final conn = ref.watch(
    connectionProvider.select((s) => (status: s.status, host: s.hostUrl)),
  );
  final reachable = {...shell.reachable};
  final url = nexusLinkUrlOf(target);
  if (url != null) {
    if (conn.host == url && conn.status == RpcStatus.connected) {
      reachable.add(UtilityIds.nexuslink);
    } else if (conn.host == url) {
      // Connecting or dropped: the live connection is the better answer.
      reachable.remove(UtilityIds.nexuslink);
    }
  }
  return ModuleContext(
    target: target,
    capabilities: capabilitiesOf(target),
    reachable: reachable,
  );
});

/// The NexusLink connection is busy (re)connecting to the current target.
final nexusLinkConnectingProvider = Provider<bool>((ref) {
  final url = nexusLinkUrlOf(ref.watch(shellProvider).current);
  final conn = ref.watch(connectionProvider);
  return url != null &&
      conn.hostUrl == url &&
      conn.status == RpcStatus.connecting;
});

class ShellController extends Notifier<ShellState> {
  Future<void>? _loading;

  @override
  ShellState build() {
    ref.listen<bool>(connectionAuthRequiredProvider, (previous, next) {
      if (next && previous != true) {
        final host = ref.read(connectionProvider).hostUrl;
        // Only a saved target's own URL: a failed enrollment attempt against
        // a new PC must not flag the current one.
        final target = _targetForUrl(host);
        if (target != null) _flagPairAgain(target.id, UtilityIds.nexuslink);
      }
    });
    final signals = ModuleSignals.pairAgain.listen(
      (r) => _flagPairAgain(r.targetId, r.utility),
    );
    ref.onDispose(signals.cancel);
    return const ShellState();
  }

  /// Marks [utility] of [targetId] as refused. A different target replaces
  /// the old flag (the banner is only ever shown for the current target).
  void _flagPairAgain(String targetId, String utility) {
    if (!ref.mounted) return;
    if (!state.targets.any((t) => t.id == targetId)) return;
    final same = state.pairAgainTargetId == targetId;
    state = state.copyWith(
      pairAgainTargetId: targetId,
      pairAgainUtilities: {if (same) ...state.pairAgainUtilities, utility},
    );
  }

  /// [utility] of [targetId] works again; clears the flag once none is left.
  void _clearPairAgain(String targetId, String utility) {
    if (state.pairAgainTargetId != targetId) return;
    final left = {...state.pairAgainUtilities}..remove(utility);
    state = left.isEmpty
        ? state.copyWith(clearPairAgain: true)
        : state.copyWith(pairAgainUtilities: left);
  }

  ReachabilityProber get _prober => ref.read(reachabilityProberProvider);
  List<NexusModule> get _modules => ref.read(moduleListProvider);
  ConnectionNotifier get _connection => ref.read(connectionProvider.notifier);

  SavedTarget? _targetForUrl(String? wsUrl) {
    if (wsUrl == null) return null;
    final url = normalizeHostWsUrl(wsUrl);
    return state.targets.where((t) => nexusLinkUrlOf(t) == url).firstOrNull;
  }

  SavedTarget? targetForUrl(String? wsUrl) => _targetForUrl(wsUrl);

  /// Loads saved targets (migrating legacy devices once). Safe to call twice.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final targets = await TargetStore.load();
      var currentId = await TargetStore.currentId();
      if (!targets.any((t) => t.id == currentId)) currentId = null;
      state = state.copyWith(
        loaded: true,
        targets: targets,
        currentId: currentId,
        clearCurrent: currentId == null,
        clearError: true,
      );
      final ctx = _contextFor(state.current);
      if (ctx != null) await _notifyModules(null, ctx);
      unawaited(probe());
    } catch (error) {
      state = state.copyWith(
        loaded: true,
        error: 'Could not load saved devices: $error',
      );
    }
  }

  /// Re-reads targets from the store (after the pairing flow wrote one).
  Future<void> reload() async {
    final targets = await TargetStore.load();
    final currentId = await TargetStore.currentId();
    state = state.copyWith(
      targets: targets,
      currentId: targets.any((t) => t.id == currentId) ? currentId : null,
      clearCurrent: !targets.any((t) => t.id == currentId),
    );
  }

  /// Cold start: reconnect NexusLink to the current target when the old
  /// rules allow it. Returns the target it dialed, if any.
  Future<SavedTarget?> autoConnect() async {
    await load();
    final decision = await decideTargetAutoConnect(
      targets: state.targets,
      currentId: state.currentId,
      userDisconnected: _connection.userDisconnected,
      alreadyAttempted: _autoConnectAttempted,
      hasCredential: ref.read(nexusLinkCredentialCheckProvider),
    );
    _autoConnectAttempted = true;
    final target = decision.target;
    if (target == null) return null;
    try {
      await _connection.connect(nexusLinkUrlOf(target)!);
    } catch (_) {
      // The connection state carries lastError / authRequired for the UI.
    }
    return target;
  }

  /// Makes [targetId] current. With [connect], starts the shared NexusLink
  /// connection if the target has it (errors are left in the connection
  /// state, not thrown).
  Future<void> select(String targetId, {bool connect = true}) async {
    await load();
    final previous = state.current;
    final next = state.targets.where((t) => t.id == targetId).firstOrNull;
    if (next == null) return;
    if (previous?.id != next.id) {
      _prober.forget(next.id);
      state = state.copyWith(
        currentId: next.id,
        reachable: const {},
        probedOnce: false,
        clearError: true,
      );
      await TargetStore.setCurrent(next.id);
      await _notifyModules(_contextFor(previous), _contextFor(next));
    }
    final url = nexusLinkUrlOf(next);
    final conn = ref.read(connectionProvider);
    if (url == null) {
      if (conn.hostUrl != null) _connection.disconnect();
    } else if (connect &&
        (conn.hostUrl != url || conn.status != RpcStatus.connected)) {
      unawaited(connectCurrent().catchError((_) {}));
    } else if (conn.hostUrl != null && conn.hostUrl != url) {
      _connection.disconnect();
    }
    unawaited(probe(force: previous?.id != next.id));
  }

  /// Dials NexusLink on the current target. Throws on failure.
  Future<void> connectCurrent({String? pairingCode}) async {
    final url = nexusLinkUrlOf(state.current);
    if (url == null) return;
    await _connection.connect(url, pairingCode: pairingCode);
    final id = state.currentId;
    if (id != null) _clearPairAgain(id, UtilityIds.nexuslink);
  }

  void dismissPairAgain() => state = state.copyWith(clearPairAgain: true);

  /// Probes the current target's utilities (throttled per utility).
  Future<void> probe({bool force = false}) async {
    final target = state.current;
    if (target == null || target.utilities.isEmpty) return;
    state = state.copyWith(probing: true);
    Set<String> ok;
    try {
      ok = await _prober.probeAll(target, force: force);
    } catch (_) {
      ok = const {};
    }
    if (!ref.mounted || state.currentId != target.id) return;
    state = state.copyWith(reachable: ok, probing: false, probedOnce: true);
  }

  /// Adds (or reconnects) a PC by its NexusLink address, as the typed
  /// fallback and Wi-Fi discovery always did. Throws when the connect fails.
  Future<SavedTarget> addNexusLink(
    String wsUrl, {
    String? pairingCode,
    String? name,
    String? icon,
  }) async {
    await load();
    final url = normalizeHostWsUrl(wsUrl);
    final code = pairingCode?.replaceAll(RegExp(r'\D'), '');
    await _connection.connect(
      url,
      pairingCode: code == null || code.isEmpty ? null : code,
    );
    final existing = _targetForUrl(url);
    SavedTarget target;
    if (existing != null) {
      target = icon == null ? existing : existing.copyWith(icon: icon);
      await _replace(target);
    } else {
      final uri = Uri.tryParse(url);
      final trimmed = name?.trim() ?? '';
      target = await TargetStore.upsert(
        SavedTarget(
          id: '$legacyTargetPrefix$url',
          name: trimmed.isNotEmpty
              ? trimmed
              : 'My PC ${state.targets.length + 1}',
          icon: icon ?? 'desktop',
          utilities: {
            UtilityIds.nexuslink: UtilityLink(
              utility: UtilityIds.nexuslink,
              port: uri != null && uri.hasPort ? uri.port : defaultRpcPort,
              wsUrl: url,
              preferredHost: uri?.host,
              pairedAt: DateTime.now(),
            ),
          },
        ),
      );
      await reload();
    }
    _clearPairAgain(target.id, UtilityIds.nexuslink);
    await select(target.id, connect: false);
    return target;
  }

  /// After [PairingFlow] stored a target (and made it current in the store).
  Future<void> adoptPaired(SavedTarget target) async {
    await load();
    final before = state.current;
    final targets = await TargetStore.load();
    state = state.copyWith(
      targets: targets,
      clearPairAgain: state.pairAgainTargetId == target.id,
    );
    if (before != null && before.id == target.id) {
      // Re-paired (or added utilities to) the current target: modules must
      // drop old sessions and pick up new secrets and newly paired utilities.
      _prober.forget(target.id);
      await _notifyModules(_contextFor(before), _contextFor(state.current));
    }
    // select() tells modules about a switch and connects NexusLink if the
    // enroller didn't leave it connected.
    await select(target.id);
  }

  Future<void> rename(String targetId, {required String name, String? icon}) =>
      _update(targetId, (t) => t.copyWith(name: name, icon: icon));

  Future<void> setWake(String targetId, WakeConfig? wake) => _update(
    targetId,
    (t) => t.copyWith(wake: wake, clearWake: wake == null),
  );

  Future<void> remove(String targetId) async {
    final gone = state.targets.where((t) => t.id == targetId).firstOrNull;
    final wasCurrent = state.currentId == targetId;
    await TargetStore.remove(targetId);
    final url = nexusLinkUrlOf(gone);
    if (wasCurrent && url != null && ref.read(connectionProvider).hostUrl == url) {
      _connection.disconnect();
    }
    if (wasCurrent) await _notifyModules(_contextFor(gone), null);
    if (gone != null) {
      for (final m in _modules) {
        if (m is! TargetRemovalAware) continue;
        try {
          await (m as TargetRemovalAware).onTargetRemoved(gone);
        } catch (error) {
          debugPrint('Module ${m.id} target removal failed: $error');
        }
      }
    }
    _prober.forget(targetId);
    unawaited(
      ref
          .read(lastDestinationsProvider.notifier)
          .forget(targetId)
          .catchError((_) {}),
    );
    unawaited(
      ref.read(lastSeenProvider.notifier).forget(targetId).catchError((_) {}),
    );
    final targets = [
      for (final t in state.targets)
        if (t.id != targetId) t,
    ];
    state = state.copyWith(
      targets: targets,
      clearCurrent: wasCurrent,
      reachable: wasCurrent ? const {} : null,
      clearPairAgain: state.pairAgainTargetId == targetId,
    );
  }

  /// Leaves the current target (back to the device picker).
  Future<void> clearCurrent() async {
    final previous = state.current;
    await TargetStore.setCurrent(null);
    state = state.copyWith(clearCurrent: true, reachable: const {});
    if (previous != null) await _notifyModules(_contextFor(previous), null);
  }

  Future<void> _update(
    String targetId,
    SavedTarget Function(SavedTarget) change,
  ) async {
    final target = state.targets.where((t) => t.id == targetId).firstOrNull;
    if (target == null) return;
    await _replace(change(target));
  }

  /// Writes the whole list (upsert's merge would keep an old icon).
  Future<void> _replace(SavedTarget target) async {
    final fresh = await TargetStore.load();
    final targets = [
      for (final t in fresh) t.id == target.id ? target : t,
    ];
    await TargetStore.save(targets);
    state = state.copyWith(targets: targets);
  }

  ModuleContext? _contextFor(SavedTarget? target) => target == null
      ? null
      : ModuleContext(
          target: target,
          capabilities: capabilitiesOf(target),
          reachable: target.id == state.currentId ? state.reachable : const {},
        );

  Future<void> _notifyModules(ModuleContext? left, ModuleContext? entered) async {
    for (final m in _modules) {
      try {
        if (left != null && m.requires.isMetBy(left.capabilities)) {
          await m.onTargetChanged(null);
        }
        if (entered != null && m.requires.isMetBy(entered.capabilities)) {
          await m.onTargetChanged(entered);
        }
      } catch (error) {
        debugPrint('Module ${m.id} target change failed: $error');
      }
    }
  }
}
