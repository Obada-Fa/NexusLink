import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexuslink/src/session/enrollment/enrollers.dart';

const goodCode = '12345678';

SecurityContext serverContext() => SecurityContext()
  ..useCertificateChain('test/session/fixtures/cert.pem')
  ..usePrivateKey('test/session/fixtures/key.pem');

/// Upper-hex SHA-256 of the fixture certificate's DER bytes.
String fixtureFingerprint() {
  final pem = File('test/session/fixtures/cert.pem').readAsStringSync();
  final b64 = pem
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  return fingerprintOfDer(base64.decode(b64));
}

/// Fake Nexus Remote: HTTPS POST /pair.
Future<HttpServer> fakeRemote({List<String>? bodies}) async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    serverContext(),
  );
  server.listen((req) async {
    final body = await utf8.decoder.bind(req).join();
    bodies?.add(body);
    final json = jsonDecode(body) as Map;
    if (req.method == 'POST' &&
        req.uri.path == '/pair' &&
        json['code'] == goodCode) {
      req.response.statusCode = 200;
      req.response.write(
        jsonEncode({'token': 'remote-token', 'host_id': 'rh-1'}),
      );
    } else {
      req.response.statusCode = 401;
      req.response.write(jsonEncode({'error': 'Wrong or expired code'}));
    }
    await req.response.close();
  });
  return server;
}

/// Fake Nexus Audio: ABP v2 enroll over TLS.
Future<SecureServerSocket> fakeAudio({List<String>? lines}) async {
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    serverContext(),
  );
  server.listen((socket) async {
    final buf = <int>[];
    await for (final chunk in socket) {
      buf.addAll(chunk);
      if (buf.contains(10)) break;
    }
    final line = utf8.decode(buf.sublist(0, buf.indexOf(10)));
    lines?.add(line);
    final json = jsonDecode(line) as Map;
    if (json['abp'] == 2 &&
        json['op'] == 'enroll' &&
        json['code'] == goodCode) {
      socket.write(
        '${jsonEncode({'ok': true, 'deviceId': 'dev-1', 'token': 'audio-token'})}\n',
      );
    } else {
      socket.write(
        '${jsonEncode({
          'ok': false,
          'error': {'code': 'UNAUTHENTICATED', 'message': 'Wrong or expired code'},
        })}\n',
      );
    }
    await socket.flush();
    await socket.close();
  });
  return server;
}
