// Prints scannable QR codes + the URLs on host startup, so a phone joins by
// scanning a square instead of typing an IP. When Tailscale is up we print a
// QR for that IP as well as the local Wi-Fi one — the phone can connect from
// any network as long as both sides are on the tailnet.

import os from 'os';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
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

export type HostUrlKind = 'lan' | 'tailscale';

export interface HostUrl {
  url: string;
  address: string;
  kind: HostUrlKind;
  /** Kernel iface name, when the address came from os.networkInterfaces(). */
  iface?: string;
}

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

export function isIpv4(address: string): boolean {
  const m = address.match(IPV4);
  if (!m) return false;
  return m.slice(1).every((o) => {
    const n = Number(o);
    return n >= 0 && n <= 255;
  });
}

/**
 * Tailscale's default userspace/kernel addresses live in CGNAT 100.64.0.0/10.
 * An iface named `tailscale*` is also treated as Tailscale even if the address
 * is something else (custom --advertise / 4via6 edge cases).
 */
export function isTailscaleIpv4(address: string, ifaceName?: string): boolean {
  if (ifaceName && /^tailscale\d*$/i.test(ifaceName)) return true;
  const m = address.match(IPV4);
  if (!m) return false;
  const a = Number(m[1]);
  const b = Number(m[2]);
  return a === 100 && b >= 64 && b <= 127;
}

/** Parse `tailscale ip -4` stdout (one address per line, sometimes extra whitespace). */
export function parseTailscaleIpOutput(stdout: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of stdout.split(/\s+/)) {
    const addr = raw.trim();
    if (!isIpv4(addr) || seen.has(addr)) continue;
    seen.add(addr);
    out.push(addr);
  }
  return out;
}

export function tailscaleIpv4FromCli(
  run: (cmd: string, args: string[]) => { status: number | null; stdout: string } = (cmd, args) => {
    try {
      const res = spawnSync(cmd, args, { encoding: 'utf8', timeout: 2000 });
      return { status: res.status, stdout: res.stdout ?? '' };
    } catch {
      return { status: 1, stdout: '' };
    }
  },
): string[] {
  const res = run('tailscale', ['ip', '-4']);
  if (res.status !== 0) return [];
  return parseTailscaleIpOutput(res.stdout);
}

type NodeNetIfaces = ReturnType<typeof os.networkInterfaces>;

/**
 * Classify every non-internal IPv4 the host is reachable at. Extra Tailscale
 * IPs (from the CLI, covering userspace-networking where there's no iface)
 * are merged in if they weren't already on an interface.
 */
export function collectHostUrls(
  port: number,
  scheme = 'http',
  nets: NodeNetIfaces = os.networkInterfaces(),
  extraTailscaleIps: string[] = [],
): HostUrl[] {
  const byAddr = new Map<string, HostUrl>();

  for (const [iface, addrs] of Object.entries(nets)) {
    for (const ni of addrs ?? []) {
      const family = String(ni.family) === 'IPv4' || String(ni.family) === '4';
      if (!family || ni.internal || !isIpv4(ni.address)) continue;
      const kind: HostUrlKind = isTailscaleIpv4(ni.address, iface) ? 'tailscale' : 'lan';
      byAddr.set(ni.address, {
        url: `${scheme}://${ni.address}:${port}`,
        address: ni.address,
        kind,
        iface,
      });
    }
  }

  for (const addr of extraTailscaleIps) {
    if (!isIpv4(addr)) continue;
    const existing = byAddr.get(addr);
    if (existing) {
      existing.kind = 'tailscale';
      continue;
    }
    byAddr.set(addr, {
      url: `${scheme}://${addr}:${port}`,
      address: addr,
      kind: 'tailscale',
    });
  }

  // Tailscale first so its QR sits on top of the local-Wi-Fi one.
  return [...byAddr.values()].sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === 'tailscale' ? -1 : 1;
    return a.address.localeCompare(b.address);
  });
}

/** All non-internal IPv4 URLs the host is reachable at, on `port`. */
export function lanUrls(port: number, scheme = 'http'): string[] {
  return collectHostUrls(port, scheme).map((u) => u.url);
}

function printQrBlock(label: string, hint: string, urls: HostUrl[]): void {
  if (urls.length === 0) return;
  const primary = urls[0]!;
  console.log(`  ${label}`);
  if (hint) console.log(`  ${hint}\n`);
  else console.log('');
  qrcode.generate(primary.url, { small: true });
  console.log(`\n  …or open in a browser:  ${primary.url}`);
  for (const u of urls.slice(1)) console.log(`                          ${u.url}`);
  console.log('');
}

export function printLaunchBanner(port: number, serveStaticClient: boolean): void {
  const urls = collectHostUrls(port, 'http', os.networkInterfaces(), tailscaleIpv4FromCli());
  const tailscale = urls.filter((u) => u.kind === 'tailscale');
  const lan = urls.filter((u) => u.kind === 'lan');

  console.log('\n──────────────────────────────────────────');
  console.log('  NexusLink host is ready');
  console.log('──────────────────────────────────────────\n');

  if (serveStaticClient && urls.length > 0) {
    printQrBlock(
      '📱 Tailscale — scan from any network (both devices on the tailnet):',
      '',
      tailscale,
    );
    printQrBlock(
      '📱 Local Wi-Fi — scan on the same network:',
      '',
      lan,
    );
  } else if (urls.length > 0) {
    console.log('  Web client not built yet (single-port mode off).');
    console.log('  Build it once:  (cd apps/mobile-client && bun run build)\n');
    console.log('  Meanwhile the RPC WebSocket is reachable at:');
    for (const u of urls) console.log(`    ${u.url.replace(/^http/, 'ws')}/rpc`);
  } else {
    console.log('  No LAN interface detected; reachable at ws://localhost:' + port + '/rpc');
  }
  const hint = firewallHint(port);
  if (hint) console.log('\n' + hint);
  console.log('\n──────────────────────────────────────────\n');
}
