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
  | 'input.buttonDown'
  | 'input.buttonUp'
  | 'input.mouseMoveAbs'
  | 'input.mouseScroll'
  | 'input.keyEvent'
  | 'input.typeText'
  | 'window.list'
  | 'window.adopt'
  | 'window.release'
  | 'window.activate'
  | 'apps.list'
  | 'apps.launch'
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
    ? { quality: 'low' | 'medium' | 'high'; fps: number; windowId?: string }
    : M extends 'screen.stopCapture'
    ? { streamId: string }
    : M extends 'screen.getMetadata'
    ? {}
    : M extends 'input.mouseMove'
    ? { dx: number; dy: number }
    : M extends 'input.mouseClick'
    ? { button: 'left' | 'right' | 'middle'; x?: number; y?: number }
    : M extends 'input.buttonDown'
    ? { button: 'left' | 'right' | 'middle'; x?: number; y?: number }
    : M extends 'input.buttonUp'
    ? { button: 'left' | 'right' | 'middle'; x?: number; y?: number }
    : M extends 'input.mouseMoveAbs'
    ? { x: number; y: number }
    : M extends 'input.mouseScroll'
    ? { deltaX: number; deltaY: number; x: number; y: number; modifiers?: string[] }
    : M extends 'input.keyEvent'
    ? { key: string; modifiers?: string[] }
    : M extends 'input.typeText'
    ? { text: string }
    : M extends 'window.list'
    ? {}
    : M extends 'window.adopt'
    ? { windowId: string; viewportW?: number; viewportH?: number; dpr?: number }
    : M extends 'window.release'
    ? { windowId: string }
    : M extends 'window.activate'
    ? { windowId: string }
    : M extends 'apps.list'
    ? {}
    : M extends 'apps.launch'
    ? { appId: string; viewportW?: number; viewportH?: number; dpr?: number }
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
    ? { streamId: string; streamKey: number; region: CaptureRegion }
    : M extends 'screen.stopCapture'
    ? void
    : M extends 'screen.getMetadata'
    ? ScreenMetadata
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
    ? { region: CaptureRegion; mobileBrowser?: boolean }
    : M extends 'window.release'
    ? { ok: boolean }
    : M extends 'window.activate'
    ? { ok: boolean }
    : M extends 'apps.list'
    ? AppInfo[]
    : M extends 'apps.launch'
    ? { ok: boolean; wmClass?: string }
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

export type WsMessage =
  | { type: 'rpc-request'; request: RpcRequest }
  | { type: 'rpc-response'; response: RpcResponse }
  | { type: 'stream-frame'; streamId: string; data: string; timestamp: number }
  | { type: 'stream-region'; streamId: string; region: CaptureRegion }
  | { type: 'terminal-output'; terminalId: string; data: string }
  | { type: 'perf-update'; data: PerfSnapshot }
