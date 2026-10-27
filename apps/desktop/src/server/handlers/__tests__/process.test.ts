import { describe, expect, test } from 'bun:test';
import { displayName, killProcess, listProcesses } from '../process';

const waitExit = (p: { exited: Promise<number> }, ms = 3000) =>
  Promise.race([p.exited.then(() => true), new Promise<boolean>((r) => setTimeout(() => r(false), ms))]);

describe('process.list', () => {
  test('returns current-CPU entries with full names, sorted and limited', async () => {
    const all = await listProcesses({ limit: 1000 });
    expect(all.length).toBeGreaterThan(3);
    for (let i = 1; i < all.length; i++) expect(all[i - 1]!.cpuPercent).toBeGreaterThanOrEqual(all[i]!.cpuPercent);
    const self = all.find((p) => p.pid === process.pid);
    expect(self).toBeDefined();
    expect(self!.own).toBe(true);
    expect(self!.rssBytes).toBeGreaterThan(0);
    expect(self!.memMb).toBeCloseTo(self!.rssBytes / 1048576, 0);
    expect(self!.command.length).toBeGreaterThan(0);
    expect((await listProcesses({ limit: 5 })).length).toBe(5);
    expect((await listProcesses()).length).toBeLessThanOrEqual(200);
  });

  test('displayName expands truncated comm from argv[0]', () => {
    expect(displayName('gnome-session-b', ['/usr/libexec/gnome-session-binary', '--x'])).toBe('gnome-session-binary');
    expect(displayName('python3', ['/usr/bin/python3', 'x.py'])).toBe('python3');
    expect(displayName('Web Content', ['/usr/lib/firefox/firefox'])).toBe('Web Content');
    expect(displayName('kworker/0:1', [])).toBe('kworker/0:1');
  });
});

describe('process.kill', () => {
  test('refuses pid 1, the host itself, its ancestors and invalid pids', async () => {
    for (const pid of [1, process.pid, process.ppid, 0, -5, 1.5]) {
      const r = await killProcess(pid);
      expect(r.ok).toBe(false);
    }
  });

  test("refuses other users' processes and kernel threads", async () => {
    const r = await killProcess(2); // kthreadd, root-owned
    expect(r.ok).toBe(false);
    expect(r.message).toMatch(/another user|Kernel/);
  });

  test('stops an own process with SIGTERM', async () => {
    const child = Bun.spawn(['sleep', '30'], { stdout: 'ignore', stderr: 'ignore' });
    const r = await killProcess(child.pid, false, { graceMs: 2000 });
    expect(r.ok).toBe(true);
    expect(r.signal).toBe('SIGTERM');
    expect(r.exited).toBe(true);
    expect(await waitExit(child)).toBe(true);
  });

  test('escalates to SIGKILL only when forced', async () => {
    // exec keeps a single process that ignores SIGTERM.
    const child = Bun.spawn(['sh', '-c', "trap '' TERM; exec sleep 30"], { stdout: 'ignore', stderr: 'ignore' });
    await new Promise((r) => setTimeout(r, 150));
    const soft = await killProcess(child.pid, false, { graceMs: 300 });
    expect(soft.ok).toBe(true);
    expect(soft.exited).toBe(false);
    const hard = await killProcess(child.pid, true, { graceMs: 300 });
    expect(hard.ok).toBe(true);
    expect(hard.signal).toBe('SIGKILL');
    expect(await waitExit(child)).toBe(true);
  });

  test('reports a pid that does not exist', async () => {
    // Above pid_max, so it can never be reused by a live process mid-test.
    const pidMax = Number((await Bun.file('/proc/sys/kernel/pid_max').text()).trim());
    const r = await killProcess(pidMax + 1);
    expect(r.ok).toBe(false);
    expect(r.message).toMatch(/No such process/);
  });
});
