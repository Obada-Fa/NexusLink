// fs.delete / fs.move for the phone: guarded, no-clobber, Trash-first, cross-filesystem safe.
import { afterAll, afterEach, describe, expect, test } from 'bun:test';
import { existsSync, mkdtempSync, statSync } from 'node:fs';
import { lstat, mkdir, readFile, readlink, readdir, rename, rm, stat, symlink, utimes, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { deleteEntry, moveEntry, renameFile, setTrashRunnerForTests } from './files';
import { handleFsRead } from '../handlers/fs';

const root = mkdtempSync(join(tmpdir(), 'nl-move-delete-'));
const shm = existsSync('/dev/shm') ? mkdtempSync('/dev/shm/nl-move-') : null;
const crossFs = !!shm && statSync(shm).dev !== statSync(root).dev;
afterAll(async () => {
  setTrashRunnerForTests(null);
  await rm(root, { recursive: true, force: true });
  if (shm) await rm(shm, { recursive: true, force: true });
});
afterEach(() => setTrashRunnerForTests(null));
let n = 0;
const fresh = async () => { const d = join(root, `case-${n++}`); await mkdir(d); return d; };
const noTrash = () => setTrashRunnerForTests(async () => false);

describe('moveEntry', () => {
  test('renames files and folders without clobbering', async () => {
    const d = await fresh();
    await writeFile(join(d, 'a.txt'), 'A');
    await writeFile(join(d, 'b.txt'), 'B');
    await expect(moveEntry(join(d, 'a.txt'), join(d, 'b.txt'))).rejects.toMatchObject({ code: 'EXISTS' });
    expect(await readFile(join(d, 'b.txt'), 'utf8')).toBe('B');
    expect(await moveEntry(join(d, 'a.txt'), join(d, 'c.txt'))).toEqual({ path: join(d, 'c.txt') });
    expect(await readFile(join(d, 'c.txt'), 'utf8')).toBe('A');
    await mkdir(join(d, 'dir/sub'), { recursive: true });
    await writeFile(join(d, 'dir/sub/x'), 'x');
    await moveEntry(join(d, 'dir'), join(d, 'renamed'));
    expect(await readFile(join(d, 'renamed/sub/x'), 'utf8')).toBe('x');
    await mkdir(join(d, 'taken'));
    await expect(moveEntry(join(d, 'renamed'), join(d, 'taken'))).rejects.toMatchObject({ code: 'EXISTS' });
    expect(existsSync(join(d, 'renamed/sub/x'))).toBe(true);
    // fs.rename (renameFile) now shares this path, so folders work too.
    await renameFile(join(d, 'renamed'), join(d, 'again'));
    expect(existsSync(join(d, 'again/sub/x'))).toBe(true);
  });

  test('refuses protected paths and moving a folder into itself', async () => {
    const d = await fresh();
    await mkdir(join(d, 'p'));
    await expect(moveEntry(join(d, 'p'), join(d, 'p/inner'))).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' });
    for (const p of ['/', '/tmp', homedir()]) await expect(moveEntry(p, join(d, 'stolen'))).rejects.toMatchObject({ code: 'PERMISSION_DENIED' });
  });

  test.if(crossFs)('moves files, symlinks and folders across filesystems', async () => {
    const d = await fresh();
    await writeFile(join(d, 'f.bin'), 'cross');
    await utimes(join(d, 'f.bin'), new Date(1_600_000_000_000), new Date(1_600_000_000_000));
    await symlink('../nowhere', join(d, 'link'));
    await mkdir(join(d, 'tree/deep'), { recursive: true });
    await writeFile(join(d, 'tree/deep/leaf'), 'leaf');
    await moveEntry(join(d, 'f.bin'), join(shm!, 'f.bin'));
    expect(await readFile(join(shm!, 'f.bin'), 'utf8')).toBe('cross');
    expect((await stat(join(shm!, 'f.bin'))).mtimeMs).toBe(1_600_000_000_000);
    expect(existsSync(join(d, 'f.bin'))).toBe(false);
    await moveEntry(join(d, 'link'), join(shm!, 'link'));
    expect(await readlink(join(shm!, 'link'))).toBe('../nowhere');
    await moveEntry(join(d, 'tree'), join(shm!, 'tree'));
    expect(await readFile(join(shm!, 'tree/deep/leaf'), 'utf8')).toBe('leaf');
    expect(existsSync(join(d, 'tree'))).toBe(false);
    await writeFile(join(d, 'dup'), 'mine');
    await writeFile(join(shm!, 'dup'), 'theirs');
    await expect(moveEntry(join(d, 'dup'), join(shm!, 'dup'))).rejects.toMatchObject({ code: 'EXISTS' });
    expect(await readFile(join(shm!, 'dup'), 'utf8')).toBe('theirs');
    expect(await readFile(join(d, 'dup'), 'utf8')).toBe('mine');
    expect((await readdir(shm!)).some((name) => name.includes('nlmove'))).toBe(false);
  });
});

describe('deleteEntry', () => {
  test('uses the Trash when available', async () => {
    const d = await fresh();
    const trash = join(d, '.trash');
    await mkdir(trash);
    // Like gio: a plain rename into the trash dir (it does not take our path locks).
    setTrashRunnerForTests(async (p) => { await rename(p, join(trash, `t${Math.random()}`)); return true; });
    await mkdir(join(d, 'full'));
    await writeFile(join(d, 'full/x'), 'x');
    expect(await deleteEntry(join(d, 'full'), { recursive: true })).toMatchObject({ ok: true, trashed: true });
    expect(existsSync(join(d, 'full'))).toBe(false);
    expect((await readdir(trash)).length).toBe(1);
  });

  test('without a Trash removes files and empty folders only', async () => {
    noTrash();
    const d = await fresh();
    await writeFile(join(d, 'f'), 'f');
    expect(await deleteEntry(join(d, 'f'))).toMatchObject({ ok: true, trashed: false });
    expect(existsSync(join(d, 'f'))).toBe(false);
    await mkdir(join(d, 'empty'));
    await deleteEntry(join(d, 'empty'));
    expect(existsSync(join(d, 'empty'))).toBe(false);
    await mkdir(join(d, 'full'));
    await writeFile(join(d, 'full/keep'), 'k');
    await expect(deleteEntry(join(d, 'full'))).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' });
    await expect(deleteEntry(join(d, 'full'), { recursive: true })).rejects.toMatchObject({ code: 'UNSUPPORTED' });
    expect(await readFile(join(d, 'full/keep'), 'utf8')).toBe('k');
  });

  test('deletes a symlink, never its target', async () => {
    noTrash();
    const d = await fresh();
    await mkdir(join(d, 'target'));
    await writeFile(join(d, 'target/keep'), 'k');
    await symlink(join(d, 'target'), join(d, 'link'));
    await deleteEntry(join(d, 'link'));
    expect(existsSync(join(d, 'link'))).toBe(false);
    expect(await readFile(join(d, 'target/keep'), 'utf8')).toBe('k');
  });

  test('refuses /, top-level folders, $HOME and relative paths', async () => {
    let calls = 0;
    setTrashRunnerForTests(async () => { calls++; return false; });
    for (const p of ['/', '/tmp', '/home', homedir(), '~']) await expect(deleteEntry(p, { recursive: true })).rejects.toMatchObject({ code: 'PERMISSION_DENIED' });
    await expect(deleteEntry('relative/path')).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' });
    expect(calls).toBe(0);
    expect((await lstat(homedir())).isDirectory()).toBe(true);
  });
});

test('fs.read refuses FIFOs instead of hanging', async () => {
  const d = await fresh();
  const fifo = join(d, 'pipe');
  expect(Bun.spawnSync(['mkfifo', fifo]).exitCode).toBe(0);
  await expect(handleFsRead(fifo)).rejects.toThrow(/Not a regular file/);
});
