import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection_policy.dart';

void main() {
  group('shouldReuseRpcClient', () {
    test('reuses an open client for the same host', () {
      expect(
        shouldReuseRpcClient(
          targetUrl: 'ws://192.168.1.8:45678/rpc',
          currentUrl: 'ws://192.168.1.8:45678/rpc',
          clientClosed: false,
        ),
        isTrue,
      );
    });

    test('does not reuse a disposed client or a different host', () {
      expect(
        shouldReuseRpcClient(
          targetUrl: 'ws://192.168.1.8:45678/rpc',
          currentUrl: 'ws://192.168.1.8:45678/rpc',
          clientClosed: true,
        ),
        isFalse,
      );
      expect(
        shouldReuseRpcClient(
          targetUrl: 'ws://192.168.1.9:45678/rpc',
          currentUrl: 'ws://192.168.1.8:45678/rpc',
          clientClosed: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldReplaceLiveSocket', () {
    test('keeps a still-open socket after a slow heartbeat', () {
      expect(
        shouldReplaceLiveSocket(
          status: RpcStatus.connected,
          socketOpen: true,
          probeFailed: true,
        ),
        isFalse,
      );
    });

    test('replaces a connected status with a dead socket', () {
      expect(
        shouldReplaceLiveSocket(
          status: RpcStatus.connected,
          socketOpen: false,
          probeFailed: true,
        ),
        isTrue,
      );
    });
  });

  group('sessionsForResumeCatchUp', () {
    test('only pulls busy sessions, capped at 3', () {
      final sessions = [
        (id: 'a', busy: false),
        (id: 'b', busy: true),
        (id: 'c', busy: true),
        (id: 'd', busy: true),
        (id: 'e', busy: true),
        (id: 'f', busy: false),
      ];
      final picked = sessionsForResumeCatchUp(
        sessions,
        isBusy: (s) => s.busy,
      );
      expect(picked.map((s) => s.id).toList(), ['b', 'c', 'd']);
    });

    test('skips catch-up when nothing is running', () {
      expect(
        sessionsForResumeCatchUp(
          [(id: 'a', busy: false)],
          isBusy: (s) => s.busy,
        ),
        isEmpty,
      );
    });
  });
}
