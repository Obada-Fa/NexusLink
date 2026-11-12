import { test, expect } from 'bun:test';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, delimiter } from 'node:path';
import {
  createAgentSession, closeAgentSession, listAgentSessions, promptAgent, cancelAgent,
  setAgentPermissionMode, resolveAgentPermission, pendingAgentApprovals,
  setAgentBroadcast, setAgentApprovalMode, getAgentApprovalMode,
} from '../agents';
import type { AgentEvent } from '@nexuslink/rpc-types';

async function until(check: () => boolean) {
  const deadline = Date.now() + 5000;
  while (!check() && Date.now() < deadline) await Bun.sleep(10);
  expect(check()).toBe(true);
}

for (const [agent, bin, flag] of [
  ['cursor', 'cursor-agent', '--force'],
  ['opencode', 'opencode', '--auto'],
  ['antigravity', 'agy', '--dangerously-skip-permissions'],
]) {
  test(`${agent}: Ask gates each turn before spawn; denial and Stop never launch; auto mode runs`, async () => {
    const dir = mkdtempSync(join(tmpdir(), 'nexus-turn-approval-'));
    const log = join(dir, 'spawned.jsonl');
    writeFileSync(join(dir, bin!), `#!${process.execPath}
const fs=require('node:fs');
fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(process.argv.slice(2))+'\\n');
console.log(JSON.stringify({type:'result',subtype:'success',result:'done'}));
`, {mode:0o755});
    const oldPath=process.env.PATH;
    const oldMode=getAgentApprovalMode(agent!);
    process.env.PATH=dir+delimiter+oldPath;
    setAgentApprovalMode(agent!,'auto');
    const chat=createAgentSession(agent!,dir,'permission fixture');
    const busy=()=>listAgentSessions().find(s=>s.agentSessionId===chat.agentSessionId)?.busy === true;
    const spawned=()=>existsSync(log)?readFileSync(log,'utf8').trim().split('\n').map(line=>JSON.parse(line)):[];
    try {
      expect(setAgentPermissionMode(chat.agentSessionId,'ask').ok).toBe(true);
      promptAgent(chat.agentSessionId,'do some work');
      const denied=pendingAgentApprovals(chat.agentSessionId).at(-1)!;
      expect(denied.toolName).toBe('Run agent turn');
      expect(spawned()).toHaveLength(0);
      expect(setAgentPermissionMode(chat.agentSessionId,'full-access').ok).toBe(false);
      resolveAgentPermission(chat.agentSessionId,denied.refId!,false);
      expect(busy()).toBe(false);
      expect(spawned()).toHaveLength(0);
      promptAgent(chat.agentSessionId,'stop this turn');
      const stopped=pendingAgentApprovals(chat.agentSessionId).at(-1)!;
      cancelAgent(chat.agentSessionId);
      expect(resolveAgentPermission(chat.agentSessionId,stopped.refId!,true).ok).toBe(false);
      expect(spawned()).toHaveLength(0);
      promptAgent(chat.agentSessionId,'approve this turn');
      const allowed=pendingAgentApprovals(chat.agentSessionId).at(-1)!;
      expect(spawned()).toHaveLength(0);
      resolveAgentPermission(chat.agentSessionId,allowed.refId!,true);
      await until(()=>!busy());
      expect(spawned()).toHaveLength(1);
      expect(spawned()[0]).toContain(flag);
      promptAgent(chat.agentSessionId,'next turn needs its own approval');
      expect(pendingAgentApprovals(chat.agentSessionId)).toHaveLength(1);
      expect(spawned()).toHaveLength(1);
      cancelAgent(chat.agentSessionId);
      expect(setAgentPermissionMode(chat.agentSessionId,'full-access').ok).toBe(true);
      promptAgent(chat.agentSessionId,'run automatically');
      await until(()=>!busy());
      expect(spawned()).toHaveLength(2);
      expect(pendingAgentApprovals(chat.agentSessionId)).toHaveLength(0);
      setAgentPermissionMode(chat.agentSessionId,'ask');
      promptAgent(chat.agentSessionId,'close before approval');
      const closed=pendingAgentApprovals(chat.agentSessionId).at(-1)!;
      closeAgentSession(chat.agentSessionId);
      expect(resolveAgentPermission(chat.agentSessionId,closed.refId!,true).ok).toBe(false);
      expect(spawned()).toHaveLength(2);
    } finally {
      closeAgentSession(chat.agentSessionId);
      setAgentApprovalMode(agent!,oldMode);process.env.PATH=oldPath;
      rmSync(dir,{recursive:true,force:true});
    }
  });
}

