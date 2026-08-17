# NexusLink

Remote desktop that feels like a phone OS: the PC runs the apps, the phone is the
screen. Tapping an app opens it in a **phone-shaped virtual display** on the host
(your real desktop is never resized). Chrome launches with a mobile user-agent so
sites reflow like native Chrome. Claude Code, Cursor CLI, OpenCode, and Antigravity run on the PC and
show up as a chat UI on the phone.

## Architecture

```
phone (PWA or Flutter)
  launcher ── WS RPC :45678 ── PC host (Bun)
                 │
                 ├── appSession  → Xvfb + openbox per app (exact phone pixels)
                 ├── MJPEG WS    → ffmpeg x11grab of that display (always-on)
                 ├── WebRTC      → GStreamer webrtcbin H.264 + Opus (upgrade)
                 ├── PTY         → python pty-host.py → xterm on the phone
                 └── agents      → Claude Code / Cursor CLI / OpenCode / Antigravity → chat UI
```

Control plane is the existing ECDH-paired JSON WebSocket. Video upgrades to
WebRTC when GStreamer is present; MJPEG stays as the automatic fallback.

## Install

```bash
bun install
```

Linux/X11 host needs:

- `ffmpeg`, `xdotool`, `wmctrl`, `xclip` (already used by the LAN path)
- `xvfb`, `openbox` (per-app virtual displays)
- `python3` + GStreamer (`gstreamer1.0-tools`, `gstreamer1.0-plugins-{good,bad}`,
  `gir1.2-gst-plugins-bad-1.0`) for H.264 WebRTC
- `pulseaudio-utils` for per-session audio sinks

## Quick Start (LAN) — scan & go

```bash
bun run lan          # builds the PWA, then starts the unified host on :45678
```

The host prints a **QR code** for every address it is reachable at:

- **Local Wi-Fi** (same network)
- **Tailscale** (any network, as long as the phone and PC are on the same tailnet)

Scan either square — the page auto-connects. Example: `http://192.168.2.30:45678` and `http://100.x.y.z:45678`.

- **Phone**: scan the **local** QR on the same Wi-Fi, or the **Tailscale** QR from anywhere
  on the tailnet — the browser opens and auto-connects. Tap an app — it opens full-screen
  on the phone, nothing moves on the PC. The dock has Terminal and Agents.
- **PC**: open `http://localhost:45678`. Your desktop stays fully usable.

One port serves the app *and* the control WebSocket. The client derives the host from the
page it was served from, so there is no address to enter.

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
- **Mobile**: Next.js 14 PWA + Flutter (Riverpod, flutter_webrtc, xterm, markdown)
- **Relay**: Bun WebSocket server (port 3033)
- **Packages**: TypeScript types, touch gesture engine, SVG UI components
- **Sidecar**: Rust (Tokio, Serde) JSON-RPC helper
- **Host extras**: Xvfb virtual displays, GStreamer webrtcbin, PTY helper, agent gateway

## Project Layout

```
apps/
  desktop/          Tauri + Next.js host app (virtual sessions, WebRTC, agents)
  mobile-client/    Next.js PWA client
  flutter_client/   Flutter Android client
  relay/            Bun WebSocket signaling relay
packages/
  rpc-types/        Shared TypeScript RPC types
  gesture-engine/   Touch-to-input translation
  ui-components/    React SVG components
sidecar/            Rust sidecar binary
```

## License

MIT
