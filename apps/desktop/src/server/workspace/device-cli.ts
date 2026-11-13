import { createInvite, deviceCount, hostId, enableEnrollment, listDevices, listDevicesDetailed, revokeDevice } from './security';
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const json = args.includes('--json');
const rest = args.filter(a => a !== '--json');
const command = rest[0] || 'pair';

class CliError extends Error { constructor(public code: 'BAD_ARGS' | 'NOT_FOUND' | 'UNAVAILABLE' | 'INTERNAL', message: string) { super(message); } }
const flag = (name: string): string | undefined => {
  const i = rest.indexOf(`--${name}`);
  if (i < 0) return undefined;
  const v = rest[i + 1];
  if (v === undefined || v.startsWith('--')) throw new CliError('BAD_ARGS', `--${name} needs a value.`);
  return v;
};
const out = (o: object) => console.log(JSON.stringify({ contract: 1, ...o }));

function version(): string {
  try { return JSON.parse(readFileSync(new URL('../../../package.json', import.meta.url), 'utf8')).version ?? '0.0.0'; } catch { return '0.0.0'; }
}

function runJson() {
  switch (command) {
    case 'status': return out({ utility: 'nexuslink', version: version(), hostId: hostId(), devices: deviceCount(), fingerprint: null });
    case 'invite': {
      const ttlRaw = flag('ttl') ?? '300';
      const ttl = Number(ttlRaw);
      if (!/^\d+$/.test(ttlRaw) || ttl < 60 || ttl > 900) throw new CliError('BAD_ARGS', '--ttl must be an integer between 60 and 900.');
      const label = flag('label') ?? '';
      if (label.length > 100) throw new CliError('BAD_ARGS', '--label must be at most 100 characters.');
      const inv = createInvite(ttl * 1000);
      return out({ inviteId: inv.inviteId, secret: inv.code, expiresAt: inv.expiresAt, fingerprint: null, hostId: hostId() });
    }
    case 'devices': return out({ devices: listDevicesDetailed() });
    case 'revoke': {
      if (!rest[1]) throw new CliError('BAD_ARGS', 'revoke needs a device id.');
      if (!revokeDevice(rest[1])) throw new CliError('NOT_FOUND', 'No such device.');
      return out({ revoked: true });
    }
    default: throw new CliError('BAD_ARGS', `Unknown subcommand: ${command.slice(0, 40)}`);
  }
}

if (json) {
  try { runJson(); }
  catch (e) {
    const err = e instanceof CliError ? e : new CliError('INTERNAL', e instanceof Error ? e.message : 'Internal error');
    out({ error: { code: err.code, message: err.message } });
    process.exitCode = 1;
  }
} else if (command === 'pair') console.log(`NexusLink pairing code: ${enableEnrollment()}\nExpires in five minutes; can be used once.`);
else if (command === 'list') console.table(listDevices());
else if (command === 'revoke' && rest[1]) { revokeDevice(rest[1]); console.log('Device revoked.'); }
else { console.error('Usage: device-cli.ts pair | list | revoke <device-id>'); process.exitCode = 1; }
