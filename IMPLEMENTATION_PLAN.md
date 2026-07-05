# NexusLink Plan
## Stage 1 - Monorepo scaffold
Create structure:
- apps/desktop (Tauri 2.0 host)
- apps/mobile-client (Next.js PWA)
- packages/rpc-types
- packages/gesture-engine
- packages/ui-components
- sidecar (Rust stub)
- turbo.json, package.json workspaces, bun.lock

## Stage 2 - RPC bridge core
- Shared types: RpcMethod, RpcRequest, RpcResponse, Params, Result, FileEntry, ProcessEntry, SystemInfo, PerfSnapshot, WsMessage in packages/rpc-types.
- Tauri IPC stubs in src-tauri/src.
- Bun WebSocket server stubs in apps/desktop with fs/process/system/terminal handlers.
- Wire Next.js into Tauri via tauri.conf beforeDevCommand/beforeBuildCommand/devUrl.

## Stage 3 - Mobile UI
- Add PWA/manifest/connection/rpc client to apps/mobile-client.
- Home screen and component pages for terminal, files, processes, system, mirror mode.

## Stage 4 - Gestures and input
- Gesture engine library in packages/gesture-engine.
- Mirror mode overlay and remote command mapping.

## Stage 5 - Network and auth
- Signaling handshake in Bun server.
- ECDH/TOTP pairing layer.
- Relay server scaffold.

## Execution rule
Do one stage at a time, verify with test/build command, then continue.
