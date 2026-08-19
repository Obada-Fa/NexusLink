export type ProcessEntry = {
  pid: number;
  name: string;
  cpuPercent: number;
  memMb: number;
};

/** Parse `tasklist /FO CSV /NH` lines like `"chrome.exe","1234","Console","1","120,456 K"`. */
export function parseTasklistCsv(text: string): ProcessEntry[] {
  const entries: ProcessEntry[] = [];
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const cols: string[] = [];
    const re = /"([^"]*)"/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(trimmed))) cols.push(m[1] ?? '');
    if (cols.length < 5) continue;
    const name = cols[0] ?? '';
    const pid = Number(cols[1]);
    const memRaw = (cols[4] ?? '').replace(/[^\d]/g, '');
    const memKb = Number(memRaw);
    if (!name || !Number.isFinite(pid)) continue;
    entries.push({
      pid,
      name,
      cpuPercent: 0,
      memMb: Number.isFinite(memKb) ? Math.round(memKb / 1024) : 0,
    });
  }
  return entries;
}

export async function listProcesses(): Promise<ProcessEntry[]> {
  try {
    const proc = Bun.spawnSync(['tasklist', '/FO', 'CSV', '/NH'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    if (proc.exitCode !== 0) return [];
    return parseTasklistCsv(proc.stdout.toString('utf-8'));
  } catch {
    return [];
  }
}

export function killProcess(pid: number): void {
  if (!Number.isFinite(pid) || pid <= 0) throw new Error('invalid pid');
  Bun.spawnSync(['taskkill', '/PID', String(pid), '/F'], {
    stdout: 'ignore',
    stderr: 'ignore',
  });
}
