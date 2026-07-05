# @nexuslink/desktop

NexusLink host desktop application. Next.js UI + Tauri 2 shell + Bun RPC server.

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
