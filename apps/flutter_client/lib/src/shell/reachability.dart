// Reachability per utility (spec §3.3): a TCP connect to the utility's port,
// trying the address that answered at enrollment first, then Tailscale, then
// LAN. At most one probe per utility every 10 s.

import 'dart:async';
import 'dart:io';

import '../session/target.dart';
import 'capabilities.dart';

typedef TcpConnector =
    Future<bool> Function(String host, int port, Duration timeout);

Future<bool> defaultTcpConnector(
  String host,
  int port,
  Duration timeout,
) async {
  // Widget tests run in a fake-async zone where real sockets never finish.
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Hosts to try for [link] on [target], in order, de-duplicated.
List<String> probeHosts(SavedTarget target, UtilityLink link) {
  final out = <String>[];
  void add(String? h) {
    if (h != null && h.isNotEmpty && !out.contains(h)) out.add(h);
  }

  final ws = link.wsUrl == null ? null : Uri.tryParse(link.wsUrl!);
  add(link.preferredHost);
  add(ws?.host);
  for (final h in target.addresses.ordered) {
    add(h);
  }
  return out;
}

int probePort(UtilityLink link) {
  final ws = link.wsUrl == null ? null : Uri.tryParse(link.wsUrl!);
  if (ws != null && ws.hasPort) return ws.port;
  if (link.port > 0) return link.port;
  return utilityDefaultPorts[link.utility] ?? 0;
}

class ReachabilityProber {
  ReachabilityProber({
    TcpConnector? connect,
    this.minInterval = const Duration(seconds: 10),
    this.timeout = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _connect = connect ?? defaultTcpConnector,
       _clock = clock ?? DateTime.now;

  final TcpConnector _connect;
  final Duration minInterval;
  final Duration timeout;
  final DateTime Function() _clock;

  final _last = <String, ({DateTime at, bool ok})>{};
  final _inFlight = <String, Future<bool>>{};

  /// Probes [utility] on [target]; reuses the last answer for [minInterval].
  Future<bool> probe(SavedTarget target, String utility, {bool force = false}) {
    final link = target.utilities[utility];
    if (link == null) return Future.value(false);
    final key = '${target.id}/$utility';
    final running = _inFlight[key];
    if (running != null) return running;
    final last = _last[key];
    if (!force &&
        last != null &&
        _clock().difference(last.at) < minInterval) {
      return Future.value(last.ok);
    }
    final run = _probeHosts(probeHosts(target, link), probePort(link));
    _inFlight[key] = run;
    return run.then((ok) {
      _last[key] = (at: _clock(), ok: ok);
      return ok;
    }).whenComplete(() => _inFlight.remove(key));
  }

  /// Probes every paired utility (or just [only]); returns those that answered.
  Future<Set<String>> probeAll(
    SavedTarget target, {
    Iterable<String>? only,
    bool force = false,
  }) async {
    final utilities = (only ?? target.utilities.keys).toList();
    final results = await Future.wait([
      for (final u in utilities) probe(target, u, force: force),
    ]);
    return {
      for (var i = 0; i < utilities.length; i++)
        if (results[i]) utilities[i],
    };
  }

  /// Last known answer without probing.
  bool? lastResult(String targetId, String utility) =>
      _last['$targetId/$utility']?.ok;

  void forget(String targetId) =>
      _last.removeWhere((k, _) => k.startsWith('$targetId/'));

  Future<bool> _probeHosts(List<String> hosts, int port) async {
    if (port <= 0) return false;
    for (final h in hosts) {
      if (await _connect(h, port, timeout)) return true;
    }
    return false;
  }
}
