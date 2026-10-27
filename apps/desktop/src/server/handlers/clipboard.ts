// Clipboard sync between the phone and any X display (the real desktop or a
// virtual app session) via xclip.
//
// Reading the X clipboard asks the selection owner for its contents; a frozen
// owner never answers and `xclip -o` would wait forever. Every read is bounded.

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type SpawnSyncOpts = Parameters<typeof Bun.spawnSync>[1];

const DEFAULT_DISPLAY = process.env.DISPLAY || ':0';
export const CLIPBOARD_TIMEOUT_MS = 1500;
/** Larger payloads would risk the control socket's 4 MB "too slow" limit. */
export const CLIPBOARD_MAX_CHARS = 1_000_000;

type ClipboardText = { text: string; truncated?: boolean; timedOut?: boolean };

function capped(text: string): ClipboardText {
  return text.length > CLIPBOARD_MAX_CHARS ? { text: text.slice(0, CLIPBOARD_MAX_CHARS), truncated: true } : { text };
}

/** Synchronous read, killed after CLIPBOARD_TIMEOUT_MS (blocks the event loop at most that long). */
export function getClipboard(display?: string): ClipboardText {
  try {
    const out = Bun.spawnSync(['xclip', '-selection', 'clipboard', '-o'], {
      env: { ...process.env, DISPLAY: display || DEFAULT_DISPLAY },
      stdout: 'pipe',
      stderr: 'ignore',
      timeout: CLIPBOARD_TIMEOUT_MS,
      killSignal: 'SIGKILL',
    } as unknown as SpawnSyncOpts);
    if (out.exitCode !== 0) return { text: '', ...(out.exitCode === null ? { timedOut: true } : {}) };
    return capped(out.stdout?.toString() ?? '');
  } catch {
    return { text: '' };
  }
}

/**
 * Non-blocking read (preferred): index.ts can use
 * `result = await readClipboard(inputDisplay)` instead of getClipboard().
 */
export async function readClipboard(display?: string, timeoutMs = CLIPBOARD_TIMEOUT_MS): Promise<ClipboardText> {
  let proc: ReturnType<typeof Bun.spawn>;
  try {
    proc = Bun.spawn(['xclip', '-selection', 'clipboard', '-o'], {
      env: { ...process.env, DISPLAY: display || DEFAULT_DISPLAY },
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'ignore',
    } as unknown as SpawnOpts);
  } catch {
    return { text: '' };
  }
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; try { proc.kill('SIGKILL'); } catch { /* gone */ } }, timeoutMs);
  try {
    const [text, code] = await Promise.all([new Response(proc.stdout as ReadableStream).text(), proc.exited]);
    if (timedOut) return { text: '', timedOut: true };
    return code === 0 ? capped(text) : { text: '' };
  } catch {
    return { text: '', ...(timedOut ? { timedOut: true } : {}) };
  } finally {
    clearTimeout(timer);
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
