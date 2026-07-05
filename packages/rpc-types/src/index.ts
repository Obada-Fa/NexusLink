export type RpcMethod =
  | 'fs.list'
  | 'fs.read'
  | 'fs.write'
  | 'fs.delete'
  | 'fs.move'
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
  | 'input.mouseMove'
  | 'input.mouseClick'
  | 'input.mouseScroll'
  | 'input.keyEvent'
  | 'session.pair'
  | 'session.authenticate'
  | 'session.heartbeat'
  | 'session.disconnect'
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
}

export type Params<M extends RpcMethod> =
  M extends 'fs.list'
    ? { path: string; showHidden?: boolean }
    : M extends 'fs.read'
    ? { path: string }
    : M extends 'fs.write'
    ? { path: string; content: string }
    : M extends 'fs.delete'
    ? { path: string }
    : M extends 'fs.move'
    ? { from: string; to: string }
    : M extends 'process.list'
    ? {}
    : M extends 'process.kill'
    ? { pid: number }
    : M extends 'process.spawn'
    ? { command: string; args?: string[] }
    : M extends 'terminal.create'
    ? { cols: number; rows: number; shell?: string }
    : M extends 'terminal.input'
    ? { terminalId: string; data: string }
    : M extends 'terminal.resize'
    ? { terminalId: string; cols: number; rows: number }
    : M extends 'terminal.kill'
    ? { terminalId: string }
    : M extends 'screen.startCapture'
    ? { quality: 'low' | 'medium' | 'high'; fps: number }
    : M extends 'screen.stopCapture'
    ? { streamId: string }
    : M extends 'screen.getMetadata'
    ? {}
    : M extends 'input.mouseMove'
    ? { dx: number; dy: number }
    : M extends 'input.mouseClick'
    ? { button: 'left' | 'right' | 'middle'; x?: number; y?: number }
    : M extends 'input.mouseScroll'
    ? { deltaX: number; deltaY: number; x: number; y: number }
    : M extends 'input.keyEvent'
    ? { key: string; modifiers?: string[] }
    : M extends 'session.pair'
    ? { publicKey: string }
    : M extends 'session.authenticate'
    ? { code: string }
    : M extends 'session.heartbeat'
    ? {}
    : M extends 'session.disconnect'
    ? {}
    : M extends 'system.getInfo'
    ? {}
    : M extends 'system.getPerf'
    ? {}
    : never

export type Result<M extends RpcMethod> =
  M extends 'fs.list'
    ? FileEntry[]
    : M extends 'fs.read'
    ? string
    : M extends 'fs.write'
    ? void
    : M extends 'fs.delete'
    ? void
    : M extends 'fs.move'
    ? void
    : M extends 'process.list'
    ? ProcessEntry[]
    : M extends 'process.kill'
    ? void
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
    ? { streamId: string }
    : M extends 'screen.stopCapture'
    ? void
    : M extends 'screen.getMetadata'
    ? ScreenMetadata
    : M extends 'input.mouseMove'
    ? { ok: boolean }
    : M extends 'input.mouseClick'
    ? { ok: boolean }
    : M extends 'input.mouseScroll'
    ? { ok: boolean }
    : M extends 'input.keyEvent'
    ? { ok: boolean }
    : M extends 'session.pair'
    ? { publicKey: string; totpIssuerUri: string }
    : M extends 'session.authenticate'
    ? { token: string }
    : M extends 'session.heartbeat'
    ? void
    : M extends 'session.disconnect'
    ? void
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
  cpuPercent: number
  ramPercent: number
  ramUsedGb: number
  netInKBs: number
  netOutKBs: number
  diskReadMBs: number
  diskWriteMBs: number
}

export interface ScreenMetadata {
  width: number
  height: number
}

export type WsMessage =
  | { type: 'rpc-request'; request: RpcRequest }
  | { type: 'rpc-response'; response: RpcResponse }
  | { type: 'stream-frame'; streamId: string; data: string; timestamp: number }
  | { type: 'terminal-output'; terminalId: string; data: string }
  | { type: 'perf-update'; data: PerfSnapshot }
