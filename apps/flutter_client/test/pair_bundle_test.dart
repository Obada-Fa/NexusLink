import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/auth/pair_bundle.dart';

String bundle(Map<String, Object?> json) =>
    'NXU1:${base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '')}';

Map<String, Object?> sample({
  Object? ts = '100.64.0.5',
  List<String> lan = const ['192.168.2.10'],
  int? exp,
  Map<String, Object?>? u,
}) => {
  'v': 1,
  'hub': 'hub-1',
  'pc': 'Office PC',
  'exp': exp ?? DateTime(2030).millisecondsSinceEpoch,
  'addr': {'ts': ts, 'lan': lan},
  'u':
      u ??
      {
        'nexuslink': {'port': 45678, 'code': '54978453', 'host': 'h-1'},
        'nexus-remote': {'port': 45679, 'code': '67852204'},
      },
};

void main() {
  final now = DateTime(2029);

  test('reads the NexusLink entry with the Tailscale address', () {
    final p = parsePairBundle(bundle(sample()), now: now);
    expect(p.wsUrl, 'ws://100.64.0.5:45678/rpc');
    expect(p.code, '54978453');
    expect(p.pcName, 'Office PC');
    expect(p.hostId, 'h-1');
  });

  test('falls back to the first LAN address without Tailscale', () {
    final p = parsePairBundle(bundle(sample(ts: null)), now: now);
    expect(p.wsUrl, 'ws://192.168.2.10:45678/rpc');
  });

  test('brackets an IPv6 address', () {
    final p = parsePairBundle(bundle(sample(ts: 'fd7a:115c::5')), now: now);
    expect(p.wsUrl, 'ws://[fd7a:115c::5]:45678/rpc');
  });

  test('accepts padding and surrounding whitespace', () {
    final text =
        ' NXU1:${base64Url.encode(utf8.encode(jsonEncode(sample())))}\n';
    expect(parsePairBundle(text, now: now).code, '54978453');
  });

  test('rejects with a user-facing reason', () {
    void rejects(String text, String part) => expect(
      () => parsePairBundle(text, now: now),
      throwsA(
        isA<PairBundleException>().having(
          (e) => e.message,
          'message',
          contains(part),
        ),
      ),
    );
    rejects('https://example.com', 'isn’t a Nexus pairing code');
    rejects('NXU1:@@@', 'couldn’t be read');
    rejects(bundle({...sample(), 'v': 2}), 'newer');
    rejects(
      bundle(sample(exp: DateTime(2028).millisecondsSinceEpoch)),
      'expired',
    );
    rejects(
      bundle(
        sample(
          u: {
            'nexus-remote': {'port': 1, 'code': '1'},
          },
        ),
      ),
      'doesn’t include NexusLink',
    );
    rejects(bundle(sample(ts: null, lan: const [])), 'network address');
    rejects(
      bundle(
        sample(
          u: {
            'nexuslink': {'port': 'x', 'code': '1'},
          },
        ),
      ),
      'incomplete',
    );
  });

  test('isPairBundle is a cheap prefix check', () {
    expect(isPairBundle('NXU1:abc'), isTrue);
    expect(isPairBundle('hello'), isFalse);
  });
}
