import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/modules/remote/remote_module.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/capabilities.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_signals.dart';

import '../shell/fakes.dart';

ModuleContext ctxOf(SavedTarget t) => ModuleContext(
  target: t,
  capabilities: capabilitiesOf(t),
  reachable: const {UtilityIds.remote},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final office = hubTarget();
  late List<FakeRemoteSession> sessions;

  setUp(() async {
    sessions = [];
    RemoteRuntime.debugReset();
    RemoteRuntime.debugSessionFactory = (endpoint, onUnauthorized) {
      final s = FakeRemoteSession(endpoint, onUnauthorized: onUnauthorized);
      sessions.add(s);
      return s;
    };
    await CredentialVault.write(office.id, UtilityIds.remote, 'r-token');
  });

  tearDown(() async {
    RemoteRuntime.debugReset();
    RemoteRuntime.debugSessionFactory = null;
    await CredentialVault.delete(office.id, UtilityIds.remote);
  });

  test('endpoint: preferred host first, de-duplicated; null without token', () {
    final e = buildRemoteEndpoint(office, 'tok')!;
    expect(e.hosts, ['100.64.0.5', '192.168.1.20']);
    expect(e.port, 45679);
    expect(e.fingerprint, testFingerprint);
    expect(e.pcName, 'Office PC');
    expect(buildRemoteEndpoint(office, null), isNull);
    expect(buildRemoteEndpoint(office, ''), isNull);
  });

  test('missing token: blocked with a reason, no session', () async {
    await CredentialVault.delete(office.id, UtilityIds.remote);
    const module = RemoteModule();
    await module.onTargetChanged(ctxOf(office));
    expect(sessions, isEmpty);
    expect(module.blockedReason(ctxOf(office)), contains('lost its Remote key'));
  });

  test('a revoked token asks the shell to pair again', () async {
    final requests = <PairAgainRequest>[];
    final sub = ModuleSignals.pairAgain.listen(requests.add);
    await RemoteRuntime.switchTo(ctxOf(office));
    expect(sessions, hasLength(1));
    expect(const RemoteModule().blockedReason(ctxOf(office)), isNull);
    sessions.single.onUnauthorized!();
    await Future<void>.delayed(Duration.zero);
    expect(requests.single.targetId, office.id);
    expect(requests.single.utility, UtilityIds.remote);
    expect(RemoteRuntime.unauthorized.value, isTrue);
    await sub.cancel();
  });

  test('live activity while connected, replayed to late listeners', () async {
    await RemoteRuntime.switchTo(ctxOf(office));
    await Future<void>.delayed(Duration.zero);
    final seen = <List<LiveActivity>>[];
    final sub = const RemoteModule()
        .liveActivities(ctxOf(office))!
        .listen(seen.add);
    await Future<void>.delayed(Duration.zero);
    expect(seen.last.single.label, 'Remote: Office PC');
    seen.last.single.onStop!();
    await Future<void>.delayed(Duration.zero);
    expect(sessions.single.disconnects, 1);
    expect(seen.last, isEmpty);
    await sub.cancel();
  });

  test('leaving the target disposes the session', () async {
    await RemoteRuntime.switchTo(ctxOf(office));
    expect(RemoteRuntime.session.value, isNotNull);
    await RemoteRuntime.switchTo(null);
    expect(RemoteRuntime.session.value, isNull);
  });
}
