export type ProcessEntry = {
  pid: number;
  name: string;
  cpuPercent: number;
  memMb: number;
};

export async function listProcesses(): Promise<ProcessEntry[]> {
  try {
    const proc = Bun.spawnSync(['ps', '-eo', 'pid=,comm=,pcpu=,pmem=']);
    const text = proc.stdout.toString('utf-8');
    const lines = text.split('\n').filter((line) => line.trim().length > 0);
    const entries: ProcessEntry[] = [];
    for (const line of lines) {
      const parts = line.trim().split(/\s+/);
      if (parts.length < 4) continue;
      const pid = Number(parts[0]);
      const cpuPercent = Number(parts[2]);
      const memRaw = parts[3].replace('%', '');
      const memPercent = Number(memRaw);
      const memMb = Math.round((memPercent / 100) * (await getTotalMemoryMB()));
      entries.push({
        pid,
        name: parts[1],
        cpuPercent: isNaN(cpuPercent) ? 0 : cpuPercent,
        memMb: isNaN(memMb) ? 0 : memMb,
      });
    }
    return entries;
  } catch {
    return [];
  }
}

async function getTotalMemoryMB(): Promise<number> {
  try {
    const text = await Bun.file('/proc/meminfo').text();
    const match = text.match(/MemTotal:\s+(\d+)\s+kB/);
    if (!match) return 0;
    return Number(match[1]) / 1024;
  } catch {
    return 0;
  }
}
