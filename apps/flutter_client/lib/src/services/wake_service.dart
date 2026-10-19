import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../state/wake_config.dart';
import '../workspace/platform_bridge.dart';

final wakeServiceProvider = Provider((ref) => WakeService());

class WakeException implements Exception {
  const WakeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WakeService {
  static String credentialKey(String host) => 'wake:$host';
  static Uint8List magicPacket(String mac) {
    if (!RegExp(r'^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$').hasMatch(mac) &&
        !RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(mac)) {
      throw const WakeException(
        'Enter the PC’s network adapter MAC address, such as AA:BB:CC:DD:EE:FF.',
      );
    }
    final hex = mac.replaceAll(RegExp('[:-]'), '');
    final address = List.generate(
      6,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    );
    final packet = Uint8List(102)..fillRange(0, 6, 255);
    for (var i = 0; i < 16; i++) {
      packet.setRange(6 + i * 6, 12 + i * 6, address);
    }
    return packet;
  }

  static Uri endpoint(WakeConfig config) {
    final uri = Uri.tryParse(config.endpoint.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const WakeException(
        'Enter a full http:// or https:// home-server address.',
      );
    }
    if (config.method != 'homeAssistant') return uri;
    if (!RegExp(
      r'^(switch|button|script)\.[a-z0-9_]+$',
    ).hasMatch(config.entity)) {
      throw const WakeException(
        'Enter a Home Assistant entity such as switch.pc_power or button.wake_pc.',
      );
    }
    if (uri.path != '' && uri.path != '/' || uri.hasQuery) {
      throw const WakeException(
        'Use the Home Assistant base address, such as http://home-server:8123.',
      );
    }
    final domain = config.entity.split('.').first;
    return uri.replace(
      path: '/api/services/$domain/${domain == 'button' ? 'press' : 'turn_on'}',
    );
  }

  static void validate(WakeConfig config) {
    if (config.method == 'lan') {
      magicPacket(config.mac);
      final address = InternetAddress.tryParse(config.broadcast);
      if (address == null || address.type != InternetAddressType.IPv4) {
        throw const WakeException(
          'Enter an IPv4 broadcast address, such as 192.168.68.255.',
        );
      }
      if (config.port < 1 || config.port > 65535) {
        throw const WakeException('UDP port must be between 1 and 65535.');
      }
    } else if (['webhook', 'homeAssistant'].contains(config.method)) {
      endpoint(config);
    } else {
      throw const WakeException('Choose a supported wake method.');
    }
  }

  Future<String?> token(String host) =>
      PlatformBridge.credential(credentialKey(host));
  Future<void> saveToken(String host, String value) async {
    if (value.trim().isEmpty) {
      await PlatformBridge.removeCredential(credentialKey(host));
    } else {
      await PlatformBridge.saveCredential(credentialKey(host), value.trim());
    }
  }

  Future<void> removeToken(String host) =>
      PlatformBridge.removeCredential(credentialKey(host));

  Future<void> wake(String host, WakeConfig config) async {
    validate(config);
    if (config.method == 'lan') {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      try {
        socket.broadcastEnabled = true;
        final packet = magicPacket(config.mac);
        for (var i = 0; i < 3; i++) {
          if (socket.send(
                packet,
                InternetAddress(config.broadcast),
                config.port,
              ) !=
              packet.length) {
            throw const WakeException(
              'The phone could not send the wake packet. Check your Wi-Fi connection.',
            );
          }
          if (i < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      } finally {
        socket.close();
      }
      return;
    }
    final secret = await token(host);
    if (config.method == 'homeAssistant' &&
        (secret == null || secret.isEmpty)) {
      throw const WakeException(
        'Add a Home Assistant long-lived access token in Wake settings.',
      );
    }
    await sendHttp(config, secret);
  }

  /// Exposed for transport tests. Never follows a redirect with a wake credential.
  Future<void> sendHttp(
    WakeConfig config,
    String? secret, {
    http.Client? client,
  }) async {
    final transport = client ?? http.Client();
    try {
      final request = http.Request('POST', endpoint(config))
        ..followRedirects = false;
      request.headers['Content-Type'] = 'application/json';
      if (secret?.isNotEmpty == true) {
        final bearer =
            config.method == 'homeAssistant' ||
            config.authHeader == 'Authorization';
        request.headers[bearer ? 'Authorization' : 'X-API-Key'] = bearer
            ? 'Bearer $secret'
            : secret!;
      }
      request.body = jsonEncode(
        config.method == 'homeAssistant'
            ? {'entity_id': config.entity}
            : {'action': 'wake'},
      );
      final response = await transport
          .send(request)
          .timeout(const Duration(seconds: 12));
      // Discard response content: a home server can include credentials in errors.
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const WakeException(
          'Home server rejected the wake token. Update it in Wake settings.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw WakeException(
          'Home server did not accept the wake request (HTTP ${response.statusCode}). Check the endpoint and automation.',
        );
      }
    } on TimeoutException {
      throw const WakeException(
        'Home server timed out. Check that it is online and reachable over Wi-Fi or Tailscale.',
      );
    } on http.ClientException {
      throw const WakeException(
        'Could not reach the home server. Check its address and your Wi-Fi or Tailscale connection.',
      );
    } finally {
      if (client == null) transport.close();
    }
  }

  Future<bool> reachable(String host) async {
    final uri = Uri.parse(host);
    Socket? socket;
    try {
      socket = await Socket.connect(
        uri.host,
        uri.hasPort ? uri.port : (uri.scheme == 'wss' ? 443 : 80),
        timeout: const Duration(seconds: 2),
      );
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}
