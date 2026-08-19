import { cpus, freemem, homedir, hostname, totalmem, uptime, userInfo, type CpuInfo } from 'node:os';
import type { SystemInfo, PerfSnapshot } from '@nexuslink/rpc-types';

function osLabel(): string {
  if (process.platform === 'win32') return 'Windows';
  if (process.platform === 'darwin') return 'macOS';
  return 'Linux';
}

function cpuTimes(list: CpuInfo[]): { idle: number; total: number } {
  let idle = 0;
  let total = 0;
  for (const c of list) {
    const t = c.times;
    idle += t.idle;
    total += t.user + t.nice + t.sys + t.idle + t.irq;
  }
  return { idle, total };
}

let prevCpu: { idle: number; total: number } | null = null;

export async function getSystemInfo(): Promise<SystemInfo> {
  let username = process.env.USERNAME || process.env.USER || process.env.LOGNAME || 'unknown';
  let home = homedir();
  try {
    const u = userInfo();
    username = u.username || username;
    home = u.homedir || home;
  } catch {
    // userInfo() can throw if the account has no homedir entry
  }

  return {
    os: osLabel(),
    hostname: hostname(),
    cpuModel: cpus()[0]?.model?.trim() || 'unknown',
    totalRamGb: Math.round((totalmem() / 1024 / 1024 / 1024) * 10) / 10,
    uptimeSeconds: Math.round(uptime()),
    username,
    homeDir: home.replace(/\\/g, '/'),
  };
}

export async function getPerfSnapshot(): Promise<PerfSnapshot> {
  const total = totalmem();
  const free = freemem();
  const used = Math.max(0, total - free);
  const ramUsedGb = Math.round((used / 1024 / 1024 / 1024) * 100) / 100;
  const ramPercent = total > 0 ? Math.round((used / total) * 100) / 100 : 0;

  const current = cpuTimes(cpus());
  let cpuPercent = 0;
  if (prevCpu && current.total > prevCpu.total) {
    const idleDelta = current.idle - prevCpu.idle;
    const totalDelta = current.total - prevCpu.total;
    cpuPercent = Math.round((1 - idleDelta / totalDelta) * 10000) / 100;
  }
  prevCpu = current;

  return {
    cpuPercent,
    ramPercent,
    ramUsedGb,
    netInKBs: 0,
    netOutKBs: 0,
    diskReadMBs: 0,
    diskWriteMBs: 0,
  };
}
