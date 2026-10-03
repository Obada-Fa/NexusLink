/** Additive protocol-v2 contracts. Legacy platform-specific operations remain in index.ts. */
import type { AgentEvent, AgentSessionInfo, FileEntry } from './index';
export interface HostCapabilities {
  protocolVersion: 2; hostId: string; hostVersion: string; platform: string;
  features: string[]; methods: string[];
  terminal: {available:boolean; backend:string; maxSessions:number};
  files: {maxEditBytes:number;maxEditLines:number};
  streaming: {experimental:true;available:boolean;reason:string|null};
}
export interface TerminalSummary {
  terminalId:string;cwd:string;shell:string;taskId?:string;
  cols:number;rows:number;createdAt:number;state:'running'|'exited';exitCode:number|null;seq:number;error?:string;
}
export interface TextDocument {
  path:string;requestedPath:string;content:string;bytes:number;revision:string|null;
  modifiedAt:string;bom:boolean;lineEnding:'lf'|'crlf'|'mixed';writable:boolean;
  readOnlyReason:string|null;truncated:boolean;binary:boolean;mode:number;
}
export interface AuthSession {token:string;expires:number;hostId:string;deviceId:string}
export interface WorkspaceRpc {
  'session.hello': {params:{};result:{protocolVersion:2}};
  'session.enroll': {params:{code:string;name:string};result:AuthSession & {credential:string}};
  'session.resume': {params:{credential:string;role?:'control'|'monitor'};result:AuthSession};
  'session.getCapabilities': {params:{};result:HostCapabilities};
  'session.subscribe': {params:{topics:Array<'agents'|'metrics'|'windows'>;metricsInterval?:number};result:{ok:boolean}};
  'terminal.list': {params:{};result:TerminalSummary[]};
  'terminal.attach': {params:{terminalId:string;afterSeq?:number};result:TerminalSummary & {gap:boolean;oldestSeq:number}};
  'terminal.detach': {params:{terminalId:string};result:{ok:boolean}};
  'fs.readText': {params:{path:string};result:TextDocument};
  'fs.writeText': {params:{path:string;content:string;expectedRevision:string|null;operationId:string;bom?:boolean};result:TextDocument};
  'fs.listPage': {params:{path:string;cursor?:string;limit?:number;showHidden?:boolean;query?:string;sort?:string};result:{path:string;entries:Array<FileEntry & {isSymlink?:boolean;error?:string}>;nextCursor:string|null;total:number}};
  'fs.rename': {params:{from:string;to:string;operationId?:string};result:{path:string}};
  'fs.gitChanges': {params:{cwd:string};result:{cwd:string;files:Array<{path:string;absolutePath:string;status:string;from?:string;staged:boolean;unstaged:boolean;untracked:boolean}>}};
  'fs.gitDiff': {params:{cwd:string;path:string;staged?:boolean};result:{text:string;truncated:boolean;binary:boolean}};
  'transfer.authorize': {params:{path:string};result:{token:string;expires:number;path:string;size:number}};
  'agent.historyPage': {params:{agentSessionId:string;beforeSeq?:number;afterSeq?:number;limit?:number};result:{events:AgentEvent[];oldestSeq:number|null;latestSeq:number|null;hasMore:boolean}};
  'agent.pendingApprovals': {params:{agentSessionId:string};result:AgentEvent[]};
  'agent.archive': {params:{agentSessionId:string;archived?:boolean};result:{ok:boolean}};
  'activity.snapshot': {params:{cursor?:number};result:{sessions:AgentSessionInfo[];cursor:number;events:Array<{cursor:number;type:'agent-event';agentSessionId:string;event:Pick<AgentEvent,'seq'|'ts'|'kind'|'turnId'|'refId'>}>}};
}
export const WORKSPACE_METHODS = [
  'session.hello','session.enroll','session.resume','session.getCapabilities','session.subscribe',
  'terminal.list','terminal.attach','terminal.detach','fs.readText','fs.writeText','fs.listPage','fs.rename',
  'fs.gitChanges','fs.gitDiff','transfer.authorize','agent.historyPage','agent.pendingApprovals','agent.archive','activity.snapshot',
] as const satisfies readonly (keyof WorkspaceRpc)[];
