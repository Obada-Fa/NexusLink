import { afterEach, expect, test } from 'bun:test';
import {
  MIC_SOURCE, handleMicFrame, isMicFrame, setMicAuthorizer, setMicCommandsForTest,
  startMic, stopMic, stopMicForSocket, unloadMicDevice,
} from '../mic';

const linux = process.platform === 'linux' && !!Bun.which('pactl') && !!Bun.which('pacat');

function fakeAudio() {
  const calls: string[][] = [];
  const written: Uint8Array[] = [];
  let defaultSource = 'alsa_input.real';
  let loaded = false;
  let killed = 0;
  let exit!: () => void;
  const run = (argv: string[]) => {
    calls.push(argv);
    const [, cmd, ...rest] = argv;
    if (cmd === 'get-default-source') return { ok: true, stdout: `${defaultSource}\n` };
    if (cmd === 'set-default-source') { defaultSource = rest[0]; return { ok: true, stdout: '' }; }
    if (cmd === 'list' && rest[1] === 'sources') {
      return { ok: true, stdout: loaded ? `7\t${MIC_SOURCE}\tmodule-remap-source.c\ts16le 1ch 48000Hz\tIDLE\n` : '' };
    }
    if (cmd === 'list' && rest[1] === 'modules') {
      return { ok: true, stdout: '31\tmodule-null-sink\tsink_name=nexuslink_mic_sink rate=48000\n32\tmodule-remap-source\tmaster=nexuslink_mic_sink.monitor source_name=nexuslink_phone_mic\n' };
    }
    if (cmd === 'load-module') { loaded = argv[2] === 'module-remap-source' || loaded; return { ok: true, stdout: '42\n' }; }
    return { ok: true, stdout: '' };
  };
  const spawn = (argv: string[]) => {
    calls.push(argv);
    return {
      stdin: { write: (b: Uint8Array) => { written.push(b.slice()); }, flush() {}, end() {} },
      kill: () => { killed++; },
      exited: new Promise<number>((resolve) => { exit = () => resolve(0); }),
    } as any;
  };
  setMicCommandsForTest(run, spawn);
  return { calls, written, get defaultSource() { return defaultSource; }, get killed() { return killed; }, exit: () => exit() };
}

const frame = (...pcm: number[]) => new Uint8Array([0x4e, 0x58, 0x4d, 0x43, ...pcm]);
const ws = (name: string) => ({ name }) as unknown as WebSocket;

afterEach(() => {
  setMicCommandsForTest(null, null);
  setMicAuthorizer(() => false);
});

test('recognises only magic-prefixed frames', () => {
  expect(isMicFrame(frame(1, 2))).toBe(true);
  expect(isMicFrame(new Uint8Array([0x4e, 0x58, 0x4d, 0x43]))).toBe(false);
  expect(isMicFrame(new Uint8Array([1, 2, 3, 4, 5, 6]))).toBe(false);
});

test.if(linux)('creates the virtual mic, feeds pacat whole samples and restores the default', () => {
  const audio = fakeAudio();
  const phone = ws('phone');
  setMicAuthorizer((s) => s === phone);
  const status = startMic(phone, { sampleRate: 48000, channels: 1, makeDefault: true });
  expect(status.active).toBe(true);
  expect(status.mine).toBe(true);
  expect(audio.calls.some((c) => c.includes('module-null-sink'))).toBe(true);
  expect(audio.calls.some((c) => c[0] === 'pacat' && c.includes('--rate=48000'))).toBe(true);
  expect(audio.defaultSource).toBe(MIC_SOURCE);

  // Odd trailing byte is dropped so samples stay aligned.
  expect(handleMicFrame(phone, frame(1, 2, 3))).toBe(true);
  expect([...audio.written[0]]).toEqual([1, 2]);
  // Another socket cannot inject audio.
  handleMicFrame(ws('other'), frame(9, 9));
  expect(audio.written.length).toBe(1);

  stopMic(phone);
  expect(audio.killed).toBe(1);
  expect(audio.defaultSource).toBe('alsa_input.real');
});

test.if(linux)('stops when the credential is gone or the socket closes', () => {
  const audio = fakeAudio();
  const phone = ws('phone');
  let allowed = true;
  setMicAuthorizer(() => allowed);
  startMic(phone, { sampleRate: 16000, channels: 1 });
  allowed = false;
  handleMicFrame(phone, frame(1, 2));
  expect(audio.written.length).toBe(0);
  expect(audio.killed).toBe(1);

  startMic(phone, { sampleRate: 16000, channels: 1 });
  stopMicForSocket(phone);
  expect(audio.killed).toBe(2);
});

test.if(linux)('rejects bad formats and unloads leftover modules', () => {
  const audio = fakeAudio();
  expect(() => startMic(ws('p'), { sampleRate: 12345 })).toThrow();
  expect(() => startMic(ws('p'), { channels: 3 })).toThrow();
  unloadMicDevice();
  const unloads = audio.calls.filter((c) => c[1] === 'unload-module').map((c) => c[2]);
  expect(unloads).toEqual(['32', '31']);
});
