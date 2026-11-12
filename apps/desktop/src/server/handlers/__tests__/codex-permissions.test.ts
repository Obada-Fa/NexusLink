import { expect, test } from 'bun:test';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, delimiter } from 'node:path';
import {
  createAgentSession, closeAgentSession, listAgentSessions, promptAgent,
  setAgentPermissionMode, setAgentApprovalMode, getAgentApprovalMode,
  setAgentBroadcast, resolveAgentPermission,
} from '../agents';
import { sessionSummary } from '../../../../../../packages/chat-core/src/index';
import type { AgentEvent } from '@nexuslink/rpc-types';

async function until(check: () => boolean) {
  const deadline = Date.now() + 5000;
  while (!check() && Date.now() < deadline) await Bun.sleep(10);
  expect(check()).toBe(true);
}

test('Codex chat policies reach new and resumed turns; Ask overrides global auto approval', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'nexus-codex-permissions-'));
  const log = join(dir, 'calls.jsonl');
  writeFileSync(join(dir, 'codex'), `#!${process.execPath}
const fs=require('node:fs');
const out=m=>process.stdout.write(JSON.stringify(m)+'\\n');
let thread, turn=0;
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line), p=m.params;
 fs.appendFileSync(${JSON.stringify(log)},line+'\\n');
 if(m.method==='initialize')out({id:m.id,result:{}});
 else if(m.method==='thread/start'||m.method==='thread/resume'){
  thread=p.threadId||'native-thread';out({id:m.id,result:{thread:{id:thread},model:'fixture'}});
 }else if(m.method==='turn/start'){
  turn++;out({id:m.id,result:{turn:{id:'turn-'+turn}}});
  out({id:'approval-'+turn,method:'item/commandExecution/requestApproval',params:{threadId:thread,reason:'Run command'}});
 }else if(!m.method && m.id?.startsWith('approval-')){
  out({method:'item/agentMessage/delta',params:{threadId:thread,itemId:'answer-'+turn,delta:JSON.stringify(m.result)}});
  out({method:'turn/completed',params:{threadId:thread,turn:{status:'completed'}}});
 }
});
`, {mode:0o755});
  const oldPath=process.env.PATH;
  const oldMode=getAgentApprovalMode('codex');
  process.env.PATH=dir+delimiter+oldPath;
  const events:AgentEvent[]=[];
  setAgentBroadcast(m=>{if(m.type==='agent-event')events.push(m.event);});
  const first=createAgentSession('codex',dir,'first');
  const second=createAgentSession('codex',dir,'second');
  try {
    setAgentApprovalMode('codex','auto');
    expect(setAgentPermissionMode(first.agentSessionId,'ask').ok).toBe(true);
    expect(setAgentPermissionMode(first.agentSessionId,'invalid').ok).toBe(false);
    const saved=listAgentSessions().find(s=>s.agentSessionId===first.agentSessionId)!;
    expect(saved.permissionMode).toBe('ask');
    expect(sessionSummary('host',saved).permissionMode).toBe('ask');
    expect(listAgentSessions().find(s=>s.agentSessionId===second.agentSessionId)?.permissionMode).toBeUndefined();
    promptAgent(first.agentSessionId,'first turn');
    await until(()=>events.some(e=>e.kind==='permission-request'));
    expect(events.some(e=>e.kind==='result')).toBe(false);
    expect(setAgentPermissionMode(first.agentSessionId,'full-access').ok).toBe(false);
    expect(resolveAgentPermission(first.agentSessionId,'approval-1',false).ok).toBe(true);
    await until(()=>events.some(e=>e.kind==='result'));
    expect(events.find(e=>e.kind==='text-delta')?.text).toContain('decline');
    expect(setAgentPermissionMode(first.agentSessionId,'full-access').ok).toBe(true);
    promptAgent(first.agentSessionId,'second turn');
    await until(()=>events.filter(e=>e.kind==='result').length===2);
    expect(events.filter(e=>e.kind==='permission-request')).toHaveLength(1);
    // Returning from Full access must actively restore Ask on the same thread.
    expect(setAgentPermissionMode(first.agentSessionId,'ask').ok).toBe(true);
    promptAgent(first.agentSessionId,'third turn');
    await until(()=>events.filter(e=>e.kind==='permission-request').length===2);
    resolveAgentPermission(first.agentSessionId,'approval-3',true);
    await until(()=>events.filter(e=>e.kind==='result').length===3);
    const calls=readFileSync(log,'utf8').trim().split('\n').map(line=>JSON.parse(line));
    const turns=calls.filter(c=>c.method==='turn/start').map(c=>c.params);
    expect(turns[0]).toMatchObject({approvalPolicy:'untrusted',approvalsReviewer:'user',sandboxPolicy:{type:'workspaceWrite',writableRoots:[dir],networkAccess:false}});
    expect(turns[1]).toMatchObject({approvalPolicy:'never',sandboxPolicy:{type:'dangerFullAccess'}});
    expect(turns[2]).toMatchObject({approvalPolicy:'untrusted',approvalsReviewer:'user',sandboxPolicy:{type:'workspaceWrite'}});
    expect(calls.filter(c=>c.method==='thread/resume')).toHaveLength(2);
    expect(turns.every(t=>t.threadId==='native-thread')).toBe(true);
  } finally {
    closeAgentSession(first.agentSessionId);closeAgentSession(second.agentSessionId);
    setAgentBroadcast(()=>{});setAgentApprovalMode('codex',oldMode);
    process.env.PATH=oldPath;rmSync(dir,{recursive:true,force:true});
  }
},15000);

test('chat permission mode supports other agents and rejects missing chats', () => {
  const chat=createAgentSession('mock',tmpdir(),'test');
  try {
    expect(setAgentPermissionMode(chat.agentSessionId,'ask').ok).toBe(true);
    expect(setAgentPermissionMode('missing','full-access').ok).toBe(false);
  } finally {closeAgentSession(chat.agentSessionId);}
});
