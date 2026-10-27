import { existsSync, readdirSync, readFileSync, statfsSync } from 'node:fs';
import { cpus, homedir, hostname, loadavg, uptime } from 'node:os';
import { spawnSync } from 'node:child_process';
import type { Vitals, GpuVitals } from '@nexuslink/rpc-types';
import { sampleProcesses, commandLine } from './proc-sampler';

/** Rich, cheap PC vitals from /proc and /sys only (no helper processes on AMD/Intel). */
type Counter = { at: number; values: Map<string, number[]> };
let prevCpu: number[][] | null = null;
let prevDisk: Counter | null = null;
let prevNet: Counter | null = null;
let cached: Vitals | null = null;
let gpuNames: Map<string, string> | null = null;
let nvidia: { at: number; gpus: GpuVitals[] } | null = null;

const read = (path: string) => { try { return readFileSync(path, 'utf8').trim(); } catch { return null; } };
const num = (path: string) => { const v = read(path); const n = v == null ? NaN : Number(v); return Number.isFinite(n) ? n : null; };
const round = (n: number, places = 1) => Math.round(n * 10 ** places) / 10 ** places;

export function getVitals(): Vitals {
  if (cached && Date.now() - cached.timestamp < 1200) return cached;
  const now = Date.now();
  const cpu = cpuUsage();
  const procs = sampleProcesses();
  cached = {
    timestamp: now,
    hostname: hostname(),
    uptimeSeconds: Math.round(uptime()),
    load: loadavg().map(v => round(v, 2)),
    cpu: { model: cpus()[0]?.model?.trim() || 'CPU', cores: cpus().length, percent: cpu.total, perCore: cpu.perCore,
      tempC: cpuTemp(), mhz: Math.round(cpus().reduce((a, c) => a + c.speed, 0) / Math.max(1, cpus().length)) },
    memory: memory(),
    gpus: gpus(),
    disk: disk(now),
    net: net(now),
    top: procs.filter(p => p.cpuPercent > 0 || p.rssBytes > 200 * 1024 * 1024)
      .sort((a, b) => b.cpuPercent - a.cpuPercent || b.rssBytes - a.rssBytes).slice(0, 8)
      .map(p => ({ pid: p.pid, name: processLabel(p), cpuPercent: p.cpuPercent, rssBytes: p.rssBytes })),
    processCount: procs.length,
    batteries: batteries(),
  };
  return cached;
}

function processLabel(p: { pid: number; comm: string; startedAt: number }) {
  const argv = commandLine(p);
  const exe = (argv[0] || '').split('/').pop() || p.comm;
  // Electron/Chromium children are all called after the app; show which part is busy.
  const type = argv.find(a => a.startsWith('--type='))?.slice(7);
  const base = exe.length > 2 && exe.length < 40 ? exe : p.comm;
  return type ? `${base} (${type})` : base;
}

function cpuUsage() {
  const lines = (read('/proc/stat') || '').split('\n').filter(l => /^cpu\d*\s/.test(l));
  const now = lines.map(l => l.trim().split(/\s+/).slice(1, 9).map(Number));
  const pct = (cur: number[], old?: number[]) => {
    if (!old) return 0;
    const idle = (cur[3] + cur[4]) - (old[3] + old[4]);
    const total = cur.reduce((a, b) => a + b, 0) - old.reduce((a, b) => a + b, 0);
    return total > 0 ? round(Math.max(0, Math.min(100, (1 - idle / total) * 100))) : 0;
  };
  const result = { total: pct(now[0], prevCpu?.[0]), perCore: now.slice(1).map((c, i) => pct(c, prevCpu?.[i + 1])) };
  prevCpu = now;
  return result;
}

function hwmons() {
  const out: { dir: string; name: string }[] = [];
  try { for (const h of readdirSync('/sys/class/hwmon')) { const dir = `/sys/class/hwmon/${h}`; out.push({ dir, name: read(`${dir}/name`) || '' }); } } catch {}
  return out;
}

function cpuTemp() {
  for (const { dir, name } of hwmons()) {
    if (name === 'k10temp' || name === 'zenpower') return milli(num(`${dir}/temp1_input`));
    if (name === 'coretemp') return milli(num(`${dir}/temp1_input`));
  }
  const zone = num('/sys/class/thermal/thermal_zone0/temp');
  return milli(zone);
}
const milli = (v: number | null) => v == null ? null : round(v / 1000);

