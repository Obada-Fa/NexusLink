// scripts/deploy-host.sh defers the host restart while Nexus agent turns run.
// systemctl, journalctl and systemd-run are stand-ins that only log; nothing
// touches the real service.
import { afterAll, beforeAll, expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const script = join(import.meta.dir, '..', '..', '..', '..', '..', '..', 'scripts', 'deploy-host.sh');
const root = mkdtempSync(join(tmpdir(), 'nexuslink-deploy-defer-'));
const bin = join(root, 'bin');
const data = join(root, 'data');
const runtime = join(root, 'runtime');
const log = join(root, 'calls.log');
const marker = join(data, 'busy-turns.json');

beforeAll(() => {
  mkdirSync(bin, { recursive: true });
  mkdirSync(data, { recursive: true });
  for (const name of ['systemctl', 'systemd-run']) {
    writeFileSync(join(bin, name), `#!/bin/sh\necho "${name} $*" >> "${log}"\nexit 0\n`);
    chmodSync(join(bin, name), 0o755);
  }
  writeFileSync(join(bin, 'journalctl'), `#!/bin/sh\necho "[rpc-server] listening on 0.0.0.0"\n`);
  chmodSync(join(bin, 'journalctl'), 0o755);
  mkdirSync(join(runtime, 'releases', '20260101-000000'), { recursive: true });
  mkdirSync(join(runtime, 'releases', '20260102-000000'), { recursive: true });
  symlinkSync(join(runtime, 'releases', '20260102-000000'), join(runtime, 'current'));
});

afterAll(() => rmSync(root, { recursive: true, force: true }));

function env(extra: Record<string, string> = {}): Record<string, string> {
  const base: Record<string, string> = {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: root,
    NEXUSLINK_DATA_DIR: data,
    NEXUSLINK_RUNTIME_DIR: runtime,
    NEXUSLINK_LAUNCHER: join(root, 'launcher'),
    NEXUSLINK_DEFER_POLL_SECONDS: '0.05',
    NEXUSLINK_DEFER_MAX_SECONDS: '20',
  };
  return { ...base, ...extra };
}
const calls = () => (existsSync(log) ? readFileSync(log, 'utf8') : '');
const reset = () => writeFileSync(log, '');

test('the deferred job waits until no turn runs, then restarts', async () => {
  reset();
  writeFileSync(marker, JSON.stringify({ busy: 1, pid: process.pid, ts: Date.now() }));
  const proc = Bun.spawn(['/bin/bash', script, '--restart-when-idle', '-', 'test-release'], { env: env(), stdout: 'pipe', stderr: 'pipe' });
  await Bun.sleep(600);
  expect(calls()).not.toContain('restart nexuslink.service');
  writeFileSync(marker, JSON.stringify({ busy: 0, pid: process.pid, ts: Date.now() }));
  expect(await proc.exited).toBe(0);
  expect(calls()).toContain('systemctl --user restart nexuslink.service');
  expect(await new Response(proc.stdout).text()).toContain('restarted from test-release');
});

test('a marker left by a host that is gone counts as idle', async () => {
  reset();
  writeFileSync(marker, JSON.stringify({ busy: 2, pid: 999_999_999, ts: Date.now() }));
  const proc = Bun.spawn(['/bin/bash', script, '--restart-when-idle', '-', 'x'], { env: env(), stdout: 'ignore', stderr: 'ignore' });
  expect(await proc.exited).toBe(0);
  expect(calls()).toContain('restart nexuslink.service');
});

test('inside an agent turn the restart is handed to systemd-run', () => {
  reset();
  const out = Bun.spawnSync(['/bin/bash', script, '--rollback'], { env: env({ NEXUSLINK_AGENT_TURN: '1' }) });
  expect(out.exitCode).toBe(0);
  const text = calls();
  expect(text).not.toContain('restart nexuslink.service');
  expect(text).toMatch(/systemd-run --user --quiet --collect --unit=nexuslink-deferred-restart-\S+ .*--restart-when-idle - the rolled-back release/);
  expect(text).toContain(`--setenv=NEXUSLINK_DATA_DIR=${data}`);
  expect(out.stdout.toString()).toContain('restarts once no agent turn is running');
});

test('--now restarts at once even inside a turn', () => {
  reset();
  const out = Bun.spawnSync(['/bin/bash', script, '--rollback', '--now'], { env: env({ NEXUSLINK_AGENT_TURN: '1' }) });
  expect(out.exitCode).toBe(0);
  expect(calls()).toContain('systemctl --user restart nexuslink.service');
  expect(calls()).not.toContain('systemd-run');
});
