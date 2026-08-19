import { describe, expect, test } from 'bun:test';
import { homedir } from 'node:os';
import {
  expandHostPath,
  handleFsList,
  isThisPcPath,
  listDriveEntries,
  parseGitStatusPorcelain,
  toPosixPath,
} from '../fs';

describe('expandHostPath', () => {
  const home = homedir();

  test('maps empty and tilde to the user profile', () => {
    expect(expandHostPath('')).toBe(home);
    expect(expandHostPath('~')).toBe(home);
  });

  test('does not map slash to the user profile', () => {
    expect(isThisPcPath('/')).toBe(true);
    expect(isThisPcPath('This PC')).toBe(true);
    expect(() => expandHostPath('/')).toThrow(/This PC/);
  });

  test('maps /home to the user profile', () => {
    expect(expandHostPath('/home')).toBe(home);
    expect(expandHostPath('/home/someone')).toBe(home);
  });

  test('keeps a drive-qualified Windows path', () => {
    if (process.platform !== 'win32') return;
    expect(expandHostPath('D:/projects/mobile').toLowerCase()).toBe('d:\\projects\\mobile');
    expect(expandHostPath('C:')).toBe('C:\\');
  });
});

describe('This PC listing', () => {
  test('lists drive letters as folders', async () => {
    if (process.platform !== 'win32') return;
    const entries = await handleFsList('/');
    expect(entries.length).toBeGreaterThan(0);
    expect(entries.every((e) => e.isDirectory)).toBe(true);
    expect(entries.some((e) => /^[A-Z]:$/.test(e.name) && e.path.endsWith(':/'))).toBe(true);
    const synthetic = listDriveEntries();
    expect(synthetic.length).toBe(entries.length);
  });
});

describe('toPosixPath', () => {
  test('converts backslashes', () => {
    expect(toPosixPath('C:\\Users\\a')).toBe('C:/Users/a');
  });
});

describe('parseGitStatusPorcelain', () => {
  test('reads branch and files', () => {
    const parsed = parseGitStatusPorcelain('## main...origin/main [ahead 1]\n M foo.ts\n?? bar.ts\n');
    expect(parsed?.branch).toBe('main');
    expect(parsed?.ahead).toBe(1);
    expect(parsed?.changed).toBe(2);
    expect(parsed?.files).toEqual(['foo.ts', 'bar.ts']);
  });
});
