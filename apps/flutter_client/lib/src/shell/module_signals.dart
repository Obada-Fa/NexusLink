// Lets modules (const objects with no Riverpod ref) tell the shell things:
// today only "this PC refused our pairing, offer Pair again".

import 'dart:async';

/// A module's utility on [targetId] was refused (token revoked or the PC
/// was re-enrolled).
class PairAgainRequest {
  const PairAgainRequest({
    required this.targetId,
    required this.utility,
    this.message,
  });
  final String targetId;
  final String utility; // UtilityIds.*
  final String? message;

  @override
  String toString() => 'PairAgainRequest($targetId, $utility)';
}

abstract final class ModuleSignals {
  static final _pairAgain = StreamController<PairAgainRequest>.broadcast();

  /// The shell controller listens; the home shows the pair-again banner.
  static Stream<PairAgainRequest> get pairAgain => _pairAgain.stream;

  static void requestPairAgain(
    String targetId,
    String utility, {
    String? message,
  }) => _pairAgain.add(
    PairAgainRequest(targetId: targetId, utility: utility, message: message),
  );
}
