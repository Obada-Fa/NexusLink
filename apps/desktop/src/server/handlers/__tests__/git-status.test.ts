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
