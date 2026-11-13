// Enrolls every utility of a scanned (or typed) bundle on its own, stores the
// secrets in the vault and saves ONE target. NXU1 text and tokens are never
// logged, copied or put in a URL.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/pair_bundle.dart';
import '../../screens/scan_pair_screen.dart';
import '../store.dart';
import '../target.dart';
import 'enrollers.dart';
import 'manual_pair_screen.dart';
import 'pairing_progress_screen.dart';

enum EnrollState { pending, working, done, failed, skipped }

class EnrollProgress {
  const EnrollProgress(this.utility, this.state, [this.message]);
  final String utility;
  final EnrollState state;
  final String? message;
}

/// NexusLink pairs through the app's existing connection (RpcClient pairing
/// handshake), so the shell injects it: it must connect with the code and
/// leave the credential stored.
typedef NexusLinkEnroller = Future<void> Function(String wsUrl, String code);

const _defaultDeviceName = 'Android phone';

String _cleanError(Object e) {
  if (e is EnrollException) return e.message;
  final s = e.toString();
  final stripped = s.replaceFirst(
    RegExp(r'^(Exception|StateError|Bad state): '),
    '',
  );
  return stripped.isEmpty ? 'Pairing failed.' : stripped;
}

/// One enrollment run over a bundle. Drives the progress screen (which can
/// [retry] a failed utility) and backs [PairingFlow.enrollAll].
class PairingRun extends ChangeNotifier {
  PairingRun(
    this.bundle, {
    required this.enrollNexusLink,
    this.deviceName = _defaultDeviceName,
    this.onProgress,
  }) {
    for (final u in UtilityIds.all) {
      if (bundle.utilities.containsKey(u)) {
        _progress[u] = EnrollProgress(u, EnrollState.pending);
      }
    }
  }

  final PairBundle bundle;
  final NexusLinkEnroller enrollNexusLink;
  final String deviceName;
  final void Function(EnrollProgress)? onProgress;

  final Map<String, EnrollProgress> _progress = {};
  final Map<String, UtilityLink> _links = {};
  SavedTarget? _target;

  /// Rows in display order.
  List<EnrollProgress> get rows => _progress.values.toList();
  SavedTarget? get target => _target;
  bool get busy => _progress.values.any(
    (p) => p.state == EnrollState.working || p.state == EnrollState.pending,
  );
  bool get allDone =>
      _progress.values.every((p) => p.state == EnrollState.done);

  void _set(String u, EnrollState s, [String? message]) {
    final p = EnrollProgress(u, s, message);
    _progress[u] = p;
    onProgress?.call(p);
    notifyListeners();
  }

  /// Enrolls everything in parallel; one failure never blocks the others.
  Future<void> start() =>
      Future.wait([for (final u in _progress.keys.toList()) retry(u)]);

  Future<void> retry(String utility) async {
    final entry = bundle.utilities[utility];
    if (entry == null) return;
    final cur = _progress[utility]?.state;
    if (cur == EnrollState.working || cur == EnrollState.done) return;
    _set(utility, EnrollState.working);
    try {
      _links[utility] = await _enrollOne(entry);
      await _persist();
      _set(utility, EnrollState.done);
    } catch (e) {
      _set(utility, EnrollState.failed, _cleanError(e));
    }
  }

  Future<UtilityLink> _enrollOne(BundleEntry entry) async {
    final addresses = bundle.addresses.ordered;
    switch (entry.utility) {
      case UtilityIds.nexuslink:
        Object? last;
        for (final a in addresses) {
          final wsUrl = 'ws://${hostForUrl(a)}:${entry.port}/rpc';
          try {
            await enrollNexusLink(wsUrl, entry.code);
            return UtilityLink(
              utility: UtilityIds.nexuslink,
              port: entry.port,
              hostId: entry.hostId,
              preferredHost: a,
              wsUrl: wsUrl,
              pairedAt: DateTime.now(),
            );
          } catch (e) {
            last = e;
          }
        }
        throw last ?? const EnrollException('No network address to try.');
      case UtilityIds.remote:
        final r = await RemoteEnroller.enroll(
          addresses: addresses,
          port: entry.port,
          code: entry.code,
          fingerprint: entry.fingerprint,
          deviceName: deviceName,
        );
        await CredentialVault.write(bundle.hubId, UtilityIds.remote, r.token);
        return UtilityLink(
          utility: UtilityIds.remote,
          port: entry.port,
          hostId: r.hostId,
          fingerprint: r.fingerprint,
          preferredHost: r.address,
          pairedAt: DateTime.now(),
        );
      case UtilityIds.audio:
        final r = await AudioEnroller.enroll(
          addresses: addresses,
          port: entry.port,
          code: entry.code,
          fingerprint: entry.fingerprint,
          deviceName: deviceName,
        );
        await CredentialVault.write(bundle.hubId, UtilityIds.audio, r.token);
        return UtilityLink(
          utility: UtilityIds.audio,
          port: entry.port,
          hostId: entry.hostId,
          fingerprint: r.fingerprint,
          deviceId: r.deviceId,
          preferredHost: r.address,
          pairedAt: DateTime.now(),
        );
    }
    throw EnrollException('Unknown utility "${entry.utility}".');
  }

  Future<void> _persist() async {
    final t = await TargetStore.upsert(
      SavedTarget(
        id: bundle.hubId,
        name: bundle.pcName,
        addresses: bundle.addresses,
        utilities: Map.of(_links),
      ),
    );
    _target = t;
    await TargetStore.setCurrent(t.id);
  }
}

class PairingFlow {
  /// Enrolls every utility in [bundle] (addresses in order: ts, then lan), each
  /// independently. Stores secrets in the vault, upserts ONE SavedTarget
  /// (id = bundle.hubId) and makes it current. Returns null only when nothing
  /// enrolled.
  static Future<SavedTarget?> enrollAll(
    PairBundle bundle, {
    required NexusLinkEnroller enrollNexusLink,
    String deviceName = _defaultDeviceName,
    void Function(EnrollProgress)? onProgress,
  }) async {
    final run = PairingRun(
      bundle,
      enrollNexusLink: enrollNexusLink,
      deviceName: deviceName,
      onProgress: onProgress,
    );
    await run.start();
    return run.target;
  }

  /// UI: scan → progress list (one row per utility, retry button on failed
  /// rows) → pop with the target. "Type it instead" opens manual entry.
  static Future<SavedTarget?> run(
    BuildContext context, {
    required NexusLinkEnroller enrollNexusLink,
  }) async {
    final nav = Navigator.of(context);
    final scanned = await nav.push<Object>(
      MaterialPageRoute(
        builder: (_) => const ScanPairScreen(returnBundle: true),
      ),
    );
    PairBundle? bundle;
    if (scanned is PairBundle) {
      bundle = scanned;
    } else if (scanned == ScanChoice.manual) {
      if (!nav.mounted) return null;
      bundle = await nav.push<PairBundle>(
        MaterialPageRoute(builder: (_) => const ManualPairScreen()),
      );
    }
    if (bundle == null || !nav.mounted) return null;
    return nav.push<SavedTarget>(
      MaterialPageRoute(
        builder: (_) => PairingProgressScreen(
          run: PairingRun(bundle!, enrollNexusLink: enrollNexusLink),
        ),
      ),
    );
  }
}