function memory() {
  const info = new Map<string, number>();
  for (const line of (read('/proc/meminfo') || '').split('\n')) { const m = line.match(/^(\w+):\s+(\d+)/); if (m) info.set(m[1], Number(m[2]) * 1024); }
  const total = info.get('MemTotal') || 0;
  const available = info.get('MemAvailable') ?? info.get('MemFree') ?? 0;
  const swapTotal = info.get('SwapTotal') || 0;
  return { totalBytes: total, usedBytes: Math.max(0, total - available), cachedBytes: (info.get('Cached') || 0) + (info.get('Buffers') || 0),
    swapTotalBytes: swapTotal, swapUsedBytes: Math.max(0, swapTotal - (info.get('SwapFree') || 0)),
    percent: total ? round(((total - available) / total) * 100) : 0 };
}

function gpuName(slot: string, vendor: string, device: string, vramTotal: number) {
  if (!gpuNames) {
    gpuNames = new Map();
    try {
      const out = spawnSync('lspci', ['-mm', '-d', '::0300'], { encoding: 'utf8', timeout: 1500 }).stdout || '';
      const more = spawnSync('lspci', ['-mm', '-d', '::0302'], { encoding: 'utf8', timeout: 1500 }).stdout || '';
      for (const line of (out + more).split('\n')) {
        const parts = [...line.matchAll(/"([^"]*)"/g)].map(m => m[1]);
        const pci = line.split(' ')[0];
        if (pci && parts.length >= 3) gpuNames.set(pci, parts[2]);
      }
    } catch {}
  }
  const known: Record<string, string> = { '0x7550': 'Radeon RX 9070 series', '0x164e': 'Radeon iGPU (Raphael)', '0x744c': 'Radeon RX 7900 series', '0x73bf': 'Radeon RX 6800/6900' };
  const listed = [...gpuNames.entries()].find(([pci]) => slot.endsWith(pci))?.[1];
  const vendorName = vendor === '0x1002' ? 'AMD' : vendor === '0x8086' ? 'Intel' : vendor === '0x10de' ? 'NVIDIA' : 'GPU';
  const name = known[device] || (listed && !/^Device [0-9a-f]+$/i.test(listed) ? listed.replace(/\[|\]/g, '') : null) || `${vendorName} ${vramTotal > 2e9 ? 'GPU' : 'integrated GPU'}`;
  return name.startsWith(vendorName) || vendorName === 'GPU' ? name : `${vendorName} ${name}`;
}

function gpus(): GpuVitals[] {
  const list: GpuVitals[] = [];
  let cards: string[] = [];
  try { cards = readdirSync('/sys/class/drm').filter(c => /^card\d+$/.test(c)); } catch {}
  for (const card of cards) {
    const dev = `/sys/class/drm/${card}/device`;
    const vendor = read(`${dev}/vendor`) || '';
    if (vendor === '0x10de') continue; // NVIDIA is read through nvidia-smi below.
    const busy = num(`${dev}/gpu_busy_percent`);
    const vramTotal = num(`${dev}/mem_info_vram_total`) ?? 0;
    if (busy == null && !vramTotal) continue;
    let hw = '';
    try { const h = readdirSync(`${dev}/hwmon`)[0]; if (h) hw = `${dev}/hwmon/${h}`; } catch {}
    const labels = new Map<string, number | null>();
    if (hw) for (let i = 1; i <= 4; i++) { const label = read(`${hw}/temp${i}_label`) || (i === 1 ? 'edge' : `temp${i}`); labels.set(label, milli(num(`${hw}/temp${i}_input`))); }
    const power = num(`${hw}/power1_average`) ?? num(`${hw}/power1_input`);
    const slot = (() => { try { return readFileSync(`${dev}/uevent`, 'utf8').match(/PCI_SLOT_NAME=(.+)/)?.[1] || card; } catch { return card; } })();
    list.push({ id: card, name: gpuName(slot, vendor, read(`${dev}/device`) || '', vramTotal), vendor: vendor === '0x1002' ? 'amd' : vendor === '0x8086' ? 'intel' : 'other',
      integrated: vramTotal > 0 && vramTotal < 2 * 1024 ** 3, busyPercent: busy, memBusyPercent: num(`${dev}/mem_busy_percent`),
      vramUsedBytes: num(`${dev}/mem_info_vram_used`), vramTotalBytes: vramTotal || null,
      tempC: labels.get('edge') ?? null, hotspotC: labels.get('junction') ?? null, memTempC: labels.get('mem') ?? null,
      powerW: power == null ? null : round(power / 1e6), powerCapW: (() => { const c = num(`${hw}/power1_cap`); return c == null ? null : round(c / 1e6, 0); })(),
      fanRpm: num(`${hw}/fan1_input`), coreMHz: (() => { const f = num(`${hw}/freq1_input`); return f == null ? null : Math.round(f / 1e6); })() });
  }
  // Discrete first: the gaming/compute card is what people want to see.
  list.sort((a, b) => Number(a.integrated) - Number(b.integrated) || (b.vramTotalBytes || 0) - (a.vramTotalBytes || 0));
  return [...list, ...nvidiaGpus()];
}

