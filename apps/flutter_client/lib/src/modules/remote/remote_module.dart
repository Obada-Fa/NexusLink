import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nexus_remote/nexus_remote.dart';

import '../../session/target.dart';
import '../../shell/module.dart';
import '../../shell/module_extras.dart';
import '../../shell/module_signals.dart';
import '../../shell/shell_navigator.dart';
import '../../shell/target_actions.dart';
import '../../theme/nexus_theme.dart';

/// Builds a [RemoteSession]; tests swap it for a fake.
typedef RemoteSessionFactory =
    RemoteSession Function(RemoteEndpoint endpoint, VoidCallback onUnauthorized);

/// Adapter that turns the `nexus_remote` package into a shell module.
///
/// The module object is const, so the one live [RemoteSession] per target is
/// kept in [RemoteRuntime] (created in [onTargetChanged], disposed when the
/// target is left).
class RemoteModule extends NexusModule
    implements DescribedModule, BlockableModule {
  const RemoteModule();

  @override
  String get id => 'remote';

  @override
  String get title => 'Remote';

  @override
  String get subtitle => 'Trackpad · Keyboard · Dictation';

  @override
  Color get accent => NX.waiting;

  @override
  IconData get icon => Icons.touch_app;

  @override
  int get order => 40;

  @override
  CapabilityRequirement get requires =>
      const CapabilityRequirement.anyOf(['input', 'dictation']);

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) =>
      _RemoteEntry(targetId: ctx.target.id);

  @override
  Stream<List<LiveActivity>>? liveActivities(ModuleContext ctx) =>
      RemoteRuntime.activities;

  @override
  Listenable get blockedChanges => RemoteRuntime.blocked;

  @override
  String? blockedReason(ModuleContext ctx) =>
      RemoteRuntime.blockedFor(ctx.target.id);

  @override
  Future<void> onTargetChanged(ModuleContext? ctx) async {
    await RemoteRuntime.switchTo(ctx);
  }
}

/// Builds the endpoint for the `remote` link of [target], or null when the
/// target has no remote link, no fingerprint, no token or no address.
RemoteEndpoint? buildRemoteEndpoint(SavedTarget target, String? token) {
  final link = target.utilities[UtilityIds.remote];
  final fingerprint = link?.fingerprint;
  if (link == null ||
      fingerprint == null ||
      fingerprint.isEmpty ||
      token == null ||
      token.isEmpty) {
    return null;
  }
  final hosts = <String>[
    if (link.preferredHost != null && link.preferredHost!.isNotEmpty)
      link.preferredHost!,
    ...target.addresses.ordered,
  ];
  final seen = <String>{};
  final unique = <String>[
    for (final h in hosts)
      if (seen.add(h)) h,
  ];
  if (unique.isEmpty) return null;
  return RemoteEndpoint(
    hosts: unique,
    port: link.port,
    fingerprint: fingerprint,
    hostId: link.hostId ?? target.id,
    token: token,
    pcName: target.name,
  );
}

/// Why [buildRemoteEndpoint] returned null, in plain words.
String remoteMissingReason(SavedTarget target, String? token) {
  final link = target.utilities[UtilityIds.remote];
  if (token == null || token.isEmpty) {
    return 'This phone has lost its Remote key for ${target.name}. Pair again.';
  }
  if (link?.fingerprint == null || link!.fingerprint!.isEmpty) {
    return 'The Remote pairing for ${target.name} is incomplete. Pair again.';
  }
  return 'No address is saved for ${target.name}. Pair again.';
}

/// The one Remote session for the current target. Static because the module
/// is const.
abstract final class RemoteRuntime {
  static final ValueNotifier<RemoteSession?> session = ValueNotifier(null);
  static final ValueNotifier<bool> unauthorized = ValueNotifier(false);

