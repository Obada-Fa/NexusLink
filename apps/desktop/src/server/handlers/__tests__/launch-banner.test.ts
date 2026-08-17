import { describe, expect, test } from 'bun:test';
import {
  collectHostUrls,
  isIpv4,
  isTailscaleIpv4,
  parseTailscaleIpOutput,
  tailscaleIpv4FromCli,
} from '../../launch-banner';

describe('isIpv4', () => {
  test('accepts dotted quads', () => {
    expect(isIpv4('192.168.2.30')).toBe(true);
    expect(isIpv4('100.91.4.12')).toBe(true);
  });
  test('rejects junk', () => {
    expect(isIpv4('::1')).toBe(false);
    expect(isIpv4('100.91.4')).toBe(false);
    expect(isIpv4('999.1.1.1')).toBe(false);
    expect(isIpv4('')).toBe(false);
  });
});

describe('isTailscaleIpv4', () => {
  test('CGNAT 100.64.0.0/10 is Tailscale', () => {
    expect(isTailscaleIpv4('100.64.0.1')).toBe(true);
    expect(isTailscaleIpv4('100.91.4.12')).toBe(true);
    expect(isTailscaleIpv4('100.127.255.254')).toBe(true);
  });
  test('just outside the CGNAT block is not', () => {
    expect(isTailscaleIpv4('100.63.255.255')).toBe(false);
    expect(isTailscaleIpv4('100.128.0.1')).toBe(false);
    expect(isTailscaleIpv4('192.168.2.30')).toBe(false);
    expect(isTailscaleIpv4('10.0.0.5')).toBe(false);
  });
  test('tailscale* iface name wins even for a non-CGNAT address', () => {
    expect(isTailscaleIpv4('10.10.10.10', 'tailscale0')).toBe(true);
    expect(isTailscaleIpv4('10.10.10.10', 'Tailscale1')).toBe(true);
    expect(isTailscaleIpv4('10.10.10.10', 'wlan0')).toBe(false);
  });
});

describe('parseTailscaleIpOutput', () => {
  test('reads one IPv4 per line and ignores blanks', () => {
    expect(parseTailscaleIpOutput('100.91.4.12\n')).toEqual(['100.91.4.12']);
    expect(parseTailscaleIpOutput('  100.91.4.12  \n\n100.64.0.2\n')).toEqual([
      '100.91.4.12',
      '100.64.0.2',
    ]);
  });
  test('dedupes', () => {
    expect(parseTailscaleIpOutput('100.91.4.12\n100.91.4.12')).toEqual(['100.91.4.12']);
  });
});

describe('tailscaleIpv4FromCli', () => {
  test('returns [] when the binary is missing or fails', () => {
    expect(tailscaleIpv4FromCli(() => ({ status: 127, stdout: '' }))).toEqual([]);
    expect(tailscaleIpv4FromCli(() => ({ status: 1, stdout: 'failed' }))).toEqual([]);
  });
  test('parses a successful `tailscale ip -4`', () => {
    expect(
      tailscaleIpv4FromCli(() => ({ status: 0, stdout: '100.91.4.12\n' })),
    ).toEqual(['100.91.4.12']);
  });
});

describe('collectHostUrls', () => {
  const nets = {
    wlan0: [
      { address: '192.168.2.30', family: 'IPv4' as const, internal: false },
      { address: 'fe80::1', family: 'IPv6' as const, internal: false },
    ],
    lo: [{ address: '127.0.0.1', family: 'IPv4' as const, internal: true }],
    tailscale0: [
      { address: '100.91.4.12', family: 'IPv4' as const, internal: false },
    ],
  };

  test('classifies LAN vs Tailscale and puts Tailscale first', () => {
    const urls = collectHostUrls(45678, 'http', nets as ReturnType<typeof import('os').networkInterfaces>);
    expect(urls.map((u) => u.kind)).toEqual(['tailscale', 'lan']);
    expect(urls[0]!.url).toBe('http://100.91.4.12:45678');
    expect(urls[1]!.url).toBe('http://192.168.2.30:45678');
  });

  test('merges CLI Tailscale IPs that have no kernel iface (userspace net)', () => {
    const onlyLan = {
      eth0: [{ address: '10.0.0.8', family: 'IPv4' as const, internal: false }],
    };
    const urls = collectHostUrls(
      45678,
      'http',
      onlyLan as ReturnType<typeof import('os').networkInterfaces>,
      ['100.64.1.9'],
    );
    expect(urls.find((u) => u.kind === 'tailscale')?.url).toBe('http://100.64.1.9:45678');
    expect(urls.find((u) => u.kind === 'lan')?.url).toBe('http://10.0.0.8:45678');
  });

  test('CLI IP reclassifies an already-listed address as tailscale', () => {
    const weird = {
      tun0: [{ address: '100.91.4.12', family: 'IPv4' as const, internal: false }],
    };
    const urls = collectHostUrls(
      80,
      'http',
      weird as ReturnType<typeof import('os').networkInterfaces>,
      ['100.91.4.12'],
    );
    expect(urls).toHaveLength(1);
    expect(urls[0]!.kind).toBe('tailscale');
    expect(urls[0]!.url).toBe('http://100.91.4.12:80');
  });

  test('skips loopback and IPv6', () => {
    const urls = collectHostUrls(45678, 'http', nets as ReturnType<typeof import('os').networkInterfaces>);
    expect(urls.every((u) => u.address !== '127.0.0.1')).toBe(true);
    expect(urls.every((u) => !u.address.includes(':'))).toBe(true);
  });
});
