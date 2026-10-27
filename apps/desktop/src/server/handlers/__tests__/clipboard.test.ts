// A frozen selection owner makes `xclip -o` hang forever; reads must be bounded.
// A fake xclip on PATH stands in for both the hung and the healthy case.
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CLIPBOARD_TIMEOUT_MS, getClipboard, readClipboard } from '../clipboard';

const bin = mkdtempSync(join(tmpdir(), 'nl-fake-xclip-'));
const realPath = process.env.PATH;
const fake = (script: string) => {
  writeFileSync(join(bin, 'xclip'), `#!/bin/sh\n${script}\n`);
  chmodSync(join(bin, 'xclip'), 0o755);
};
beforeAll(() => { process.env.PATH = `${bin}:${realPath}`; });
afterAll(() => { process.env.PATH = realPath; rmSync(bin, { recursive: true, force: true }); });

describe('clipboard reads are bounded', () => {
  test('sync read gives up on a hung selection owner', () => {
    fake('exec sleep 20');
    const t0 = Date.now();
    const r = getClipboard();
    expect(Date.now() - t0).toBeLessThan(CLIPBOARD_TIMEOUT_MS + 1500);
    expect(r.text).toBe('');
    expect(r.timedOut).toBe(true);
  });

  test('async read gives up on a hung selection owner without blocking the loop', async () => {
    fake('exec sleep 20');
    let ticks = 0;
    const iv = setInterval(() => ticks++, 50);
    const t0 = Date.now();
    const r = await readClipboard(undefined, 400);
    clearInterval(iv);
    expect(Date.now() - t0).toBeLessThan(2000);
    expect(r.timedOut).toBe(true);
    expect(ticks).toBeGreaterThan(3);
  });

  test('healthy reads return the text', async () => {
    fake("printf 'héllo clipboard'");
    expect(getClipboard().text).toBe('héllo clipboard');
    expect((await readClipboard()).text).toBe('héllo clipboard');
  });
});
