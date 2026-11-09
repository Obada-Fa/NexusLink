// Test doubles for shell tests.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_remote/nexus_remote.dart';
import 'package:nexuslink/src/modules/agents/agents_module.dart';
import 'package:nexuslink/src/modules/desktop/desktop_module.dart';
import 'package:nexuslink/src/modules/files/files_module.dart';
import 'package:nexuslink/src/modules/terminal/terminal_module.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_extras.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';

/// The NexusLink modules only (the registry without Remote and Audio).
const nexusLinkModules = <NexusModule>[
  DesktopModule(),
  FilesModule(),
  AgentsModule(),
  TerminalModule(),
];

const testFingerprint =
    'AB12CD34EF56AB12CD34EF56AB12CD34EF56AB12CD34EF56AB12CD34EF56AB12';

/// A Remote session that never touches sqlite or the network.
class FakeRemoteSession extends RemoteSession {
  FakeRemoteSession(super.endpoint, {super.onUnauthorized, this.connectOnInit = true});
  final bool connectOnInit;
  int disconnects = 0;

  @override
  Future<void> initialize() async {
    if (!connectOnInit) return;
    connected = true;
    status = 'Connected';
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    connected = false;
    notifyListeners();
  }
}

/// A configurable module, e.g. a stand-in for wave 2's Remote.
class FakeModule extends NexusModule implements DescribedModule {
  FakeModule({
    required this.id,
    this.title = 'Fake',
    this.requiredCaps = const ['input'],
    this.platformSet = const {TargetPlatform.android},
    this.orderValue = 100,
    this.activities,
    this.subtitle = '',
    this.accent = NX.waiting,
    this.icon = Icons.touch_app_outlined,
  });

  @override
  final String id;
  @override
  final String title;
  final List<String> requiredCaps;
  final Set<TargetPlatform> platformSet;
  final int orderValue;
  final Stream<List<LiveActivity>>? activities;
  @override
  final String subtitle;
  @override
  final Color accent;
  @override
  final IconData icon;

  final changes = <String?>[];

  @override
  CapabilityRequirement get requires =>
      CapabilityRequirement.anyOf(requiredCaps);
  @override
  Set<TargetPlatform> get platforms => platformSet;
  @override
  int get order => orderValue;

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) =>
      Scaffold(body: Text('entry:$id'));

  @override
  Stream<List<LiveActivity>>? liveActivities(ModuleContext ctx) => activities;

  @override
  Future<void> onTargetChanged(ModuleContext? ctx) async =>
      changes.add(ctx?.target.id);
}

UtilityLink link(String utility, {String? wsUrl, String? host, int? port}) =>
    UtilityLink(
      utility: utility,
      port:
          port ??
          switch (utility) {
            UtilityIds.nexuslink => 45678,
            UtilityIds.remote => 45679,
            _ => 8010,
          },
      wsUrl: wsUrl,
      preferredHost: host,
      fingerprint: utility == UtilityIds.nexuslink ? null : testFingerprint,
      deviceId: utility == UtilityIds.audio ? 'phone-1' : null,
      pairedAt: DateTime.utc(2026, 11, 8),
    );

SavedTarget hubTarget({
  String id = 'hub-office',
  String name = 'Office PC',
  String icon = 'desktop',
  Set<String> utilities = const {
    UtilityIds.nexuslink,
    UtilityIds.remote,
    UtilityIds.audio,
  },
}) => SavedTarget(
  id: id,
  name: name,
  icon: icon,
  addresses: const TargetAddresses(
    tailscale: '100.64.0.5',
    lan: ['192.168.1.20'],
  ),
  utilities: {
    for (final u in utilities)
      u: link(
        u,
        wsUrl: u == UtilityIds.nexuslink ? 'ws://100.64.0.5:45678/rpc' : null,
        host: '100.64.0.5',
      ),
  },
);

/// A stream that emits [value] once and stays open.
Stream<List<LiveActivity>> liveOnce(List<LiveActivity> value) {
  final c = StreamController<List<LiveActivity>>();
  c.add(value);
  return c.stream;
}
