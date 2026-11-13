import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/last_host.dart';

/// Records connects instead of opening sockets.
class FakeConnection extends ConnectionNotifier {
  static final connects = <String>[];
  static Object? failWith;
  bool _disconnected = false;

  @override
  bool get userDisconnected => _disconnected;

  @override
  Future<void> connect(String wsUrl, {String? pairingCode}) async {
    _disconnected = false;
    final url = normalizeHostWsUrl(wsUrl);
    connects.add(pairingCode == null ? url : '$url#$pairingCode');
    final error = failWith;
    if (error != null) {
      state = ConnectionState(
        hostUrl: url,
        authRequired: isAuthError(error),
        lastError: connectErrorMessage(error),
      );
      throw error;
    }
    state = ConnectionState(hostUrl: url, status: RpcStatus.connected);
  }

  @override
  void disconnect() {
    _disconnected = true;
    state = const ConnectionState();
  }

  @override
  Future<void> ensureConnected() async {}
}
