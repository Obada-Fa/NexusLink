import { describe, expect, test } from 'bun:test';
import { parseGitStatusPorcelain } from '../fs';

describe('parseGitStatusPorcelain', () => {
  test('reads branch, ahead, and changed files', () => {
    const parsed = parseGitStatusPorcelain(`## main...origin/main [ahead 40]
 M apps/flutter_client/lib/src/screens/agent_screen.dart
?? apps/mobile-client/src/lib/agent-history.ts
`);
    expect(parsed).toEqual({
      branch: 'main',
      ahead: 40,
      behind: 0,
      changed: 2,
      files: [
        'apps/flutter_client/lib/src/screens/agent_screen.dart',
        'apps/mobile-client/src/lib/agent-history.ts',
      ],
    });
  });

  test('returns null for empty or non-git output', () => {
    expect(parseGitStatusPorcelain('')).toBeNull();
    expect(parseGitStatusPorcelain('not a git status')).toBeNull();
  });

  test('treats a clean branch as zero changes', () => {
    expect(parseGitStatusPorcelain('## feat/plus')).toEqual({
      branch: 'feat/plus',
      ahead: 0,
      behind: 0,
      changed: 0,
      files: [],
    });
  });
});

describe('handleFsRead', () => {
  test('reads an existing file by path and strips file:// prefix', async () => {
    const { handleFsRead } = await import('../fs');
    const content = await handleFsRead(`file://${process.cwd()}/package.json`);
    expect(content).toContain('"name"');
  });

  test('throws for non-existent file or directory', async () => {
    const { handleFsRead } = await import('../fs');
    expect(handleFsRead('/tmp/non_existent_file_xyz_123.txt')).rejects.toThrow();
    expect(handleFsRead('/tmp')).rejects.toThrow();
  });
});

describe('handleFsMkdir', () => {
  test('creates a directory recursively and returns POSIX path and name', async () => {
    const { handleFsMkdir } = await import('../fs');
    const { existsSync, rmSync } = await import('node:fs');
    const testDir = `/tmp/test-nexuslink-mkdir-${Date.now()}/nested/folder`;
    try {
      const res = await handleFsMkdir(testDir);
      expect(res.name).toBe('folder');
      expect(res.path).toBe(testDir);
      expect(existsSync(testDir)).toBe(true);
    } finally {
      try { rmSync(`/tmp/test-nexuslink-mkdir-${Date.now()}`, { recursive: true, force: true }); } catch {}
    }
  });
});

describe('findGitRoot', () => {
  test('finds repository root from nested subdirectory', async () => {
    const { findGitRoot } = await import('../fs');
    const nested = `${process.cwd()}/src/server/handlers`;
    const root = findGitRoot(nested);
    expect(root.endsWith('opendesktop') || root.includes('opendesktop')).toBe(true);
  });

  test('returns original path if not inside a git repo', async () => {
    const { findGitRoot } = await import('../fs');
    const tmp = '/tmp';
    expect(findGitRoot(tmp)).toBe('/tmp');
  });
});
