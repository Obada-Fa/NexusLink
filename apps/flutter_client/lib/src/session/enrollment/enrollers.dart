// Wire-level enrollment for Nexus Remote (HTTPS /pair) and Nexus Audio
// (ABP v2 enroll over TLS). Both pin the PC's self-signed certificate by the
// SHA-256 of its DER encoding. Codes and tokens are never logged.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// A failure with a message that is safe to show the user.
class EnrollException implements Exception {
  const EnrollException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Upper-hex SHA-256 of a DER certificate.
String fingerprintOfDer(List<int> der) =>
    sha256.convert(der).toString().toUpperCase();

/// Normalises a user-typed fingerprint (colons/spaces allowed). Empty string
/// means "pin whatever the server presents".
String normalizeFingerprint(String? fp) =>
    (fp ?? '').replaceAll(':', '').replaceAll(' ', '').toUpperCase();

String _bare(String address) => address.startsWith('[') && address.endsWith(']')
    ? address.substring(1, address.length - 1)
    : address;

class RemoteEnrollment {
  const RemoteEnrollment({
    required this.token,
    required this.hostId,
    required this.fingerprint,
    required this.address,
  });
  final String token, hostId, fingerprint, address;
}

class AudioEnrollment {
  const AudioEnrollment({
    required this.deviceId,
    required this.token,
    required this.fingerprint,
    required this.address,
  });
  final String deviceId, token, fingerprint, address;
}

class _PinMismatch implements Exception {
  const _PinMismatch();
}

/// Tries [attempt] on each address in order. A refusal from the PC
/// ([EnrollException]) stops at once, since the code is one-use; connection
/// problems move on to the next address.
Future<T> _firstAddress<T>(
  List<String> addresses,
  Future<T> Function(String address) attempt,
) async {
  if (addresses.isEmpty) {
    throw const EnrollException('No network address to try.');
  }
  var mismatch = false;
  for (final a in addresses) {
    try {
      return await attempt(a);
    } on EnrollException {
      rethrow;
    } on _PinMismatch {
      mismatch = true;
    } on TimeoutException {
      // try the next address
    } on SocketException {
      // try the next address
    } on HandshakeException {
      // try the next address
    } on TlsException {
      // try the next address
    } on HttpException {
      // try the next address
    } on FormatException {
      throw const EnrollException(
        'The PC sent a reply this app doesn’t understand. Update both apps.',
      );
    }
  }
  throw EnrollException(
    mismatch
        ? 'The PC’s certificate doesn’t match the pairing code. Make a new '
              'code on the PC and scan it again.'
        : 'Couldn’t reach the PC. Check that Tailscale (or Wi-Fi) is on and '
              'the utility is running.',
  );
}

abstract final class RemoteEnroller {
  /// HTTPS `POST /pair`; reply `{"token","host_id"}`.
  static Future<RemoteEnrollment> enroll({
    required List<String> addresses,
    required int port,
    required String code,
    String? fingerprint,
    String deviceName = 'Android phone',
    Duration timeout = const Duration(seconds: 8),
  }) => _firstAddress(addresses, (address) async {
    final expected = normalizeFingerprint(fingerprint);
    var seen = '';
    var mismatch = false;
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = timeout;
    client.badCertificateCallback = (cert, host, p) {
      seen = fingerprintOfDer(cert.der);
      if (expected.isEmpty) return true;
      if (expected.length == 64 && seen == expected) return true;
      mismatch = true;
      return false;
    };
    try {
      final uri = Uri(
        scheme: 'https',
        host: _bare(address),
        port: port,
        path: '/pair',
      );
      final HttpClientResponse response;
      final String text;
      try {
        final request = await client.postUrl(uri).timeout(timeout);
        final body = utf8.encode(
          jsonEncode({'code': code.trim(), 'device_name': deviceName}),
        );
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.add(body);
        response = await request.close().timeout(timeout);
        text = await utf8.decoder.bind(response).join().timeout(timeout);
      } catch (_) {
        if (mismatch) throw const _PinMismatch();
        rethrow;
      }
      Object? json;
      try {
        json = jsonDecode(text);
      } catch (_) {
        json = null;
      }
      if (response.statusCode != 200) {
        final err = json is Map ? json['error'] : null;
        throw EnrollException(
          err is String && err.isNotEmpty
              ? err
              : 'The PC refused the code. Make a new one and try again.',
        );
      }
      if (json is! Map ||
          json['token'] is! String ||
          json['host_id'] is! String) {
        throw const FormatException('bad reply');
      }
      return RemoteEnrollment(
        token: json['token'] as String,
        hostId: json['host_id'] as String,
        fingerprint: expected.isEmpty ? seen : expected,
        address: address,
      );
    } finally {
      client.close(force: true);
    }
  });
}

abstract final class AudioEnroller {
  /// ABP v2: one JSON line out, one line back (at most 4 KiB).
  static Future<AudioEnrollment> enroll({
    required List<String> addresses,
    required int port,
    required String code,
    String? fingerprint,
    String deviceName = 'Android phone',
    Duration timeout = const Duration(seconds: 8),
  }) => _firstAddress(addresses, (address) async {
    final expected = normalizeFingerprint(fingerprint);
    var seen = '';
    var mismatch = false;
    SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        _bare(address),
        port,
        context: SecurityContext(withTrustedRoots: false),
        timeout: timeout,
        onBadCertificate: (cert) {
          seen = fingerprintOfDer(cert.der);
          if (expected.isEmpty) return true;
          if (expected.length == 64 && seen == expected) return true;
          mismatch = true;
          return false;
        },
      );
    } catch (_) {
      if (mismatch) throw const _PinMismatch();
      rethrow;
    }
    try {
      socket.add(
        utf8.encode(
          '${jsonEncode({'abp': 2, 'op': 'enroll', 'code': code.trim(), 'deviceName': deviceName})}\n',
        ),
      );
      await socket.flush();
      final line = await _readLine(socket).timeout(timeout);
      if (line.isEmpty) {
        throw const EnrollException('The PC closed the connection.');
      }
      final Object? json = jsonDecode(utf8.decode(line));
      if (json is! Map) throw const FormatException('bad reply');
      if (json['ok'] != true) {
        final err = json['error'];
        final msg = err is Map ? err['message'] : null;
        throw EnrollException(
          msg is String && msg.isNotEmpty
              ? msg
              : 'The PC refused the code. Make a new one and try again.',
        );
      }
      if (json['deviceId'] is! String || json['token'] is! String) {
        throw const FormatException('bad reply');
      }
      return AudioEnrollment(
        deviceId: json['deviceId'] as String,
        token: json['token'] as String,
        fingerprint: expected.isEmpty ? seen : expected,
        address: address,
      );
    } finally {
      socket.destroy();
    }
  });

  static Future<List<int>> _readLine(Stream<List<int>> s) async {
    final out = <int>[];
    await for (final chunk in s) {
      for (final b in chunk) {
        if (b == 0x0A) return out;
        out.add(b);
        if (out.length >= 4096) return out;
      }
    }
    return out;
  }
}
