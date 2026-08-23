import 'package:flutter_riverpod/flutter_riverpod.dart';

class TerminalBusyNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void setBusy(String sessionId, bool busy) {
    if (state[sessionId] == busy) return;
    state = {...state, sessionId: busy};
  }

  void remove(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    final next = Map<String, bool>.from(state)..remove(sessionId);
    state = next;
  }

  bool isBusy(String sessionId) => state[sessionId] ?? false;
}

final terminalBusyProvider =
    NotifierProvider<TerminalBusyNotifier, Map<String, bool>>(
  TerminalBusyNotifier.new,
);
