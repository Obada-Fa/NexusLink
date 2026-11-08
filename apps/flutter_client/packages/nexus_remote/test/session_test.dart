import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/nexus_remote.dart';

/// A throwaway TLS server speaking just enough of Remote's /ws protocol.
class _Fake {
  _Fake(this.server, this.fingerprint, {required this.requireToken});
  final HttpServer server;
  final String fingerprint;
  final String? requireToken;
  int connections = 0;
  int get port => server.port;

  static Future<_Fake> start(Directory dir, String name, {String? requireToken}) async {
    final key = '${dir.path}/$name.key';
    final crt = '${dir.path}/$name.crt';
    final r = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', crt,
      '-days', '2', '-subj', '/CN=localhost',
    ]);
    if (r.exitCode != 0) throw StateError('openssl failed: ${r.stderr}');
    final ctx = SecurityContext()
      ..useCertificateChain(crt)
      ..usePrivateKey(key);
    final der = (await File(crt).readAsString())
        .split('-----')
        .firstWhere((p) => p.length > 100 && !p.contains('CERTIFICATE'));
    final fp = sha256.convert(base64.decode(der.replaceAll(RegExp(r'\s'), ''))).toString().toUpperCase();
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    final f = _Fake(server, fp, requireToken: requireToken);
    server.listen((req) async {
      f.connections++;
      if (requireToken != null && req.headers.value('Authorization') != 'Bearer $requireToken') {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((data) {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        Map<String, dynamic> result = {};
        if (m['method'] == 'host.info') {
          result = {'platform': 'linux', 'capabilities': {'input': 'supported'}};
        }
        ws.add(jsonEncode({'id': m['id'], 'result': result}));
      });
    });
    return f;
  }

  Future<void> stop() => server.close(force: true);
}

Future<void> _until(bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('nexus_remote_test'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  RemoteEndpoint ep(List<String> hosts, int port, String fp, [String token = 'tok']) => RemoteEndpoint(
      hosts: hosts, port: port, fingerprint: fp, hostId: 'h', token: token, pcName: 'PC');

  test('tries hosts in order and falls back to the next', () async {
    final fake = await _Fake.start(dir, 'a', requireToken: 'tok');
    final session = RemoteSession(ep(['127.0.0.1:1', '127.0.0.1:${fake.port}'], fake.port, fake.fingerprint));
    addTearDown(() async {
      session.dispose();
      await fake.stop();
    });
    await session.connect();
    expect(session.connected, isTrue);
    expect(session.address, '127.0.0.1:${fake.port}');
    expect(session.inputSupported, isTrue);
  });

  test('uses the first host when it works', () async {
    final fake = await _Fake.start(dir, 'b');
    final session = RemoteSession(ep(['127.0.0.1', '10.255.255.1'], fake.port, fake.fingerprint));
    addTearDown(() async {
      session.dispose();
      await fake.stop();
    });
    await session.connect();
    expect(session.connected, isTrue);
    expect(session.address, '127.0.0.1');
  });

  test('pin mismatch is rejected and does not fire onUnauthorized', () async {
    final fake = await _Fake.start(dir, 'c');
    var unauthorized = 0;
    final session = RemoteSession(ep(['127.0.0.1'], fake.port, 'CD' * 32),
        onUnauthorized: () => unauthorized++);
    addTearDown(() async {
      session.dispose();
      await fake.stop();
    });
    await session.connect();
    expect(session.connected, isFalse);
    expect(session.status, 'Certificate changed');
    expect(fake.connections, 0);
    expect(unauthorized, 0);
  });

  test('401 fires onUnauthorized once and stops reconnecting', () async {
    final fake = await _Fake.start(dir, 'd', requireToken: 'right');
    var unauthorized = 0;
    final session = RemoteSession(ep(['127.0.0.1'], fake.port, fake.fingerprint, 'wrong'),
        onUnauthorized: () => unauthorized++);
    addTearDown(() async {
      session.dispose();
      await fake.stop();
    });
    await session.connect();
    expect(session.connected, isFalse);
    expect(session.status, 'Credential revoked');
    await _until(() => unauthorized == 1);
    await session.connect();
    expect(unauthorized, 1);
  });
}
