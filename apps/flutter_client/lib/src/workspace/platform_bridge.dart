import 'dart:io';
import 'package:flutter/services.dart';

class PlatformBridge {
  static const channel = MethodChannel('nexuslink/workspace');
  static final Map<String, String> _memory = {};
  static Future<String?> credential(String host) async => Platform.isAndroid
      ? channel.invokeMethod<String>('credential.get', {'host': host})
      : _memory[host];
  static Future<void> saveCredential(String host, String value) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('credential.set', {
        'host': host,
        'value': value,
      });
    } else {
      _memory[host] = value;
    }
  }

  static Future<void> removeCredential(String host) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('credential.remove', {'host': host});
    } else {
      _memory.remove(host);
    }
  }

  static Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('This feature requires Android.');
    }
    return channel.invokeMethod(method, args);
  }
}
