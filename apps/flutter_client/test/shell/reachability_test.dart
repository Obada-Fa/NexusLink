import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/reachability.dart';

import 'fakes.dart';

void main() {
  test('tries the enrollment address, then Tailscale, then LAN', () async {
    final tried = <String>[];
    final prober = ReachabilityProber(
      connect: (host, port, _) async {
        tried.add('$host:$port');
        return host == '192.168.1.20';
      },
    );
    final t = SavedTarget(
      id: 'hub',
      name: 'PC',
      addresses: const TargetAddresses(
        tailscale: '100.64.0.5',
        lan: ['192.168.1.20'],
      ),
      utilities: {
        UtilityIds.remote: link(UtilityIds.remote, host: '10.0.0.9'),
      },
    );
    expect(await prober.probe(t, UtilityIds.remote), isTrue);
    expect(tried, [
      '10.0.0.9:45679',
      '100.64.0.5:45679',
      '192.168.1.20:45679',
    ]);
  });

  test('NexusLink probes the ws URL host and port', () async {
    final tried = <String>[];
    final prober = ReachabilityProber(
      connect: (host, port, _) async {
        tried.add('$host:$port');
        return false;
      },
    );
    final t = SavedTarget(
      id: 'legacy:ws://pc:4000/rpc',
      name: 'PC',
      utilities: {
        UtilityIds.nexuslink: link(
          UtilityIds.nexuslink,
          wsUrl: 'ws://pc:4000/rpc',
        ),
      },
    );
    expect(await prober.probe(t, UtilityIds.nexuslink), isFalse);
    expect(tried, ['pc:4000']);
  });

  test('at most one probe per utility every 10 s', () async {
    var now = DateTime(2026, 11, 8, 12);
    var calls = 0;
    final prober = ReachabilityProber(
      clock: () => now,
      connect: (_, _, _) async {
        calls++;
        return true;
      },
    );
    final t = hubTarget(utilities: {UtilityIds.audio});
    expect(await prober.probeAll(t), {UtilityIds.audio});
    expect(calls, 1);
    now = now.add(const Duration(seconds: 5));
    await prober.probeAll(t);
    expect(calls, 1);
    await prober.probeAll(t, force: true);
    expect(calls, 2);
    now = now.add(const Duration(seconds: 11));
    await prober.probeAll(t);
    expect(calls, 3);
  });

  test('concurrent probes share one attempt; unpaired is unreachable', () async {
    var calls = 0;
    final prober = ReachabilityProber(
      connect: (_, _, _) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return true;
      },
    );
    final t = hubTarget(utilities: {UtilityIds.remote});
    final results = await Future.wait([
      prober.probe(t, UtilityIds.remote),
      prober.probe(t, UtilityIds.remote),
    ]);
    expect(results, [true, true]);
    expect(calls, 1);
    expect(await prober.probe(t, UtilityIds.audio), isFalse);
  });
}
