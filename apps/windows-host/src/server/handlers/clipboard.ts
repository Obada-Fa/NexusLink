function psQuote(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

function ps(command: string): string {
  const proc = Bun.spawnSync(
    ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command],
    { stdout: 'pipe', stderr: 'pipe' },
  );
  return proc.stdout?.toString('utf-8') ?? '';
}

export function getClipboard(): { text: string } {
  try {
    return { text: ps('Get-Clipboard -Raw') };
  } catch {
    return { text: '' };
  }
}

export function setClipboard(text: string): { ok: boolean } {
  try {
    const payload = text ?? '';
    if (payload.length > 256 * 1024) throw new Error('clipboard too large');
    ps(`Set-Clipboard -Value ${psQuote(payload)}`);
    return { ok: true };
  } catch {
    return { ok: false };
  }
}
