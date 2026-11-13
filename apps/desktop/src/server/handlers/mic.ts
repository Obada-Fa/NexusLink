// Phone mic → PC virtual microphone.
//
// The phone streams raw s16le PCM as binary WebSocket frames prefixed with
// MIC_FRAME_MAGIC. We play it into a private null sink and expose that sink's
// monitor as a normal input device ("NexusLink Phone Mic"), so any PC app —
// AI voice modes, Discord, recorders — can select it like a real microphone.
// Works on PulseAudio and on PipeWire through pipewire-pulse.

import type { Subprocess } from 'bun';
import { WorkspaceError } from '../workspace/security';

export const MIC_SINK = 'nexuslink_mic_sink';
export const MIC_SOURCE = 'nexuslink_phone_mic';
export const MIC_DEVICE_NAME = 'NexusLink Phone Mic';
/** "NXMC": every phone mic binary frame starts with these four bytes. */
export const MIC_FRAME_MAGIC = [0x4e, 0x58, 0x4d, 0x43] as const;

const RATES = new Set([16000, 22050, 24000, 32000, 44100, 48000]);

type RunResult = { ok: boolean; stdout: string };
type Runner = (argv: string[]) => RunResult;
type Spawner = (argv: string[]) => Subprocess<'pipe', 'ignore', 'ignore'>;

const defaultRun: Runner = (argv) => {
  try {
    const res = Bun.spawnSync(argv, { stdout: 'pipe', stderr: 'pipe' });
    return { ok: res.exitCode === 0, stdout: res.stdout.toString() };
  } catch {
    return { ok: false, stdout: '' };
  }
};
const defaultSpawn: Spawner = (argv) =>
  Bun.spawn(argv, { stdin: 'pipe', stdout: 'ignore', stderr: 'ignore' });

let run: Runner = defaultRun;
let spawn: Spawner = defaultSpawn;
let authorize: (ws: WebSocket) => boolean = () => false;

interface MicSession {
  ws: WebSocket;
  proc: Subprocess<'pipe', 'ignore', 'ignore'>;
  /** Default source to restore on stop, when we replaced it. */
  previousDefault: string | null;
  sampleRate: number;
  channels: number;
  startedAt: number;
  bytes: number;
}

let active: MicSession | null = null;

/** Test hook: swap the pactl runner and pacat spawner. */
export function setMicCommandsForTest(r: Runner | null, s: Spawner | null): void {
  run = r ?? defaultRun;
  spawn = s ?? defaultSpawn;
}

/** Binary frames bypass send(); the credential is re-checked per frame. */
export function setMicAuthorizer(fn: (ws: WebSocket) => boolean): void {
  authorize = fn;
}

function unsupportedReason(): string | null {
  if (process.platform !== 'linux') {
    return 'Phone mic needs a Linux PC with PulseAudio or PipeWire for now.';
  }
  if (!Bun.which('pactl') || !Bun.which('pacat')) {
    return 'Install pulseaudio-utils (pactl and pacat) on the PC to use the phone mic.';
  }
  return null;
}

export function micStatus(ws?: WebSocket) {
  const reason = unsupportedReason();
  return {
    supported: reason === null,
    reason,
    device: MIC_DEVICE_NAME,
    active: !!active,
    mine: !!active && active.ws === ws,
    sampleRate: active?.sampleRate ?? null,
    isDefault: !!active && defaultSource() === MIC_SOURCE,
  };
}

function defaultSource(): string | null {
  const res = run(['pactl', 'get-default-source']);
  const name = res.stdout.trim();
  return res.ok && name ? name : null;
}

function sourceExists(): boolean {
  const res = run(['pactl', 'list', 'short', 'sources']);
  return res.ok && res.stdout.split('\n').some((l) => l.split('\t')[1] === MIC_SOURCE);
}

/** Create the null sink + remapped source once; reuse it if a previous run left it. */
function ensureDevice(): void {
  if (sourceExists()) return;
  const sink = run([
    'pactl', 'load-module', 'module-null-sink',
    `sink_name=${MIC_SINK}`,
    'rate=48000', 'channels=1',
    'sink_properties=device.description=NexusLink-Phone-Mic-Feed',
  ]);
  if (!sink.ok) throw new WorkspaceError('UNAVAILABLE', 'Could not create the virtual mic on the PC (pactl load-module failed).');
  const source = run([
    'pactl', 'load-module', 'module-remap-source',
    `master=${MIC_SINK}.monitor`,
    `source_name=${MIC_SOURCE}`,
    'channels=1',
    `source_properties=device.description="${MIC_DEVICE_NAME}"`,
  ]);
  if (!source.ok) {
    unloadMicDevice();
    throw new WorkspaceError('UNAVAILABLE', 'Could not create the virtual mic on the PC (remap-source failed).');
  }
}

