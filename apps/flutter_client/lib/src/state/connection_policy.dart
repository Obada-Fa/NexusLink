import '../rpc/rpc_client.dart';

/// How long a resume probe may wait before treating the PC as unreachable.
const livenessProbeTimeout = Duration(seconds: 8);

const resumeCatchUpSessionLimit = 3;

/// Keep the existing RPC client when we are already talking to this host.
/// Replacing it drops auto-reconnect and forces a new pairing handshake.
bool shouldReuseRpcClient({
  required String targetUrl,
  required String? currentUrl,
  required bool clientClosed,
}) {
  if (clientClosed) return false;
  if (currentUrl == null || currentUrl.isEmpty) return false;
  return currentUrl == targetUrl;
}

/// A half-open TCP socket still looks "connected". Only replace it when the
/// probe failed *and* the WebSocket is no longer open.
bool shouldReplaceLiveSocket({
  required RpcStatus status,
  required bool socketOpen,
  required bool probeFailed,
}) {
  if (!probeFailed) return false;
  if (status == RpcStatus.connecting) return false;
  return !socketOpen;
}

/// Resume catch-up used to pull every session's full history, which stalled
/// the only WebSocket. Busy sessions are the ones that may have finished
/// while the phone was backgrounded.
List<T> sessionsForResumeCatchUp<T>(
  Iterable<T> sessions, {
  required bool Function(T session) isBusy,
  int limit = resumeCatchUpSessionLimit,
}) {
  return sessions.where(isBusy).take(limit).toList();
}
