# @nexuslink/desktop

Linux/X11 NexusLink host. Next.js UI + Tauri 2 shell + Bun RPC server.

On Windows, run the dedicated host instead: `bun run windows` (`apps/windows-host`). Do not add further `win32` branches here.

## Start

```bash
bun run dev             # Next.js dev on :3000
bun run tauri           # Tauri dev (requires Rust toolchain)
```

## Architecture

- `src/app/` — Next.js pages (pairing, home)
- `src/server/` — Bun WebSocket RPC server on :45678
- `src/lib/` — desktop runtime utilities
- `src-tauri/` — Tauri 2 Rust shell

## Scripts

- `bun run dev` — Next.js dev server
- `bun run build` — Next.js production build
- `bun run start` — Next.js production start
- `bun run tauri` — Tauri desktop window
