// Clipboard sync between the phone and any X display (the real desktop or a
// virtual app session) via xclip.

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

const DEFAULT_DISPLAY = process.env.DISPLAY || ':0';

export function getClipboard(display?: string): { text: string } {
  try {
    const out = Bun.spawnSync(['xclip', '-selection', 'clipboard', '-o'], {
      env: { ...process.env, DISPLAY: display || DEFAULT_DISPLAY },
      stderr: 'ignore',
    } as unknown as SpawnOpts);
    return { text: out.exitCode === 0 ? out.stdout?.toString() ?? '' : '' };
  } catch {
    return { text: '' };
  }
}

export function setClipboard(text: string, display?: string): { ok: boolean } {
  try {
    const proc = Bun.spawn(['xclip', '-selection', 'clipboard'], {
      stdin: 'pipe',
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY: display || DEFAULT_DISPLAY },
    } as unknown as SpawnOpts);
    const stdin = proc.stdin as unknown as { write(s: string): unknown; end(): void };
    stdin.write(text ?? '');
    stdin.end();
    return { ok: true };
  } catch {
    return { ok: false };
  }
}
