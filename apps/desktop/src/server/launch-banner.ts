// Prints a scannable QR + the LAN URLs on host startup, so a phone joins by
// scanning a square instead of typing an IP address.

import os from 'os';
// eslint-disable-next-line @typescript-eslint/no-var-requires
import qrcode from 'qrcode-terminal';

/** All non-internal IPv4 URLs the host is reachable at, on `port`. */
export function lanUrls(port: number, scheme = 'http'): string[] {
  const nets = os.networkInterfaces();
  const urls: string[] = [];
  for (const iface of Object.values(nets)) {
    for (const ni of iface ?? []) {
      if (ni.family === 'IPv4' && !ni.internal) {
        urls.push(`${scheme}://${ni.address}:${port}`);
      }
    }
  }
  return urls;
}

export function printLaunchBanner(port: number, serveStaticClient: boolean): void {
  const urls = lanUrls(port);
  console.log('\n──────────────────────────────────────────');
  console.log('  NexusLink host is ready');
  console.log('──────────────────────────────────────────\n');

  if (serveStaticClient && urls.length > 0) {
    const primary = urls[0]!;
    console.log('  📱 Scan with your phone (same Wi-Fi) to connect:\n');
    qrcode.generate(primary, { small: true });
    console.log(`\n  …or open in a browser:  ${primary}`);
    for (const u of urls.slice(1)) console.log(`                          ${u}`);
  } else if (urls.length > 0) {
    console.log('  Web client not built yet (single-port mode off).');
    console.log('  Build it once:  (cd apps/mobile-client && bun run build)\n');
    console.log('  Meanwhile the RPC WebSocket is reachable at:');
    for (const u of urls) console.log(`    ${u.replace(/^http/, 'ws')}/rpc`);
  } else {
    console.log('  No LAN interface detected; reachable at ws://localhost:' + port + '/rpc');
  }
  console.log('\n──────────────────────────────────────────\n');
}
