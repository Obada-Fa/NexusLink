import type { WorkspaceRpc } from './workspace';
import type { ChatRpc } from './chat';
export * from './chat';
export * from './monitor';
export * from './workspace';
export type RpcMethod = keyof WorkspaceRpc | keyof ChatRpc
  | 'fs.list'
  | 'fs.read'
  | 'fs.write'
  | 'fs.delete'
  | 'fs.move'
  | 'fs.mkdir'
  | 'fs.listProjects'
  | 'fs.gitStatus'
  | 'process.list'
  | 'process.kill'
  | 'process.spawn'
  | 'terminal.create'
  | 'terminal.input'
  | 'terminal.resize'
  | 'terminal.kill'
  | 'screen.startCapture'
  | 'screen.stopCapture'
  | 'screen.getMetadata'
  | 'screen.reportStats'
  | 'screen.setQuality'
  | 'input.mouseMove'
  | 'input.mouseClick'
  | 'input.buttonDown'
  | 'input.buttonUp'
  | 'input.mouseMoveAbs'
  | 'input.mouseScroll'
  | 'input.keyEvent'
  | 'input.typeText'
  | 'window.list'
  | 'window.adopt'
  | 'window.release'
  | 'window.close'
  | 'window.activate'
  | 'apps.list'
  | 'apps.refresh'
  | 'apps.launch'
  | 'appSession.create'
  | 'appSession.list'
  | 'appSession.resize'
  | 'appSession.close'
  | 'webrtc.start'
  | 'webrtc.signal'
  | 'webrtc.stop'
  | 'clipboard.get'
  | 'clipboard.set'
  | 'agent.list'
  | 'agent.createSession'
  | 'agent.renameSession'
  | 'agent.setSessionCwd'
  | 'agent.listSessions'
  | 'agent.listHostChats'
  | 'agent.openHostChat'
  | 'agent.listModels'
  | 'agent.prompt'
  | 'agent.permission'
  | 'agent.setApprovalMode'
  | 'agent.cancel'
  | 'agent.close'
  | 'agent.history'
  | 'ide.start'
  | 'ide.stop'
  | 'ide.status'
  | 'session.pair'
  | 'session.authenticate'
  | 'session.heartbeat'
  | 'session.disconnect'
  | 'push.registerToken'
  | 'push.listTokens'
  | 'push.removeToken'
  | 'push.sendTest'
  | 'system.getInfo'
  | 'system.getPerf'

export interface RpcRequest<M extends RpcMethod = RpcMethod> {
  id: string | number
  method: M
  params?: Params<M>
}

export interface RpcResponse<T = unknown> {
  id: string | number
  result?: T
  error?: string
  code?: string
  details?: unknown
}

