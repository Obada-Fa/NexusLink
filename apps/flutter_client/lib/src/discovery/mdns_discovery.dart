// Zero-typing host discovery: resolve _nexuslink._tcp.local via mDNS.
// Server counterpart: apps/desktop/src/server/mdns.ts.

import 'package:multicast_dns/multicast_dns.dart';

class DiscoveredHost {
  final String name;
  final String address;
  final int port;
  DiscoveredHost(this.name, this.address, this.port);

  String get wsUrl => 'ws://$address:$port/rpc';
  String get httpUrl => 'http://$address:$port';
}

const _serviceType = '_nexuslink._tcp.local';

Future<List<DiscoveredHost>> discoverHosts(
    {Duration timeout = const Duration(seconds: 3)}) async {
  final client = MDnsClient();
  final found = <String, DiscoveredHost>{};
  try {
    await client.start();
    await for (final ptr in client
        .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_serviceType))
        .timeout(timeout, onTimeout: (sink) => sink.close())) {
      await for (final srv in client
          .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName))
          .timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
        await for (final ip in client
            .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target))
            .timeout(const Duration(seconds: 2),
                onTimeout: (sink) => sink.close())) {
          final label = ptr.domainName
              .replaceAll('.$_serviceType', '')
              .replaceAll('._nexuslink._tcp.local', '');
          found[ip.address.address] = DiscoveredHost(
              label, ip.address.address, srv.port);
        }
      }
    }
  } finally {
    client.stop();
  }
  return found.values.toList();
}
