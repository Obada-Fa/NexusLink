import type { RpcMethod } from '@nexuslink/rpc-types';
import { WorkspaceError, stringParam, intParam, hostId, downloadToken } from './security';
import { readText, writeText, listPage, renameFile, gitChanges, gitDiff, hostPath, EDIT_BYTES } from './files';
import { listTerminals, attachTerminal, detachTerminal, hasPty } from '../handlers/terminal';
import { stat } from 'node:fs/promises';
import { CHAT_METHODS } from '../../../../../packages/chat-core/src/index';
let chatLibraryReady = false;
export function setChatLibraryReady(ready: boolean) { chatLibraryReady = ready; }
const mutations = new Map<string, { fingerprint: string; result: Promise<unknown> }>();
export async function once(device: string, method: string, params: Record<string,unknown>, action: () => unknown) {
  const operation = stringParam(params, 'operationId', true);
  if (!operation) return await action();
  const key = `${device}:${method}:${operation}`;
  const fingerprint = JSON.stringify(params);
  const old = mutations.get(key);
  if (old) {
    if (old.fingerprint !== fingerprint) throw new WorkspaceError('INVALID_ARGUMENT','Operation ID reused with different arguments.');
    return old.result;
  }
  const result = Promise.resolve().then(action);
  mutations.set(key, { fingerprint, result });
  while (mutations.size > 2048) mutations.delete(mutations.keys().next().value!);
  return await result;
}
export const SUPPORTED_METHODS = ['activity.monitor', 'activity.snapshot', 'activity.snapshotV2', 'activity.action', 'activity.actionStatus', 'agent.archive', 'agent.cancel', 'agent.close', 'agent.createSession', 'agent.history', 'agent.historyPage', 'agent.list', 'agent.listHostChats', 'agent.listModels', 'agent.listSessions', 'agent.openHostChat', 'agent.pendingApprovals', 'agent.permission', 'agent.prompt', 'agent.renameSession', 'approvals.configure', 'approvals.list', 'approvals.resolve', 'approvals.status', 'agent.setApprovalMode', 'agent.setSessionCwd', 'appSession.close', 'appSession.create', 'appSession.list', 'appSession.resize', 'apps.launch', 'apps.list', 'apps.refresh', 'clipboard.get', 'clipboard.set', 'fs.delete', 'fs.gitChanges', 'fs.gitDiff', 'fs.gitStatus', 'fs.list', 'fs.listPage', 'fs.listProjects', 'fs.mkdir', 'fs.move', 'fs.read', 'fs.readText', 'fs.rename', 'fs.writeText', 'ide.start', 'ide.status', 'ide.stop', 'monitor.appAction', 'monitor.remoteAction', 'monitor.snapshot', 'input.cursorHint', 'input.buttonDown', 'input.buttonUp', 'input.keyEvent', 'input.mouseClick', 'input.mouseMove', 'input.mouseMoveAbs', 'input.mouseScroll', 'input.typeText', 'mic.start', 'mic.status', 'mic.stop', 'process.kill', 'process.list', 'push.listTokens', 'push.registerToken', 'push.removeToken', 'push.sendTest', 'screen.getMetadata', 'screen.listMonitors', 'screen.reportStats', 'screen.setQuality', 'screen.startCapture', 'screen.stopCapture', 'session.disconnect', 'session.enroll', 'session.getCapabilities', 'session.heartbeat', 'session.hello', 'session.resume', 'session.subscribe', 'system.getInfo', 'system.getPerf', 'system.getVitals', 'terminal.attach', 'terminal.create', 'terminal.detach', 'terminal.input', 'terminal.kill', 'terminal.list', 'terminal.resize', 'transfer.authorize', 'webrtc.signal', 'webrtc.start', 'webrtc.stop', 'window.activate', 'window.adopt', 'window.close', 'window.list', 'window.release'] as const;
export function capabilities() {
  return { protocolVersion: 2, hostId:hostId(), hostVersion:'2.0.0', platform:process.platform,
    methods:[...SUPPORTED_METHODS,...(chatLibraryReady ? CHAT_METHODS : [])],
    features:['monitor.v1','fs.delete','fs.move','process.kill','screen.monitors','input.cursor.v1','screen.quality.v1','terminal.attach','fs.readText','fs.writeText','fs.listPage','fs.rename','fs.gitChanges','fs.gitDiff','transfer.authorize','session.subscribe','agent.historyPage','agent.archive','agent.pendingApprovals','activity.snapshot','activity.v2','activity.monitor.v1','activity.actions.v1','window.close','window.activate','mic.v1','approvals.v1',...(chatLibraryReady ? ['chat.library.v1','chat.state.v1'] : [])],
    terminal:{ available:hasPty(), backend:'python-pty', maxSessions:12 }, files:{maxEditBytes:EDIT_BYTES,maxEditLines:20000},
    streaming:{experimental:true,available:!!process.env.DISPLAY,reason:process.env.DISPLAY?null:'Requires an X11 display'} };
}
export async function workspaceRequest(method:string, p:Record<string,unknown>, ws:WebSocket, deviceId:string) {
  switch(method) {
    case 'session.getCapabilities': return {handled:true,result:capabilities()};
    case 'terminal.list': return {handled:true,result:listTerminals()};
    case 'terminal.attach': return {handled:true,result:attachTerminal(stringParam(p,'terminalId'),ws,intParam(p,'afterSeq',0,0,Number.MAX_SAFE_INTEGER))};
    case 'terminal.detach': detachTerminal(stringParam(p,'terminalId'),ws); return {handled:true,result:{ok:true}};
    case 'fs.readText': return {handled:true,result:await readText(stringParam(p,'path'))};
    case 'fs.writeText': {
      if(p.expectedRevision!==null && typeof p.expectedRevision!=='string') throw new WorkspaceError('INVALID_ARGUMENT','A saved revision is required.');
      stringParam(p,'operationId');
      return {handled:true,result:await once(deviceId,method,p,()=>writeText(stringParam(p,'path'),stringParam(p,'content',true),p.expectedRevision as string|null,p.bom===true))};
    }
    case 'fs.listPage': return {handled:true,result:await listPage(stringParam(p,'path'),{cursor:stringParam(p,'cursor',true),hidden:p.showHidden===true,query:stringParam(p,'query',true),sort:stringParam(p,'sort',true),limit:intParam(p,'limit',200,1,200)})};
    case 'fs.rename': return {handled:true,result:await once(deviceId,method,p,()=>renameFile(stringParam(p,'from'),stringParam(p,'to')))};
    case 'fs.gitChanges': return {handled:true,result:await gitChanges(stringParam(p,'cwd'))};
    case 'fs.gitDiff': return {handled:true,result:await gitDiff(stringParam(p,'cwd'),stringParam(p,'path'),p.staged===true)};
    case 'transfer.authorize': {
      const path=hostPath(stringParam(p,'path')); const info=await stat(path);
      if(!info.isFile()) throw new WorkspaceError('INVALID_ARGUMENT','Only regular files can be downloaded.');
      return {handled:true,result:{...downloadToken(deviceId,path),path,size:info.size}};
    }
    default:return {handled:false,result:undefined};
  }
}
export function validateRequest(method:string,p:Record<string,unknown>) {
  if(!p || typeof p!=='object' || Array.isArray(p)) throw new WorkspaceError('INVALID_ARGUMENT','Parameters must be an object.');
  for(const key of ['path','cwd','agentSessionId','terminalId','agent','requestId','data','text','title','shell','operationId'])
    if(p[key]!==undefined && typeof p[key]!=='string') throw new WorkspaceError('INVALID_ARGUMENT',`Invalid ${key}.`);
  if(method==='session.enroll') {
    if(!/^\d{8}$/.test(stringParam(p,'code'))) throw new WorkspaceError('INVALID_ARGUMENT','Pairing code must contain eight digits.');
    const name=stringParam(p,'name'); if(name.length>100) throw new WorkspaceError('INVALID_ARGUMENT','Device name is too long.');
  }
  if(method==='session.resume') {
    const credential=stringParam(p,'credential');
    if(credential.length<32 || credential.length>256) throw new WorkspaceError('INVALID_ARGUMENT','Invalid device credential.');
    if(p.role!==undefined && p.role!=='control' && p.role!=='monitor') throw new WorkspaceError('INVALID_ARGUMENT','Invalid connection role.');
  }
  if(method==='session.subscribe') {
    if(!Array.isArray(p.topics) || p.topics.some(topic=>!['agents','metrics','windows','activity','monitor'].includes(topic))) throw new WorkspaceError('INVALID_ARGUMENT','Invalid subscription topics.');
    if(p.metricsInterval!==undefined && p.metricsInterval!==2000 && p.metricsInterval!==5000) throw new WorkspaceError('INVALID_ARGUMENT','Metrics interval must be two or five seconds.');
    if(p.monitorInterval!==undefined && ![1000,2000,5000].includes(p.monitorInterval as number)) throw new WorkspaceError('INVALID_ARGUMENT','Monitor interval must be one, two or five seconds.');
  }
  if(method==='terminal.create' || method==='terminal.resize') { intParam(p,'cols',80,1,1000); intParam(p,'rows',24,1,1000); }
  if(method==='terminal.input') { stringParam(p,'terminalId'); stringParam(p,'data',true); }
  if(method==='terminal.attach') { stringParam(p,'terminalId');intParam(p,'afterSeq',0,0,Number.MAX_SAFE_INTEGER); }
  if(method==='terminal.detach' || method==='terminal.kill') stringParam(p,'terminalId');
  if(method==='fs.readText' || method==='transfer.authorize' || method==='fs.listPage' || method==='fs.delete') stringParam(p,'path');
  if(method==='fs.move') { stringParam(p,'from'); stringParam(p,'to'); }
  if(method==='process.kill' && (typeof p.pid!=='number' || !Number.isSafeInteger(p.pid))) throw new WorkspaceError('INVALID_ARGUMENT','A process ID is required.');
  if(method==='screen.startCapture' && p.monitor!==undefined && (typeof p.monitor!=='string' || !/^[\w.-]{1,40}$/.test(p.monitor))) throw new WorkspaceError('INVALID_ARGUMENT','Invalid monitor name.');
  if(method==='fs.listPage') {
    if(p.sort!==undefined && !['name','date','size'].includes(p.sort as string)) throw new WorkspaceError('INVALID_ARGUMENT','Invalid sort order.');
    if(p.showHidden!==undefined && typeof p.showHidden!=='boolean') throw new WorkspaceError('INVALID_ARGUMENT','Invalid hidden-file setting.');
    intParam(p,'limit',200,1,200);
    if(p.cursor!==undefined && !/^\d+$/.test(stringParam(p,'cursor'))) throw new WorkspaceError('INVALID_ARGUMENT','Invalid directory cursor.');
  }
  if(method==='fs.writeText') {
    stringParam(p,'path');stringParam(p,'operationId');
    if(typeof p.content!=='string' || p.content.length>EDIT_BYTES) throw new WorkspaceError('INVALID_ARGUMENT','Invalid text content.');
    if(p.expectedRevision!==null && (typeof p.expectedRevision!=='string' || !/^[a-f0-9]{64}$/.test(p.expectedRevision))) throw new WorkspaceError('INVALID_ARGUMENT','Expected revision is required.');
    if(p.bom!==undefined && typeof p.bom!=='boolean') throw new WorkspaceError('INVALID_ARGUMENT','Invalid BOM setting.');
  }
  if(method==='fs.rename') {stringParam(p,'from');stringParam(p,'to');}
  if(method==='fs.gitChanges') stringParam(p,'cwd');
  if(method==='fs.gitDiff') {stringParam(p,'cwd');stringParam(p,'path');if(p.staged!==undefined && typeof p.staged!=='boolean') throw new WorkspaceError('INVALID_ARGUMENT','Invalid staged flag.');}
  if(method==='agent.historyPage') {stringParam(p,'agentSessionId');intParam(p,'limit',100,1,200);if(p.beforeSeq!==undefined && p.afterSeq!==undefined) throw new WorkspaceError('INVALID_ARGUMENT','Choose one history cursor.');if(p.beforeSeq!==undefined)intParam(p,'beforeSeq',0,1,Number.MAX_SAFE_INTEGER);if(p.afterSeq!==undefined)intParam(p,'afterSeq',0,0,Number.MAX_SAFE_INTEGER);}
  if(method==='activity.snapshot') intParam(p,'cursor',0,0,Number.MAX_SAFE_INTEGER);
  if(method==='activity.snapshotV2') {intParam(p,'cursor',0,0,Number.MAX_SAFE_INTEGER);if(p.throughCursor!==undefined)intParam(p,'throughCursor',0,0,Number.MAX_SAFE_INTEGER);}
  if(method==='activity.action') {
    for(const key of ['operationId','hostId','agentSessionId','expectedTurnId'])stringParam(p,key);
    intParam(p,'sourceCursor',0,1,Number.MAX_SAFE_INTEGER);
    if(!['approve','deny','reply'].includes(p.action as string))throw new WorkspaceError('INVALID_ARGUMENT','Invalid notification action.');
    if(p.action==='reply'){const text=stringParam(p,'text');if(!text.trim()||Buffer.byteLength(text,'utf8')>8192)throw new WorkspaceError('INVALID_ARGUMENT','Reply must be 1–8192 UTF-8 bytes.');}
    else stringParam(p,'requestId');
  }
  if(method==='activity.actionStatus')stringParam(p,'operationId');
  if(method==='agent.permission' && typeof p.allow!=='boolean') throw new WorkspaceError('INVALID_ARGUMENT','Approval must be a boolean.');
  if(method==='approvals.resolve'){
    if(typeof p.id!=='string'||!p.id||!['allow','deny'].includes(p.decision as string)) throw new WorkspaceError('INVALID_ARGUMENT','Approval needs an id and allow or deny.');
    if(p.answers!==undefined&&(!p.answers||typeof p.answers!=='object'||Array.isArray(p.answers)||Object.values(p.answers).some(v=>typeof v!=='string'))) throw new WorkspaceError('INVALID_ARGUMENT','Answers must map each question to text.');
    if(p.message!==undefined&&typeof p.message!=='string') throw new WorkspaceError('INVALID_ARGUMENT','Invalid message.');
  }
  if(method==='approvals.configure'&&((p.claude!==undefined&&typeof p.claude!=='boolean')||(p.holdTerminal!==undefined&&typeof p.holdTerminal!=='boolean'))) throw new WorkspaceError('INVALID_ARGUMENT','Settings must be on or off.');
}
