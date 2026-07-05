# @nexuslink/mobile-client

NexusLink mobile client. Next.js PWA with gesture engine, xterm.js terminal, and file browser.

## Start

```bash
bun run dev     # Next.js dev on :3001
bun run build   # production build with PWA service worker
```

## Architecture

- `src/app/` — pages: pairing, terminal, files, processes, system, mirror
- `src/components/` — ConnectionProvider, GestureOverlay
- `src/lib/` — RPC client, auth client
- `src/store/` — Zustand connection store

## Scripts

- `bun run dev` — Next.js dev server
- `bun run build` — Next.js production build
- `bun run start` — Next.js production start
- `bun test` — run tests
