import os from 'os';
import { spawnSync } from 'node:child_process';
import qrcode from 'qrcode-terminal';

export type HostUrlKind = 'lan' | 'tailscale';

export interface HostUrl {
  url: string;
  address: string;
  kind: HostUrlKind;
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

export function isTailscaleIpv4(address: string, ifaceName?: string): boolean {
  if (ifaceName && /^tailscale\d*$/i.test(ifaceName)) return true;
  const m = address.match(IPV4);
  if (!m) return false;
  const a = Number(m[1]);
  const b = Number(m[2]);
  return a === 100 && b >= 64 && b <= 127;
}

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

  return [...byAddr.values()].sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === 'tailscale' ? -1 : 1;
    return a.address.localeCompare(b.address);
  });
}

function firewallHint(port: number): string {
  return (
    `  If the phone cannot connect, allow TCP ${port} in Windows Firewall:\n` +
    `    netsh advfirewall firewall add rule name=NexusLink dir=in action=allow protocol=TCP localport=${port}`
  );
}

function printQrBlock(label: string, urls: HostUrl[]): void {
  if (urls.length === 0) return;
  const primary = urls[0]!;
  console.log(`  ${label}\n`);
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
  console.log('  NexusLink Windows host is ready');
  console.log('──────────────────────────────────────────\n');

  if (serveStaticClient && urls.length > 0) {
    printQrBlock('Tailscale — scan from any network (both devices on the tailnet):', tailscale);
    printQrBlock('Local Wi-Fi — scan on the same network:', lan);
  } else if (urls.length > 0) {
    console.log('  Web client not built yet (single-port mode off).');
    console.log('  Build it once:  (cd apps/mobile-client && bun run build)\n');
    console.log('  Meanwhile the RPC WebSocket is reachable at:');
    for (const u of urls) console.log(`    ${u.url.replace(/^http/, 'ws')}/rpc`);
  } else {
    console.log('  No LAN interface detected; reachable at ws://localhost:' + port + '/rpc');
  }
  console.log('\n' + firewallHint(port));
  console.log('\n──────────────────────────────────────────\n');
}