export type Params<M extends RpcMethod> =
  M extends keyof ChatRpc ? ChatRpc[M]['params'] : M extends keyof WorkspaceRpc ? WorkspaceRpc[M]['params'] : M extends 'fs.list'
    ? { path: string; showHidden?: boolean }
    : M extends 'fs.read'
    ? { path: string }
    : M extends 'fs.write'
    ? { path: string; content: string }
    : M extends 'fs.delete'
    ? { path: string; recursive?: boolean }
    : M extends 'fs.move'
    ? { from: string; to: string }
    : M extends 'fs.mkdir'
    ? { path: string }
    : M extends 'fs.listProjects'
    ? {}
    : M extends 'fs.gitStatus'
    ? { cwd: string }
    : M extends 'process.list'
    ? { limit?: number }
    : M extends 'process.kill'
    ? { pid: number; force?: boolean }
    : M extends 'process.spawn'
    ? { command: string; args?: string[] }
    : M extends 'terminal.create'
    ? { cols: number; rows: number; shell?: string; cwd?: string; taskId?: string; detached?: boolean; operationId?: string }
    : M extends 'terminal.input'
    ? { terminalId: string; data: string }
    : M extends 'terminal.resize'
    ? { terminalId: string; cols: number; rows: number }
    : M extends 'terminal.kill'
    ? { terminalId: string }
    : M extends 'screen.startCapture'
    ? { quality: 'low' | 'medium' | 'high' | 'full'; fps: number; windowId?: string; sessionId?: string }
    : M extends 'screen.stopCapture'
    ? { streamId: string }
    : M extends 'screen.getMetadata'
    ? {}
    : M extends 'screen.reportStats'
    ? { streamId: string; fps: number; frameAgeMs: number }
    : M extends 'screen.setQuality'
    ? { streamId: string; quality: 'low' | 'medium' | 'high' | 'full' }
    : M extends 'input.mouseMove'
    ? { dx: number; dy: number; sessionId?: string }
    : M extends 'input.mouseClick'
    ? { button: 'left' | 'right' | 'middle'; x?: number; y?: number; sessionId?: string }
    : M extends 'input.buttonDown'
    ? { button: 'left' | 'right' | 'middle'; x?: number; y?: number; sessionId?: string }
    : M extends 'input.buttonUp'
    ? { button: 'left' | 'right' | 'middle'; x?: number; y?: number; sessionId?: string }
    : M extends 'input.mouseMoveAbs'
    ? { x: number; y: number; sessionId?: string }
    : M extends 'input.mouseScroll'
    ? { deltaX: number; deltaY: number; x: number; y: number; modifiers?: string[]; sessionId?: string }
    : M extends 'input.keyEvent'
    ? { key: string; modifiers?: string[]; sessionId?: string }
    : M extends 'input.typeText'
    ? { text: string; sessionId?: string }
    : M extends 'window.list'
    ? {}
    : M extends 'window.adopt'
    ? { windowId: string; viewportW?: number; viewportH?: number }
    : M extends 'window.release'
    ? { windowId: string }
    : M extends 'window.activate' | 'window.close'
    ? { windowId: string }
    : M extends 'apps.list'
    ? {}
    : M extends 'apps.refresh'
    ? {}
    : M extends 'apps.launch'
    ? { appId: string }
    : M extends 'appSession.create'
    ? { appId: string; width: number; height: number; dpr?: number }
    : M extends 'appSession.list'
    ? {}
    : M extends 'appSession.resize'
    ? { sessionId: string; width: number; height: number }
    : M extends 'appSession.close'
    ? { sessionId: string }
    : M extends 'webrtc.start'
    ? { sessionId?: string; fps?: number }
    : M extends 'webrtc.signal'
    ? { webrtcId: string; data: WebRtcSignal }
    : M extends 'webrtc.stop'
    ? { webrtcId: string }
    : M extends 'clipboard.get'
    ? { sessionId?: string }
    : M extends 'clipboard.set'
    ? { text: string; sessionId?: string }
    : M extends 'agent.list'
    ? {}
    : M extends 'agent.createSession'
    ? { agent: string; cwd?: string; title?: string }
    : M extends 'agent.renameSession'
    ? { agentSessionId: string; title: string }
    : M extends 'agent.setSessionCwd'
    ? { agentSessionId: string; cwd: string }
    : M extends 'agent.listSessions'
    ? {}
    : M extends 'agent.listHostChats'
    ? { agent?: string }
    : M extends 'agent.openHostChat'
    ? { agent: string; hostChatId: string; cwd?: string; title?: string }
    : M extends 'agent.listModels'
    ? { agent: string }
    : M extends 'agent.prompt'
    ? {
        agentSessionId: string
        text: string
        model?: string
        mode?: AgentMode
        thinking?: string
        images?: AgentImageAttachment[]
      }
    : M extends 'agent.permission'
    ? { agentSessionId: string; requestId: string; allow: boolean }
    : M extends 'agent.setApprovalMode'
    ? { agent: string; mode: AgentApprovalMode }
    : M extends 'agent.cancel'
    ? { agentSessionId: string }
    : M extends 'agent.close'
    ? { agentSessionId: string }
    : M extends 'agent.history'
    ? { agentSessionId: string }
    : M extends 'ide.start'
    ? { cwd?: string }
    : M extends 'ide.stop'
    ? {}
    : M extends 'ide.status'
    ? {}
    : M extends 'session.pair'
    ? { publicKey: string }
    : M extends 'session.authenticate'
    ? { code: string }
    : M extends 'session.heartbeat'
    ? {}
    : M extends 'session.disconnect'
    ? {}
    : M extends 'push.registerToken'
    ? { token: string; provider?: 'fcm' | 'ntfy' | 'webhook'; endpoint?: string; name?: string }
    : M extends 'push.listTokens'
    ? {}
    : M extends 'push.removeToken'
    ? { token: string }
    : M extends 'push.sendTest'
    ? { title?: string; body?: string }
    : M extends 'system.getInfo'
    ? {}
    : M extends 'system.getPerf'
    ? {}
    : never