  /// Target id → why Remote can't start there (missing token...).
  static final ValueNotifier<Map<String, String>> blocked = ValueNotifier(
    const {},
  );
  static final StreamController<List<LiveActivity>> _activities =
      StreamController.broadcast();
  static List<LiveActivity> _current = const [];
  static String? _targetId;
  static bool _wasConnected = false;

  @visibleForTesting
  static RemoteSessionFactory? debugSessionFactory;

  /// Live activities, starting with the current list for each listener.
  static Stream<List<LiveActivity>> get activities => Stream.multi((c) {
    c.add(_current);
    final sub = _activities.stream.listen(c.add);
    c.onCancel = sub.cancel;
  });

  static String? blockedFor(String targetId) => blocked.value[targetId];

  static Future<void> switchTo(ModuleContext? ctx) async {
    if (ctx != null && ctx.target.id == _targetId && session.value != null) {
      return;
    }
    _dispose();
    _targetId = ctx?.target.id;
    if (ctx == null) return;
    final target = ctx.target;
    final token = await ctx.secret(UtilityIds.remote);
    if (_targetId != target.id) return;
    final endpoint = buildRemoteEndpoint(target, token);
    if (endpoint == null) {
      _setBlocked(target.id, remoteMissingReason(target, token));
      return;
    }
    _setBlocked(target.id, null);
    void onUnauthorized() {
      unauthorized.value = true;
      ModuleSignals.requestPairAgain(target.id, UtilityIds.remote);
    }

    final created =
        debugSessionFactory?.call(endpoint, onUnauthorized) ??
        RemoteSession(endpoint, onUnauthorized: onUnauthorized);
    created.addListener(() => _publish(created));
    session.value = created;
    _publish(created);
    unawaited(created.initialize().catchError((Object e) {
      debugPrint('Remote session failed to start: $e');
    }));
  }

  static void _setBlocked(String targetId, String? reason) {
    final next = {...blocked.value};
    if (reason == null) {
      if (!next.containsKey(targetId)) return;
      next.remove(targetId);
    } else {
      if (next[targetId] == reason) return;
      next[targetId] = reason;
    }
    blocked.value = next;
  }

  static void _emit(List<LiveActivity> list) {
    _current = list;
    _activities.add(list);
  }

  static void _publish(RemoteSession s) {
    if (s.connected == _wasConnected) return;
    _wasConnected = s.connected;
    _emit(
      s.connected
          ? [
              LiveActivity(
                moduleId: 'remote',
                label: 'Remote: ${s.endpoint.pcName}',
                icon: Icons.touch_app,
                onTap: () => ShellNavigator.instance.openModule('remote'),
                onStop: () => unawaited(s.disconnect()),
              ),
            ]
          : const [],
    );
  }

  static void _dispose() {
    final old = session.value;
    session.value = null;
    unauthorized.value = false;
    if (_wasConnected || _current.isNotEmpty) _emit(const []);
    _wasConnected = false;
    old?.dispose();
  }

  @visibleForTesting
  static void debugReset() {
    _dispose();
    _targetId = null;
    blocked.value = const {};
  }
}

class _RemoteEntry extends ConsumerWidget {
  const _RemoteEntry({required this.targetId});
  final String targetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<RemoteSession?>(
      valueListenable: RemoteRuntime.session,
      builder: (context, session, _) {
        if (session == null) {
          final reason =
              RemoteRuntime.blockedFor(targetId) ??
              'Remote is not paired with this PC.';
          return Scaffold(
            appBar: AppBar(title: const Text('Remote')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      reason,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: NX.textDim),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => startPairing(context, ref),
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text('Scan QR to pair again'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: RemoteRuntime.unauthorized,
          builder: (context, revoked, _) => Column(
            children: [
              if (revoked)
                MaterialBanner(
                  content: const Text(
                    'This PC no longer accepts this phone. Pair it again.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => startPairing(context, ref),
                      child: const Text('Scan QR'),
                    ),
                  ],
                ),
              Expanded(child: RemoteHomeScreen(session: session)),
            ],
          ),
        );
      },
    );
  }
}
