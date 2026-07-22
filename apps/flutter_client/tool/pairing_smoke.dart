// Smoke test: real RpcClient (incl. ECDH/TOTP handshake in connect()) against
// a live host. Exercises the exact code path the Android app runs.
//
//   dart run tool/pairing_smoke.dart [ws://host:port/rpc]

import 'dart:io';

import 'package:nexuslink/src/rpc/rpc_client.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args.first : 'ws://127.0.0.1:45678/rpc';
  final client = RpcClient(url);
  try {
    await client.connect();
    stdout.writeln('CONNECT+HANDSHAKE OK (status: ${client.status})');
    final info = await client.request('system.getInfo');
    stdout.writeln('PRIVILEGED RPC OK: ${'$info'.substring(0, 80)}');
    final windows = await client.request('window.list');
    stdout.writeln('window.list OK: ${(windows as List).length} windows');
    client.dispose();
    exit(0);
  } catch (e) {
    stderr.writeln('FAILED: $e');
    client.dispose();
    exit(1);
  }
}
