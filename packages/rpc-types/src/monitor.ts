/** Mission-control contracts: PC vitals, running agent apps, remote-access health. */
export interface GpuVitals {
  id: string; name: string; vendor: 'amd' | 'intel' | 'nvidia' | 'other'; integrated: boolean;
  busyPercent: number | null; memBusyPercent: number | null;
  vramUsedBytes: number | null; vramTotalBytes: number | null;
  tempC: number | null; hotspotC: number | null; memTempC: number | null;
  powerW: number | null; powerCapW: number | null; fanRpm: number | null; coreMHz: number | null;
}
export interface Vitals {
  timestamp: number; hostname: string; uptimeSeconds: number; load: number[];
  cpu: { model: string; cores: number; percent: number; perCore: number[]; tempC: number | null; mhz: number };
  memory: { totalBytes: number; usedBytes: number; cachedBytes: number; swapTotalBytes: number; swapUsedBytes: number; percent: number };
  gpus: GpuVitals[];
  disk: { readBps: number; writeBps: number; nvmeTempC: number | null;
    root: { freeBytes: number | null; totalBytes: number | null }; home: { freeBytes: number | null; totalBytes: number | null } };
  net: { rxBps: number; txBps: number; interfaces: { name: string; rxBps: number; txBps: number; vpn: boolean }[] };
  top: { pid: number; name: string; cpuPercent: number; rssBytes: number }[];
  processCount: number;
  batteries: { name: string; percent: number; charging: boolean }[];
}

export type AgentAppAction = 'restart' | 'quit' | 'kill' | 'focus' | 'launch';
/** A running agent app (desktop IDE/app) or agent CLI process tree. */
export interface AgentAppInstance {
  id: string; appId: string; name: string; provider: string; kind: 'desktop' | 'cli';
  pid: number; processCount: number; cpuPercent: number; rssBytes: number; startedAt: number;
  cwd: string | null; tty: string | null;
  /** busy: sustained CPU; active: some CPU; idle: ~0; stuck: unresponsive window or pegged single core for minutes. */
  state: 'busy' | 'active' | 'idle' | 'stuck';
  windows: { id: string; title: string }[];
  actions: AgentAppAction[];
  cpuHistory: number[];
}
export interface AgentAppLauncher { appId: string; name: string; provider: string; kind: 'desktop' | 'cli'; running: boolean }

export interface RemoteServiceHealth {
  id: string; name: string; installed: boolean;
  state: 'healthy' | 'degraded' | 'down' | 'unknown';
  summary: string; issues: string[];
  details: Record<string, string | number | boolean | null>;
  actions: ('restart' | 'repair')[];
  lastRepairAt: number | null; lastRepairReason: string | null;
}

export interface MonitorSnapshot {
  at: number; vitals: Vitals; apps: AgentAppInstance[]; launchers: AgentAppLauncher[]; remote: RemoteServiceHealth[];
}

export interface MonitorRpc {
  'monitor.snapshot': { params: Record<string, never>; result: MonitorSnapshot };
  'monitor.appAction': { params: { instanceId?: string; appId?: string; action: AgentAppAction }; result: { ok: boolean; message: string } };
  'monitor.remoteAction': { params: { service: string; action: 'restart' | 'repair' }; result: { ok: boolean; message: string } };
  'system.getVitals': { params: Record<string, never>; result: Vitals };
}
