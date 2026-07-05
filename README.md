# NexusLink

Remote desktop: host from Tauri desktop, control from mobile PWA. ECDH-paired WebSocket RPC, room-based relay signaling, gesture-engine touch-to-input translation.

## Architecture

```
desktop (Tauri+Next.js) ──┐
                           ├── relay (Bun WS) ──┐
mobile-client (Next.js PWA)┘                    │
                                                │
shared: @nexuslink/rpc-types, gesture-engine, ui-components
sidecar: Rust JSON-RPC helper
```

## Install

```bash
bun install
```

Requires [Bun](https://bun.sh) >= 1.x, [Rust](https://rustup.rs) for Tauri/sidecar.

## Dev

```bash
bun run dev          # all apps in parallel (turbo)
```

Per-app:

```bash
cd apps/desktop && bun run dev      # http://localhost:3000
cd apps/mobile-client && bun run dev # http://localhost:3001
cd apps/relay && bun run dev         # ws://localhost:3033
```

## Build

```bash
bun run build        # all apps (turbo)
```

Per-app:

```bash
cd apps/desktop && bun run build         # Next.js static export
cd apps/mobile-client && bun run build   # Next.js static export + PWA
cd apps/relay && bun run build           # bun build --target=bun
cd sidecar && cargo build --release      # Rust sidecar binary
```

## Test

```bash
bun test              # workspace-wide
```

Per-package:

```bash
bun test              # in each package/app directory
```

## Relay

```bash
cd apps/relay
RELAY_PORT=3033 bun run start
```

- WebSocket at `ws://localhost:3033/room/<roomId>`
- Health check at `http://localhost:3033/health`
- Max 2 peers per room (1 host + 1 client), 30-minute room expiry

## Pairing Flow

1. Desktop opens `/pair`, clicks "Start Pairing" to connect to signaling server
2. Desktop sends `session.pair` with ECDH public key, receives TOTP URI
3. Mobile opens `/pair`, enters server URL, receives pairing code (first 8 chars of TOTP secret)
4. User enters pairing code on desktop, desktop generates TOTP and sends `session.authenticate`
5. Desktop returns session token, connection established
6. In development, localhost connections bypass TOTP with dev tokens

## Stack

- **Desktop**: Tauri 2.0, Next.js 14, Bun RPC server (port 45678)
- **Mobile**: Next.js 14, Zustand, xterm.js, PWA manifest
- **Relay**: Bun WebSocket server (port 3033)
- **Packages**: TypeScript types, touch gesture engine, SVG UI components
- **Sidecar**: Rust (Tokio, Serde) JSON-RPC helper

## Project Layout

```
apps/
  desktop/          Tauri + Next.js host app
  mobile-client/    Next.js PWA client
  relay/            Bun WebSocket signaling relay
packages/
  rpc-types/        Shared TypeScript RPC types
  gesture-engine/   Touch-to-input translation
  ui-components/    React SVG components
sidecar/            Rust sidecar binary
```

## License

MIT
