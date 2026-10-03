import { afterAll, describe, expect, test } from 'bun:test';
import { mkdtemp, readFile, writeFile, stat, symlink, link, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { enableEnrollment, enroll, resume, revokeDevice, accessToken, downloadToken, isPrivatePeer } from './security';
import { readText, writeText } from './files';
import { handleFileDownload, handleFileUpload } from '../handlers/files-http';
import { initializeAgentStore, persistAgent, storedHistory, closeAgentStore } from './agent-store';
import { attachTerminal, detachTerminalsForSocket, handleTerminalCreate, handleTerminalInput, handleTerminalKill, listTerminals, setSend, stopAllTerminals } from '../handlers/terminal';

const directory = await mkdtemp(join(tmpdir(), 'nexuslink-workspace-test-'));
process.env.NEXUSLINK_DATA_DIR = join(directory, 'data');
process.env.NEXUSLINK_LEGACY_AGENT_STORE = join(directory, 'legacy.json');
afterAll(async () => { stopAllTerminals(); await closeAgentStore(); await rm(directory, {recursive:true,force:true}); });
const pair = () => enroll(enableEnrollment(), 'test device');

describe('paired devices and file transfers', () => {
  test('plain LAN listener refuses public and unknown peers', () => {
    for (const address of ['127.0.0.1', '::1', '192.168.1.8', '172.18.0.1', '100.108.2.3', 'fd7a::1']) expect(isPrivatePeer(address)).toBe(true);
    for (const address of [undefined, '8.8.8.8', '203.0.113.5', '2001:db8::1']) expect(isPrivatePeer(address)).toBe(false);
  });
  test('enrollment is one-use, bounded, and revoked credentials lose access', () => {
    const code = enableEnrollment();
    for (let i=0;i<5;i++) expect(() => enroll('00000000','bad')).toThrow();
    expect(() => enroll(code,'late')).toThrow();
    const device=pair(); expect(accessToken(device.token)?.deviceId).toBe(device.deviceId);
    expect(() => enroll(code,'replay')).toThrow();
    revokeDevice(device.deviceId);
    expect(accessToken(device.token)).toBeUndefined();
    expect(() => resume(device.credential)).toThrow();
  });
  test('GET/HEAD/range require authorization, scoped tokens cannot upload, changed resumes fail', async () => {
    const path=join(directory,'résumé.txt'); await writeFile(path,'0123456789');
    const url=new URL('http://localhost/files');url.searchParams.set('path',path);
    expect((await handleFileDownload(url)).status).toBe(401);
    const device=pair(); const scoped=downloadToken(device.deviceId,path);
    const headers={authorization:`Bearer ${scoped.token}`};
    const head=await handleFileDownload(url,new Request(url,{method:'HEAD',headers}));
    expect(head.status).toBe(200); expect(head.headers.get('content-length')).toBe('10'); expect(await head.text()).toBe('');
    const range=await handleFileDownload(url,new Request(url,{headers:{...headers,range:'bytes=2-5','if-range':head.headers.get('etag')!}}));
    expect(range.status).toBe(206);expect(await range.text()).toBe('2345');
    await writeFile(path,'changed contents');
    expect((await handleFileDownload(url,new Request(url,{headers:{...headers,range:'bytes=5-','if-range':head.headers.get('etag')!}}))).status).toBe(412);
    expect((await handleFileUpload(url,new Request(url,{method:'POST',headers,body:'overwrite'}))).status).toBe(401);
    revokeDevice(device.deviceId); expect((await handleFileDownload(url,new Request(url,{headers}))).status).toBe(401);
  });
  test('streamed uploads commit complete bytes and never overwrite by default', async () => {
    const path=join(directory,'upload.txt');const url=new URL('http://localhost/files');url.searchParams.set('path',path);
    const headers={authorization:`Bearer ${pair().token}`};
    const stream=new ReadableStream({start(c){c.enqueue(new TextEncoder().encode('first'));c.enqueue(new TextEncoder().encode('second'));c.close();}});
    expect((await handleFileUpload(url,new Request(url,{method:'POST',headers,body:stream,duplex:'half'} as any))).status).toBe(200);
    expect(await readFile(path,'utf8')).toBe('firstsecond');
    expect((await handleFileUpload(url,new Request(url,{method:'POST',headers,body:'different'}))).status).toBe(409);
    expect(await readFile(path,'utf8')).toBe('firstsecond');
  });
});
describe('guarded documents',()=>{
  test('preserves BOM, CRLF, executable mode, and detects external edits',async()=>{
    const path=join(directory,'script.sh'); await writeFile(path,'\ufeffecho first\r\n',{mode:0o755});
    const initial=await readText(path);expect(initial.bom).toBe(true);expect(initial.lineEnding).toBe('crlf');
    const saved=await writeText(path,'echo second\r\n',initial.revision,true);
    expect(await readFile(path,'utf8')).toBe('\ufeffecho second\r\n');expect((await stat(path)).mode & 0o777).toBe(0o755);
    await writeFile(path,'external');
    await expect(writeText(path,'local',saved.revision,false)).rejects.toMatchObject({code:'REVISION_CONFLICT'});
    expect(await readFile(path,'utf8')).toBe('external');
  });
  test('rejects binary, mixed line endings, symlink and hard-link writes',async()=>{
    const path=join(directory,'mixed');await writeFile(path,'a\r\nb\n');expect((await readText(path)).writable).toBe(false);
    const binary=join(directory,'binary');await writeFile(binary,Buffer.from([0xff,0,0]));expect((await readText(binary)).writable).toBe(false);
    const target=join(directory,'target');await writeFile(target,'plain');const sym=join(directory,'sym');await symlink(target,sym);const hard=join(directory,'hard');await link(target,hard);
    for(const p of [sym,hard]) { const doc=await readText(p);expect(doc.writable).toBe(false);await expect(writeText(p,'no',doc.revision,false)).rejects.toThrow(); }
  });
});
test('SQLite migration retains full available history across a restart',async()=>{
  const info={agentSessionId:'persisted',agent:'codex',busy:true,name:'History'};
  await writeFile(process.env.NEXUSLINK_LEGACY_AGENT_STORE!,JSON.stringify([{info,history:[{seq:1,kind:'user',text:'start'}]}]));
  await initializeAgentStore();
  await Promise.all(Array.from({length:260},(_,i)=>persistAgent({info,events:[{seq:i+2,kind:'assistant',text:`event ${i}`}]})));
  let page=await storedHistory('persisted',{limit:100});expect(page.events).toHaveLength(100);expect(page.latestSeq).toBe(261);
  const older=await storedHistory('persisted',{beforeSeq:page.oldestSeq,limit:100});expect(older.latestSeq).toBe(161);
  await closeAgentStore();await initializeAgentStore();page=await storedHistory('persisted',{afterSeq:0,limit:200});expect(page.events).toHaveLength(200);expect(page.events[0].text).toBe('start');
  expect((await stat(process.env.NEXUSLINK_LEGACY_AGENT_STORE!+'.pre-sqlite.bak')).isFile()).toBe(true);
});
test('PTY buffers before attach, survives detach, replays once, and reports the actual exit code',async()=>{
  const messages:any[]=[];setSend((_,msg)=>messages.push(msg));const ws={} as WebSocket;
  const {terminalId}=handleTerminalCreate(80,24,'/bin/bash',undefined,directory,{detached:true});
  try {
    handleTerminalInput(terminalId,"printf 'EARLY-%s\\n' output\r");await Bun.sleep(400);expect(messages).toHaveLength(0);
    attachTerminal(terminalId,ws,0);expect(messages.map(e=>e.data||'').join('')).toContain('EARLY-output');
    const last=messages.filter(e=>e.type==='terminal-output').at(-1).seq;detachTerminalsForSocket(ws);messages.length=0;
    handleTerminalInput(terminalId,"printf '\\360\\237\\230\\200\\n'; exit 7\r");
    for(let i=0;i<50 && listTerminals().find(s=>s.terminalId===terminalId)?.state!=='exited';i++) await Bun.sleep(50);
    const result=attachTerminal(terminalId,ws,last);expect(result.exitCode).toBe(7);expect(messages.map(e=>e.data||'').join('')).toContain('😀');
    const end=result.seq;messages.length=0;attachTerminal(terminalId,ws,end);expect(messages).toHaveLength(0);
  } finally {handleTerminalKill(terminalId);}
},10000);
