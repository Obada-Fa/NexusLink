import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_remote/nexus_remote.dart';

import '../../session/target.dart';
import '../../shell/module.dart';

/// Adapter that turns the `nexus_remote` package into a shell module.
///
/// The module object is const, so the one live [RemoteSession] per target is
/// kept in [_RemoteRuntime] (created in [onTargetChanged], disposed when the
/// target is left).
class RemoteModule extends NexusModule {
  const RemoteModule();

  @override
  String get id => 'remote';

  @override
  String get title => 'Remote';

  @override
  IconData get icon => Icons.touch_app;

  @override
  int get order => 40;

  @override
  CapabilityRequirement get requires => const CapabilityRequirement.anyOf(['input', 'dictation']);

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) => _RemoteEntry(targetId: ctx.target.id);

  @override
  Stream<List<LiveActivity>>? liveActivities(ModuleContext ctx) => _RemoteRuntime.activities.stream;

  @override
  Future<void> onTargetChanged(ModuleContext? ctx) async {
    await _RemoteRuntime.switchTo(ctx);
  }
}

/// Builds the endpoint for the `remote` link of [target], or null when the
/// target has no remote link, no fingerprint, no token or no address.
RemoteEndpoint? buildRemoteEndpoint(SavedTarget target, String? token) {
  final link = target.utilities[UtilityIds.remote];
  final fingerprint = link?.fingerprint;
  if (link == null || fingerprint == null || fingerprint.isEmpty || token == null || token.isEmpty) {
    return null;
  }
  final hosts = <String>[
    if (link.preferredHost != null && link.preferredHost!.isNotEmpty) link.preferredHost!,
    ...target.addresses.ordered,
  ];
  final unique = <String>[
    for (final h in hosts)
      if (!hosts.take(hosts.indexOf(h)).contains(h)) h,
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

class _RemoteRuntime {
  static final ValueNotifier<RemoteSession?> session = ValueNotifier(null);
  static final ValueNotifier<bool> unauthorized = ValueNotifier(false);
  static final StreamController<List<LiveActivity>> activities = StreamController.broadcast();
  static String? _targetId;
  static bool _wasConnected = false;

  static Future<void> switchTo(ModuleContext? ctx) async {
    if (ctx != null && ctx.target.id == _targetId && session.value != null) return;
    _dispose();
    _targetId = ctx?.target.id;
    if (ctx == null) return;
    final endpoint = buildRemoteEndpoint(ctx.target, await ctx.secret(UtilityIds.remote));
    if (endpoint == null || _targetId != ctx.target.id) return;
    final created = RemoteSession(endpoint, onUnauthorized: () => unauthorized.value = true);
    created.addListener(() => _publish(created, ctx));
    session.value = created;
    unawaited(created.initialize());
  }

  static void _publish(RemoteSession s, ModuleContext ctx) {
    if (s.connected == _wasConnected) return;
    _wasConnected = s.connected;
    activities.add(s.connected
        ? [
            LiveActivity(
              moduleId: 'remote',
              label: 'Remote: ${s.endpoint.pcName}',
              icon: Icons.touch_app,
              onStop: () => unawaited(s.disconnect()),
            ),
          ]
        : const []);
  }

  static void _dispose() {
    final old = session.value;
    session.value = null;
    unauthorized.value = false;
    if (_wasConnected) activities.add(const []);
    _wasConnected = false;
    old?.dispose();
  }
}

class _RemoteEntry extends StatelessWidget {
  const _RemoteEntry({required this.targetId});
  final String targetId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RemoteSession?>(
      valueListenable: _RemoteRuntime.session,
      builder: (context, session, _) {
        if (session == null) {
          return const Scaffold(body: Center(child: Text('Remote is not paired with this PC.')));
        }
        return ValueListenableBuilder<bool>(
          valueListenable: _RemoteRuntime.unauthorized,
          builder: (context, revoked, _) => Column(
            children: [
              if (revoked)
                MaterialBanner(
                  content: const Text('This PC no longer accepts this phone. Pair it again.'),
                  actions: [TextButton(onPressed: () => Navigator.maybePop(context), child: const Text('Back'))],
                ),
              Expanded(child: RemoteHomeScreen(session: session)),
            ],
          ),
        );
      },
    );
  }
}
