// ECDH P-256 + TOTP pairing handshake — Dart port of the PWA client
// (apps/mobile-client/src/lib/auth-client.ts); host side:
// apps/desktop/src/server/handlers/auth.ts.
//
// Wire compat: the HMAC-SHA1 key is the first 20 bytes of the ECDH shared
// point's X coordinate (the host derives it via WebCrypto
// deriveKey({HMAC, SHA-1, length: 160})). `computeSecret` returns the X
// coordinate left-padded to 32 bytes, so the truncation lines up exactly.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:elliptic/ecdh.dart';
import 'package:elliptic/elliptic.dart';

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _b64urlDecode(String s) {
  final pad = (4 - s.length % 4) % 4;
  return Uint8List.fromList(base64Url.decode(s + '=' * pad));
}

Uint8List _bigIntTo32(BigInt v) {
  final hex = v.toRadixString(16).padLeft(64, '0');
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

String _hotp(List<int> key, int counter, {int digits = 6}) {
  final counterBytes = Uint8List(8);
  ByteData.sublistView(counterBytes).setUint64(0, counter);
  final mac = Hmac(sha1, key).convert(counterBytes).bytes;
  final offset = mac[mac.length - 1] & 0x0f;
  final binary = ((mac[offset] & 0x7f) << 24) |
      ((mac[offset + 1] & 0xff) << 16) |
      ((mac[offset + 2] & 0xff) << 8) |
      (mac[offset + 3] & 0xff);
  final mod = BigInt.from(10).pow(digits).toInt();
  return (binary % mod).toString().padLeft(digits, '0');
}

/// Runs session.pair + session.authenticate over [call] and returns the
/// session token. [call] must be usable before the session is authenticated
/// (the host allows both methods unauthenticated).
Future<String> performPairingHandshake(
    Future<dynamic> Function(String method, Map<String, dynamic> params)
        call) async {
  final ec = getP256();
  final priv = ec.generatePrivateKey();
  final pub = priv.publicKey;

  final jwk = jsonEncode({
    'kty': 'EC',
    'crv': 'P-256',
    'x': _b64url(_bigIntTo32(pub.X)),
    'y': _b64url(_bigIntTo32(pub.Y)),
  });

  final pairResp =
      await call('session.pair', {'publicKey': jwk}) as Map<String, dynamic>;
  final peerJwk =
      jsonDecode(pairResp['publicKey'] as String) as Map<String, dynamic>;
  final peerPub = PublicKey(
    ec,
    _bytesToBigInt(_b64urlDecode(peerJwk['x'] as String)),
    _bytesToBigInt(_b64urlDecode(peerJwk['y'] as String)),
  );

  final hmacKey = computeSecret(priv, peerPub).sublist(0, 20);
  final counter = DateTime.now().millisecondsSinceEpoch ~/ 30000;
  final code = _hotp(hmacKey, counter);

  final authResp = await call('session.authenticate', {'code': code})
      as Map<String, dynamic>;
  return authResp['token'] as String;
}
