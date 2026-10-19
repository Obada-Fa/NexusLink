/// Wake settings contain no bearer token; credentials use Android's keystore.
class WakeConfig {
  const WakeConfig({
    this.method = 'lan',
    this.mac = '',
    this.broadcast = '255.255.255.255',
    this.port = 9,
    this.endpoint = '',
    this.entity = '',
    this.authHeader = 'X-API-Key',
  });
  final String method;
  final String mac;
  final String broadcast;
  final int port;
  final String endpoint;
  final String entity;
  final String authHeader;
  factory WakeConfig.fromJson(Map<String, dynamic> json) => WakeConfig(
    method: json['method'] as String? ?? 'lan',
    mac: json['mac'] as String? ?? '',
    broadcast: json['broadcast'] as String? ?? '255.255.255.255',
    port: (json['port'] as num?)?.toInt() ?? 9,
    authHeader: json['authHeader'] == 'Authorization'
        ? 'Authorization'
        : 'X-API-Key',
    endpoint: json['endpoint'] as String? ?? '',
    entity: json['entity'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'method': method,
    'mac': mac,
    'broadcast': broadcast,
    'port': port,
    'endpoint': endpoint,
    'entity': entity,
    'authHeader': authHeader,
  };
  String get label => switch (method) {
    'webhook' => 'Home server',
    'homeAssistant' => 'Home Assistant / Tapo',
    _ => 'Wake-on-LAN',
  };
}