function nvidiaGpus(): GpuVitals[] {
  if (nvidia && Date.now() - nvidia.at < 1800) return nvidia.gpus;
  if (!existsSync('/usr/bin/nvidia-smi')) return (nvidia = { at: Date.now(), gpus: [] }).gpus;
  const out = spawnSync('/usr/bin/nvidia-smi', ['--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,clocks.gr', '--format=csv,noheader,nounits'], { encoding: 'utf8', timeout: 1500 }).stdout || '';
  const gpus = out.trim().split('\n').filter(Boolean).map(line => {
    const [i, name, util, used, total, temp, power, cap, , clock] = line.split(',').map(s => s.trim());
    const n = (s: string) => Number.isFinite(Number(s)) ? Number(s) : null;
    return { id: `nvidia${i}`, name, vendor: 'nvidia', integrated: false, busyPercent: n(util), memBusyPercent: null, vramUsedBytes: n(used) == null ? null : n(used)! * 1024 * 1024,
      vramTotalBytes: n(total) == null ? null : n(total)! * 1024 * 1024, tempC: n(temp), hotspotC: null, memTempC: null, powerW: n(power), powerCapW: n(cap), fanRpm: null, coreMHz: n(clock) } as GpuVitals;
  });
  return (nvidia = { at: Date.now(), gpus }).gpus;
}

function rates(prev: Counter | null, now: number, values: Map<string, number[]>) {
  const dt = prev ? (now - prev.at) / 1000 : 0;
  const out = new Map<string, number[]>();
  for (const [key, cur] of values) {
    const old = prev?.values.get(key);
    out.set(key, cur.map((v, i) => (dt > 0 && old ? Math.max(0, (v - old[i]) / dt) : 0)));
  }
  return out;
}

function disk(now: number) {
  const values = new Map<string, number[]>();
  for (const line of (read('/proc/diskstats') || '').split('\n')) {
    const f = line.trim().split(/\s+/);
    if (f.length < 10 || !/^(nvme\d+n\d+|sd[a-z]+|vd[a-z]+|mmcblk\d+)$/.test(f[2])) continue;
    values.set(f[2], [Number(f[5]) * 512, Number(f[9]) * 512]);
  }
  const r = rates(prevDisk, now, values);
  prevDisk = { at: now, values };
  let readBps = 0, writeBps = 0;
  for (const [rd, wr] of r.values()) { readBps += rd; writeBps += wr; }
  const fs = (path: string) => { try { const s = statfsSync(path); return { freeBytes: s.bavail * s.bsize, totalBytes: s.blocks * s.bsize }; } catch { return { freeBytes: null, totalBytes: null }; } };
  const root = fs('/'); const home = fs(homedir());
  let nvmeTempC: number | null = null;
  for (const { dir, name } of hwmons()) if (name === 'nvme') { nvmeTempC = milli(num(`${dir}/temp1_input`)); break; }
  return { readBps: Math.round(readBps), writeBps: Math.round(writeBps), root, home, nvmeTempC };
}

function net(now: number) {
  const values = new Map<string, number[]>();
  for (const line of (read('/proc/net/dev') || '').split('\n').slice(2)) {
    const [iface, rest] = line.split(':');
    const name = iface?.trim();
    if (!name || !rest || /^(lo|docker\d*|br-|veth|virbr|vnet)/.test(name)) continue;
    const f = rest.trim().split(/\s+/).map(Number);
    values.set(name, [f[0], f[8]]);
  }
  const r = rates(prevNet, now, values);
  prevNet = { at: now, values };
  const interfaces = [...r.entries()].map(([name, [rx, tx]]) => ({ name, rxBps: Math.round(rx), txBps: Math.round(tx), vpn: /^(tailscale|wg|tun|zt)/.test(name) }));
  const physical = interfaces.filter(i => !i.vpn);
  return { rxBps: physical.reduce((a, i) => a + i.rxBps, 0), txBps: physical.reduce((a, i) => a + i.txBps, 0), interfaces };
}

function batteries() {
  const out: { name: string; percent: number; charging: boolean }[] = [];
  try {
    for (const b of readdirSync('/sys/class/power_supply')) {
      const dir = `/sys/class/power_supply/${b}`;
      const cap = num(`${dir}/capacity`);
      if (cap == null) continue;
      const model = read(`${dir}/model_name`) || (read(`${dir}/type`) === 'Battery' ? 'Battery' : b);
      out.push({ name: model, percent: cap, charging: read(`${dir}/status`) === 'Charging' });
    }
  } catch {}
  return out;
}
