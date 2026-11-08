import 'package:nexus_remote/nexus_remote.dart';

RemoteEndpoint testEndpoint({
  List<String> hosts = const ['127.0.0.1'],
  int port = 45679,
  String? fingerprint,
  String token = 'tok',
}) =>
    RemoteEndpoint(
      hosts: hosts,
      port: port,
      fingerprint: fingerprint ?? 'AB' * 32,
      hostId: 'host-1',
      token: token,
      pcName: 'Test PC',
    );
