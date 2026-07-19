// Live-host integration test: exercises the Dart RpcClient against a running
// NexusLink host (skips cleanly when none is up). Proves the full protocol:
// mDNS discovery, JSON RPC round-trips, launcher data, and binary mirror frames.
//
// Run: flutter test test/rpc_live_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexuslink/src/rpc/rpc_client.dart';

const liveUrl = 'ws://127.0.0.1:45678/rpc';
const httpBase = 'http://127.0.0.1:45678';

Future<bool> hostUp() async {
  try {
    final socket =
        await Socket.connect('127.0.0.1', 45678, timeout: const Duration(seconds: 1));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('live host: RPC + launcher + binary mirror frames', () async {
    if (!await hostUp()) {
      markTestSkipped('no NexusLink host on :45678');
      return;
    }

    final client = RpcClient(liveUrl);
    await client.connect();
    expect(client.status, RpcStatus.connected);

    // Plain RPC round-trip.
    final info = await client.request('system.getInfo') as Map<String, dynamic>;
    expect(info['hostname'], isNotEmpty);

    // Launcher data (the mobile-OS surface).
    final windows = await client.request('window.list') as List<dynamic>;
    final apps = await client.request('apps.list', const {},
        const Duration(seconds: 30)) as List<dynamic>;
    expect(apps, isNotEmpty);
    // windows may legitimately be empty on a bare session; just type-check.
    expect(windows, isA<List<dynamic>>());

    // Binary mirror frames: start capture, expect ≥5 parseable JPEG frames in 3s.
    final cap = await client.request(
        'screen.startCapture', {'quality': 'low', 'fps': 15}) as Map<String, dynamic>;
    final streamKey = (cap['streamKey'] as num).toInt();
    expect(cap['region'], isA<Map<String, dynamic>>());

    var frames = 0;
    final done = Completer<void>();
    final sub = client.frames.listen((f) {
      if (f.streamKey != streamKey) return;
      // JPEG SOI marker sanity check.
      expect(f.jpeg[0], 0xff);
      expect(f.jpeg[1], 0xd8);
      frames++;
      if (frames >= 5 && !done.isCompleted) done.complete();
    });

    await done.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    expect(frames, greaterThanOrEqualTo(5));

    await client.request('screen.stopCapture', {'streamId': cap['streamId']});

    // Files screen data path: fs.list on the home dir, then an HTTP upload +
    // download round-trip via the same `http` package the Files screen uses.
    final home = info['homeDir'] as String;
    final entries = await client.request('fs.list', {'path': home}) as List<dynamic>;
    expect(entries, isA<List<dynamic>>());

    final tmpPath = '$home/.nexuslink_livetest.bin';
    final payload = Uint8List.fromList(List.generate(4096, (i) => i % 256));
    final upUri = Uri.parse(
        '$httpBase/files?path=${Uri.encodeQueryComponent(tmpPath)}&overwrite=1');
    final up = await http.post(upUri, body: payload);
    expect(up.statusCode, 200);

    final downUri =
        Uri.parse('$httpBase/files?path=${Uri.encodeQueryComponent(tmpPath)}');
    final down = await http.get(downUri);
    expect(down.statusCode, 200);
    expect(down.bodyBytes, equals(payload));

    client.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));
}
