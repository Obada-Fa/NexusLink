import type { SystemInfo, PerfSnapshot } from '@nexuslink/rpc-types';

async function readProc(path: string): Promise<string> {
  return Bun.file(path).text();
}

function parseCpuModel(cpuinfo: string): string {
  const m = cpuinfo.match(/model name\s*:\s*(.+)/i);
  return m ? m[1].trim() : 'unknown';
}

let prevCpu: { idle: number; total: number } | null = null;

function parseCpuStat(stat: string): { idle: number; total: number } {
  const lines = stat.split('\n');
  for (const line of lines) {
    if (line.startsWith('cpu ')) {
      const parts = line.trim().split(/\s+/).slice(1).map(Number);
      const total = parts.reduce((a, b) => a + b, 0);
      const idle = parts[3] + (parts[4] || 0); // idle + iowait
      return { idle, total };
    }
  }
  return { idle: 0, total: 0 };
}

export async function getSystemInfo(): Promise<SystemInfo> {
  const [cpuinfo, meminfo, uptime, hostname] = await Promise.all([
    readProc('/proc/cpuinfo').catch(() => ''),
    readProc('/proc/meminfo').catch(() => ''),
    readProc('/proc/uptime').catch(() => '0 0'),
    readProc('/proc/sys/kernel/hostname').catch(() => 'unknown'),
  ]);

  const memTotalMatch = meminfo.match(/MemTotal:\s+(\d+)\s+kB/);
  const totalRamGb = memTotalMatch ? Math.round((Number(memTotalMatch[1]) / 1024 / 1024) * 10) / 10 : 0;

  const uptimeSeconds = Math.round(Number(uptime.split(' ')[0])) || 0;

  const userEnv = Bun.env;
  const user = userEnv.USER || userEnv.LOGNAME || 'unknown';
  const home = userEnv.HOME || '/home/' + user;

  return {
    os: 'Linux',
    hostname: hostname.trim() || 'unknown',
    cpuModel: parseCpuModel(cpuinfo),
    totalRamGb,
    uptimeSeconds,
    username: user,
    homeDir: home,
  };
}

export async function getPerfSnapshot(): Promise<PerfSnapshot> {
  const [stat, meminfo, netdev, uptime] = await Promise.all([
    readProc('/proc/stat').catch(() => ''),
    readProc('/proc/meminfo').catch(() => ''),
    readProc('/proc/net/dev').catch(() => ''),
    readProc('/proc/uptime').catch(() => '0 0'),
  ]);

  const memTotalMatch = meminfo.match(/MemTotal:\s+(\d+)\s+kB/);
  const memAvailMatch = meminfo.match(/MemAvailable:\s+(\d+)\s+kB/);
  const totalKb = memTotalMatch ? Number(memTotalMatch[1]) : 0;
  const availKb = memAvailMatch ? Number(memAvailMatch[1]) : 0;
  const usedKb = totalKb - availKb;
  const ramUsedGb = Math.round((usedKb / 1024 / 1024) * 100) / 100;
  const ramPercent = totalKb > 0 ? Math.round((usedKb / totalKb) * 100) / 100 : 0;

  const current = parseCpuStat(stat);
  let cpuPercent = 0;
  if (prevCpu && current.total > prevCpu.total) {
    const idleDelta = current.idle - prevCpu.idle;
    const totalDelta = current.total - prevCpu.total;
    cpuPercent = Math.round((1 - idleDelta / totalDelta) * 10000) / 100;
  }
  prevCpu = current;

  let netInKBs = 0;
  let netOutKBs = 0;
  const devLines = netdev.split('\n').slice(2);
  for (const line of devLines) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 10) continue;
    const iface = parts[0].replace(':', '');
    if (iface === 'lo') continue;
    netInKBs += Number(parts[1]) / 1024;
    netOutKBs += Number(parts[9]) / 1024;
  }
  netInKBs = Math.round(netInKBs * 100) / 100;
  netOutKBs = Math.round(netOutKBs * 100) / 100;

  return {
    cpuPercent,
    ramPercent,
    ramUsedGb,
    netInKBs,
    netOutKBs,
    diskReadMBs: 0,
    diskWriteMBs: 0,
  };
}