export type Result<M extends RpcMethod> =
  M extends keyof ChatRpc ? ChatRpc[M]['result'] : M extends keyof WorkspaceRpc ? WorkspaceRpc[M]['result'] : M extends 'fs.list'
    ? FileEntry[]
    : M extends 'fs.read'
    ? string
    : M extends 'fs.write'
    ? void
    : M extends 'fs.delete'
    ? { ok: boolean; path: string; trashed: boolean }
    : M extends 'fs.move'
    ? { path: string }
    : M extends 'fs.mkdir'
    ? { path: string; name: string }
    : M extends 'fs.listProjects'
    ? ProjectInfo[]
    : M extends 'fs.gitStatus'
    ? GitWorkingTree | null
    : M extends 'process.list'
    ? ProcessEntry[]
    : M extends 'process.kill'
    ? { ok: boolean; message: string; signal?: string; exited?: boolean }
    : M extends 'process.spawn'
    ? { pid: number }
    : M extends 'terminal.create'
    ? { terminalId: string }
    : M extends 'terminal.input'
    ? void
    : M extends 'terminal.resize'
    ? void
    : M extends 'terminal.kill'
    ? void
    : M extends 'screen.startCapture'
    ? { streamId: string; streamKey: number; region: CaptureRegion }
    : M extends 'screen.stopCapture'
    ? void
    : M extends 'screen.getMetadata'
    ? ScreenMetadata
    : M extends 'screen.reportStats'
    ? void
    : M extends 'screen.setQuality'
    ? void
    : M extends 'input.mouseMove'
    ? { ok: boolean }
    : M extends 'input.mouseClick'
    ? { ok: boolean }
    : M extends 'input.buttonDown'
    ? { ok: boolean }
    : M extends 'input.buttonUp'
    ? { ok: boolean }
    : M extends 'input.mouseMoveAbs'
    ? { ok: boolean }
    : M extends 'input.mouseScroll'
    ? { ok: boolean }
    : M extends 'input.keyEvent'
    ? { ok: boolean }
    : M extends 'input.typeText'
    ? { ok: boolean }
    : M extends 'window.list'
    ? WindowInfo[]
    : M extends 'window.adopt'
    ? { region: CaptureRegion }
    : M extends 'window.release'
    ? { ok: boolean }
    : M extends 'window.activate' | 'window.close'
    ? { ok: boolean }
    : M extends 'apps.list'
    ? AppInfo[]
    : M extends 'apps.refresh'
    ? AppInfo[]
    : M extends 'apps.launch'
    ? { ok: boolean; wmClass?: string }
    : M extends 'appSession.create'
    ? AppSessionInfo
    : M extends 'appSession.list'
    ? AppSessionInfo[]
    : M extends 'appSession.resize'
    ? { width: number; height: number; resized: boolean }
    : M extends 'appSession.close'
    ? { ok: boolean }
    : M extends 'webrtc.start'
    ? { webrtcId?: string; available: boolean; reason?: string }
    : M extends 'webrtc.signal'
    ? void
    : M extends 'webrtc.stop'
    ? void
    : M extends 'clipboard.get'
    ? { text: string }
    : M extends 'clipboard.set'
    ? { ok: boolean }
    : M extends 'agent.list'
    ? AgentInfo[]
    : M extends 'agent.createSession'
    ? AgentSessionInfo
    : M extends 'agent.renameSession'
    ? { ok: boolean; title: string }
    : M extends 'agent.setSessionCwd'
    ? AgentSessionInfo
    : M extends 'agent.listSessions'
    ? AgentSessionInfo[]
    : M extends 'agent.listHostChats'
    ? AgentHostChat[]
    : M extends 'agent.openHostChat'
    ? AgentSessionInfo
    : M extends 'agent.listModels'
    ? AgentModelOption[]
    : M extends 'agent.prompt'
    ? { ok: boolean }
    : M extends 'agent.permission'
    ? { ok: boolean; reason?: string }
    : M extends 'agent.setApprovalMode'
    ? { ok: boolean; mode?: AgentApprovalMode }
    : M extends 'agent.cancel'
    ? { ok: boolean }
    : M extends 'agent.close'
    ? { ok: boolean }
    : M extends 'agent.history'
    ? AgentEvent[]
    : M extends 'ide.start'
    ? IdeStatus
    : M extends 'ide.stop'
    ? { ok: boolean }
    : M extends 'ide.status'
    ? IdeStatus
    : M extends 'session.pair'
    ? { publicKey: string; totpIssuerUri: string }
    : M extends 'session.authenticate'
    ? { token: string }
    : M extends 'session.heartbeat'
    ? void
    : M extends 'session.disconnect'
    ? void
    : M extends 'push.registerToken'
    ? { ok: boolean; count: number }
    : M extends 'push.listTokens'
    ? Array<{ token: string; provider: string; endpoint?: string; name?: string; createdAt: number; lastSeenAt: number }>
    : M extends 'push.removeToken'
    ? { ok: boolean }
    : M extends 'push.sendTest'
    ? { sent: number; failed: number }
    : M extends 'system.getInfo'
    ? SystemInfo
    : M extends 'system.getPerf'
    ? PerfSnapshot
    : never

