// Prints a scannable QR + the LAN URLs on host startup, so a phone joins by
// scanning a square instead of typing an IP address.

import os from 'os';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
// eslint-disable-next-line @typescript-eslint/no-var-requires
import qrcode from 'qrcode-terminal';

/**
 * Best-effort hint when a host firewall is likely rejecting LAN peers.
 * The server binding to 0.0.0.0 is not enough on hosts where ufw is active
 * with a deny/reject-incoming default — connections from the phone die at the
 * firewall while loopback tests keep working, which reads as an app bug.
 * No sudo, no rule parsing: if we can't tell, we stay silent.
 */
function firewallHint(port: number): string | null {
  if (process.platform !== 'linux') return null;
  try {
    if (!existsSync('/usr/sbin/ufw') && !existsSync('/sbin/ufw')) return null;
    const res = spawnSync('systemctl', ['is-active', 'ufw'], { encoding: 'utf8', timeout: 2000 });
    if (res.stdout?.trim() !== 'active') return null;
    return (
      `  ⚠ A firewall (ufw) is active on this machine.\n` +
      `    If your phone can't connect, allow the port once:\n` +
      `      sudo ufw allow ${port}/tcp comment 'NexusLink host'`
    );
  } catch {
    return null;
  }
}

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
  const hint = firewallHint(port);
  if (hint) console.log('\n' + hint);
  console.log('\n──────────────────────────────────────────\n');
}