test('Claude switches Ask and auto approval on resumed processes; chat Ask overrides global auto', async () => {
  const dir=mkdtempSync(join(tmpdir(),'nexus-claude-permissions-'));
  const log=join(dir,'spawned.jsonl');
  writeFileSync(join(dir,'claude'), `#!${process.execPath}
const fs=require('node:fs');
fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(process.argv.slice(2))+'\\n');
const out=m=>console.log(JSON.stringify(m));
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line);
 if(m.type==='user'){
  out({type:'system',subtype:'init',session_id:'native-claude'});
  out({type:'control_request',request_id:'request',request:{subtype:'can_use_tool',tool_name:'Bash',input:{command:'rm -rf build'}}});
 }else if(m.type==='control_response')out({type:'result',subtype:'success',result:'done'});
});
`,{mode:0o755});
  const oldPath=process.env.PATH,oldMode=getAgentApprovalMode('claude');
  process.env.PATH=dir+delimiter+oldPath;setAgentApprovalMode('claude','auto');
  const events:AgentEvent[]=[];
  setAgentBroadcast(m=>{if(m.type==='agent-event')events.push(m.event);});
  const chat=createAgentSession('claude',dir,'fixture');
  const busy=()=>listAgentSessions().find(s=>s.agentSessionId===chat.agentSessionId)?.busy===true;
  try {
    setAgentPermissionMode(chat.agentSessionId,'ask');
    promptAgent(chat.agentSessionId,'first');
    await until(()=>pendingAgentApprovals(chat.agentSessionId).length===1);
    resolveAgentPermission(chat.agentSessionId,'request',false);
    await until(()=>!busy());
    setAgentPermissionMode(chat.agentSessionId,'full-access');
    promptAgent(chat.agentSessionId,'second');
    await until(()=>!busy());
    expect(events.filter(e=>e.kind==='permission-request')).toHaveLength(1);
    setAgentPermissionMode(chat.agentSessionId,'ask');
    promptAgent(chat.agentSessionId,'third');
    await until(()=>pendingAgentApprovals(chat.agentSessionId).length===1);
    resolveAgentPermission(chat.agentSessionId,'request',true);
    await until(()=>!busy());
    const spawns=readFileSync(log,'utf8').trim().split('\n').map(line=>JSON.parse(line) as string[]);
    expect(spawns.map(args=>args[args.indexOf('--permission-mode')+1])).toEqual(['default','bypassPermissions','default']);
    expect(spawns[1]).toContain('--resume');
    expect(spawns[2]).toContain('native-claude');
  } finally {
    closeAgentSession(chat.agentSessionId);setAgentBroadcast(()=>{});
    setAgentApprovalMode('claude',oldMode);process.env.PATH=oldPath;
    rmSync(dir,{recursive:true,force:true});
  }
});


test('demo respects per-chat auto and Ask modes too', async () => {
  const chat=createAgentSession('mock',tmpdir(),'demo permissions');
  const busy=()=>listAgentSessions().find(s=>s.agentSessionId===chat.agentSessionId)?.busy===true;
  try {
    setAgentPermissionMode(chat.agentSessionId,'full-access');
    promptAgent(chat.agentSessionId,'auto demo');
    await until(()=>!busy());
    expect(pendingAgentApprovals(chat.agentSessionId)).toHaveLength(0);
    setAgentPermissionMode(chat.agentSessionId,'ask');
    promptAgent(chat.agentSessionId,'ask demo');
    await until(()=>pendingAgentApprovals(chat.agentSessionId).length===1);
    expect(resolveAgentPermission(chat.agentSessionId,'mock-perm',false).ok).toBe(true);
    expect(busy()).toBe(false);
  } finally {closeAgentSession(chat.agentSessionId);}
});