export interface FileEntry {
  name: string
  path: string
  size: number
  isDirectory: boolean
  modifiedAt: string
  mimeType: string
}

/** A git working tree the agent/IDE can open. */
export interface ProjectInfo {
  name: string
  path: string
}

/** Live `git status` for the agent's current folder, or null if it is not a repo. */
export interface GitWorkingTree {
  cwd: string
  branch: string
  ahead: number
  behind: number
  changed: number
  files: string[]
}

export interface IdeStatus {
  available: boolean
  running: boolean
  port?: number
  cwd?: string
  reason?: string
}

export interface ProcessEntry {
  pid: number
  name: string
  cpuPercent: number
  memMb: number
}

export interface SystemInfo {
  os: string
  hostname: string
  cpuModel: string
  totalRamGb: number
  uptimeSeconds: number
  username: string
  homeDir: string
}

export interface PerfSnapshot {
  timestamp?: number
  ramUsedBytes?: number
  ramTotalBytes?: number
  diskFreeBytes?: number | null
  cpuPercent: number
  ramPercent: number
  ramUsedGb: number
  netInKBs: number | null
  netOutKBs: number | null
  diskReadMBs: number | null
  diskWriteMBs: number | null
}

export interface ScreenMetadata {
  width: number
  height: number
}

export interface CaptureRegion {
  x: number
  y: number
  width: number
  height: number
}

/** A top-level window currently open on the host. */
export interface WindowInfo {
  windowId: string
  title: string
  /** WM_CLASS instance.class, e.g. "brave-browser.Brave-browser" */
  wmClass: string
  desktop: number
  /** data: URI (png/svg) resolved from the matching .desktop entry, if any */
  icon?: string
  appId?: string
}

/** A launchable application installed on the host (.desktop entry). */
export interface AppInfo {
  /** Desktop-file basename without extension, e.g. "org.gnome.Calculator" */
  appId: string
  name: string
  /** data: URI (png/svg), if an icon could be resolved */
  icon?: string
  /** StartupWMClass or best-guess class used to match a running window */
  wmClass?: string
}

/**
 * A phone-shaped virtual display running one app on the host. The app renders
 * at the phone's exact resolution/DPI on a headless X server — the host's real
 * desktop is never touched, and the phone sees the full surface 1:1.
 */
export interface AppSessionInfo {
  sessionId: string
  appId: string
  name: string
  icon?: string
  /** X display of the session's virtual screen, e.g. ":51" */
  display: string
  width: number
  height: number
  dpr: number
  createdAt: number
  status: 'starting' | 'running' | 'exited'
}

/** SDP / ICE payload relayed verbatim between the host encoder and the phone. */
export type WebRtcSignal =
  | { kind: 'offer' | 'answer'; sdp: string }
  | { kind: 'ice'; candidate: string; sdpMLineIndex: number }

/** Composer mode — same idea as Cursor Agent / Plan / Ask. */
export type AgentMode = 'agent' | 'plan' | 'ask'