export function startMic(
  ws: WebSocket,
  params: { sampleRate?: unknown; channels?: unknown; makeDefault?: unknown },
) {
  const reason = unsupportedReason();
  if (reason) throw new WorkspaceError('UNAVAILABLE', reason);
  const sampleRate = Number(params.sampleRate ?? 48000);
  const channels = Number(params.channels ?? 1);
  if (!RATES.has(sampleRate)) throw new WorkspaceError('INVALID_ARGUMENT', 'Unsupported mic sample rate.');
  if (channels !== 1 && channels !== 2) throw new WorkspaceError('INVALID_ARGUMENT', 'Mic must be mono or stereo.');

  // One phone feeds the mic at a time; the newest start takes over.
  if (active) stopMic(active.ws);
  ensureDevice();

  const proc = spawn([
    'pacat', '--playback', '--raw',
    '--format=s16le', `--rate=${sampleRate}`, `--channels=${channels}`,
    `--device=${MIC_SINK}`, '--latency-msec=60',
    '--client-name=NexusLink', '--stream-name=Phone mic',
  ]);
  let previousDefault: string | null = null;
  if (params.makeDefault === true) {
    const current = defaultSource();
    if (current !== MIC_SOURCE) {
      previousDefault = current;
      run(['pactl', 'set-default-source', MIC_SOURCE]);
    }
  }
  const session: MicSession = {
    ws, proc, previousDefault, sampleRate, channels, startedAt: Date.now(), bytes: 0,
  };
  active = session;
  proc.exited.then(() => {
    if (active === session) stopMic(ws);
  });
  return micStatus(ws);
}

export function isMicFrame(data: Uint8Array): boolean {
  return data.length > MIC_FRAME_MAGIC.length &&
    MIC_FRAME_MAGIC.every((b, i) => data[i] === b);
}

/** Handle one binary frame from a phone. Returns true when it was a mic frame. */
export function handleMicFrame(ws: WebSocket, data: Uint8Array): boolean {
  if (!isMicFrame(data)) return false;
  const session = active;
  if (!session || session.ws !== ws) return true;
  if (!authorize(ws)) {
    stopMic(ws);
    return true;
  }
  let pcm = data.subarray(MIC_FRAME_MAGIC.length);
  // Keep whole samples so pacat never drifts by a byte.
  const frameBytes = 2 * session.channels;
  pcm = pcm.subarray(0, pcm.length - (pcm.length % frameBytes));
  if (!pcm.length) return true;
  try {
    session.proc.stdin.write(pcm);
    session.proc.stdin.flush();
    session.bytes += pcm.length;
  } catch {
    stopMic(ws);
  }
  return true;
}

export function stopMic(ws: WebSocket) {
  const session = active;
  if (!session || session.ws !== ws) return micStatus(ws);
  active = null;
  try { session.proc.stdin.end(); } catch {}
  try { session.proc.kill(); } catch {}
  // Restore only if nobody changed the default while we were live.
  if (session.previousDefault && defaultSource() === MIC_SOURCE) {
    run(['pactl', 'set-default-source', session.previousDefault]);
  }
  return micStatus(ws);
}

export function stopMicForSocket(ws: WebSocket): void {
  if (active?.ws === ws) stopMic(ws);
}

/** Remove the virtual mic (server shutdown). Also clears devices left by a crash. */
export function unloadMicDevice(): void {
  if (active) stopMic(active.ws);
  const res = run(['pactl', 'list', 'short', 'modules']);
  if (!res.ok) return;
  // Unload the remap source before the sink it reads from.
  const lines = res.stdout.split('\n');
  const ours = (needle: string) => lines
    .filter((l) => l.includes(needle))
    .map((l) => l.split('\t')[0])
    .filter((id) => /^\d+$/.test(id));
  for (const id of [...ours(`source_name=${MIC_SOURCE}`), ...ours(`sink_name=${MIC_SINK}`)]) {
    run(['pactl', 'unload-module', id]);
  }
}