export interface AgentModelOption {
  id: string
  name: string
  supportsEffort?: boolean
}

/** What the phone composer should offer for this CLI. */
export interface AgentCapabilities {
  modes: AgentMode[]
  thinkingLevels: string[]
  models: AgentModelOption[]
  images: boolean
  /** OpenCode-only: subscription tier detected via `opencode auth list`. */
  plan?: 'go' | 'byok' | 'unknown'
  /**
   * How this agent's permission requests are answered on the host.
   * 'ask' surfaces a card on the phone; 'auto' answers immediately so a turn
   * can never block on a phone that is not watching that session.
   */
  approvalMode?: AgentApprovalMode
}

/** Per-agent permission policy. See AgentCapabilities.approvalMode. */
export type AgentApprovalMode = 'ask' | 'auto'

/** Photo/screenshot attached from the phone (base64, already compressed). */
export interface AgentImageAttachment {
  name?: string
  mime?: string
  data: string
}

/** An AI agent CLI installed on the host (Claude Code, Cursor CLI, ...). */
export interface AgentInfo {
  id: string
  name: string
  available: boolean
  version?: string
  icon?: string
  capabilities: AgentCapabilities
}

export interface AgentSessionInfo {
  /** Latest observed activity, not an estimate of task completion. */
  activity?: 'working' | 'editing' | 'reading' | 'running-command' | 'thinking' | 'responding'
  activityAt?: number
  imported?: boolean
  taskState?: 'idle'|'running'|'waiting'|'completed'|'failed'|'canceled'|'interrupted'
  turnId?: string
  updatedAt?: number
  preview?: string
  archived?: boolean
  agentSessionId: string
  agent: string
  cwd: string
  title: string
  createdAt: number
  busy: boolean
  status: 'running' | 'exited'
  hostChatId?: string
  icon?: string
}

/** A conversation that already exists on the PC (CLI or IDE), not started from the phone. */
export interface AgentHostChat {
  agent: string
  hostChatId: string
  title: string
  cwd: string
  updatedAt: number
  resumable: boolean
  source: string
  icon?: string
}

/** Normalized event emitted by any agent adapter (superset of stream-json). */
export interface AgentEvent {
  turnId?: string
  approvalOutcome?: 'allowed'|'denied'|'canceled'|'expired'
  seq: number
  ts: number
  kind:
    | 'user'
    | 'text'
    | 'text-delta'
    | 'thinking'
    | 'tool-start'
    | 'tool-end'
    | 'permission-request'
    | 'result'
    | 'error'
    | 'status'
  text?: string
  toolName?: string
  toolInput?: string
  toolOutput?: string
  /** Correlates tool-start/tool-end pairs and permission requests. */
  refId?: string
  /** Filenames of photos attached to a user message. */
  images?: string[]
}

export type WsMessage =
  | { type: 'chat-library-update'; revision: number }
  | { type: 'rpc-request'; request: RpcRequest }
  | { type: 'rpc-response'; response: RpcResponse }
  | { type: 'stream-frame'; streamId: string; data: string; timestamp: number }
  | { type: 'stream-region'; streamId: string; region: CaptureRegion }
  | { type: 'terminal-output'; terminalId: string; data: string; seq?:number }
  | { type: 'terminal-gap'; terminalId:string;oldestSeq:number }
  | { type: 'terminal-exit';terminalId:string;exitCode:number|null;error?:string }
  | { type: 'perf-update'; data: PerfSnapshot }
  | { type: 'monitor-update'; snapshot: import('./monitor').MonitorSnapshot }
  | { type: 'webrtc-signal'; webrtcId: string; data: WebRtcSignal }
  | { type: 'app-session-update'; session: AppSessionInfo }
  | { type: 'app-session-ready'; sessionId: string }
  | { type: 'agent-session-update'; session: AgentSessionInfo }
  | { type: 'agent-session-deleted'; agentSessionId: string }
  | { type: 'agent-event'; agentSessionId: string; event: AgentEvent }
  | { type: 'activity-update'; record: import('./workspace').ActivityRecord }
  | { type: 'apps-update'; apps: AppInfo[] }
  | { type: 'windows-update'; windows: WindowInfo[] }
