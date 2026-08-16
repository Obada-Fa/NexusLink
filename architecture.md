# NexusLink — System Architecture & Production Blueprint

> Canonical design document for NexusLink's evolution from a LAN prototype into a
> commercial-grade, WAN-capable remote-control ecosystem. This file supersedes the
> conceptual goals; `plan.md` is retained as the historical phase-prompt record.

## 1. Vision & Paradigm Shifts

NexusLink today is a working **LAN prototype**: a Bun WebSocket RPC server hosted inside
the Tauri desktop app, a Next.js PWA mobile client (terminal / files / processes / system
views), a JSON room relay, and an ECDH+TOTP pairing flow.

We are expanding to a commercial product built on three paradigm shifts:

1. **Mobile OS Abstraction** — the phone stops being a trackpad and becomes a
   native-feeling mobile OS view of the PC: desktop apps are presented in a portrait
   viewport, and touch is *direct manipulation* (momentum scroll, long-press context,
   pinch-zoom), not cursor emulation.
2. **Sustainable WAN** — networking evolves from LAN-only to control-from-anywhere via
   WebRTC P2P with a self-hosted rendezvous / STUN / relay stack for NAT traversal.
3. **The Unified Connection Engine** — two pipelines run in parallel:
   - **Infrastructure Control Line** (Rust sidecar): screen capture, H.264 encode,
     input injection, window orchestration — native performance.
   - **App Component Line** (Bun server): structured data (directory trees, shells,
     process lists) rendered into mobile-optimized React views.

### Locked technical decisions
- **Window management** — *hybrid, phased*: Phase 1 physical window resize + per-window
  capture; Phase 2 driver-level virtual portrait display; both behind one
  `DisplayBackend` interface.
- **Video** — H.264 **hardware** encode, native WebRTC in the Rust sidecar
  (`webrtc-rs`); Bun handles signaling only.

## 2. Current-State Audit

| Area | File | State |
|---|---|---|
| RPC contract | `packages/rpc-types/src/index.ts` | Typed method union + `WsMessage`; no `window.*`, `signal.*`, or auth-v2 messages |
| Bun RPC server | `apps/desktop/src/server/index.ts` | Works; dispatch switch; **auth not enforced per-method**; `123456` TOTP backdoor |
| Auth | `apps/desktop/src/server/handlers/auth.ts` | ECDH P-256 + hand-rolled TOTP; `totpIssuerUri` leaks `pairingId` as the "secret" (client cannot compute a real TOTP — protocol broken); localhost auto-token bypass; keys in memory only |
| Relay | `apps/relay/src/index.ts`, `room.ts` | JSON-parses and re-wraps every frame (`relay-message`) — **not** a blind byte forwarder; no room auth; no STUN |
| Gesture engine | `packages/gesture-engine/src/index.ts` | Trackpad paradigm; no inertia; discrete scroll ticks. `scaleToHost()` letterbox math is solid and retained |
| Terminal | `apps/desktop/src/server/handlers/terminal.ts` | **Not stubbed** — works via `Bun.spawn` pipes (degraded: no real TTY, `resize` is a no-op `SIGWINCH` to a piped process). Bypasses the sidecar entirely |
| Sidecar | `sidecar/src/main.rs` | Only `ping`. No PTY, capture, or input injection |
| Mirror mode | `apps/mobile-client/src/app/mirror/page.tsx` | Placeholder div; `stream-frame` subscription is a no-op; no WebRTC in the codebase |
| Signaling | `apps/desktop/src/server/handlers/signaling.ts` | 34-line room broadcast stub, unused by any real peer |

**Implication:** the sidecar is effectively greenfield; the Bun server, mobile UI shell,
RPC types, and relay skeleton are the reusable base. The terminal works but must be moved
onto a real PTY.

## 2.1 Shipped: Working LAN Implementation (pure-Bun X11 path)

Rather than block the entire product on the Rust sidecar + WebRTC stack, the LAN path is
implemented **without Rust** by driving standard Linux/X11 tooling directly from the Bun
server. This makes NexusLink a genuinely working remote desktop today; the Rust/WebRTC
design below remains the target for WAN and cross-platform (Windows/Wayland) hardening.

| Capability | Implementation | File |
|---|---|---|
| Input injection | `xdotool` (mousemove/click/scroll/key), serialized queue + backpressure | `apps/desktop/src/server/handlers/input.ts` |
| Screen capture | `ffmpeg -f x11grab` → MJPEG pipe, SOI-framed, base64 `stream-frame` over WS | `apps/desktop/src/server/handlers/capture.ts` |
| Screen metadata | `xdotool getdisplaygeometry` (cached) | `capture.ts` `getScreenMetadata()` |
| Mirror render | `<img>` fed base64 JPEG frames via a ref (no per-frame React re-render) | `apps/mobile-client/src/app/mirror/page.tsx` |
| Touch → input | Gesture Engine v2 → `input.*` RPC, fire-and-forget | `apps/mobile-client/src/components/GestureOverlay.tsx` |
| Zero-config connect | Client auto-derives `ws://<page-origin-host>:45678/rpc` and auto-connects | `apps/mobile-client/src/lib/host-url.ts`, `ConnectionProvider.tsx` |
| Single port | Bun host serves the exported PWA **and** the RPC WS on `:45678` | `apps/desktop/src/server/static-server.ts` |
| QR launch | Host prints a scannable QR of `http://<lan-ip>:45678` on startup | `apps/desktop/src/server/launch-banner.ts` |

**Connection UX (no IP typing):** the PWA is served by the host, so the browser origin
*is* the host address. On load the client derives the RPC URL from `window.location` and
connects automatically; the manual form is an "Advanced" fallback. The host prints a QR of
its own LAN URL at startup, so a phone scans → browser opens → already connected → mirror.
One port (`45678`) carries the page, assets, and the WebSocket. Build once with
`bun run build` in `apps/mobile-client` (or `bun run lan` from the repo root, which builds
then starts the unified host). The RustDesk-style short-**ID** rendezvous (Module A) is the
next step, removing the same-LAN requirement for WAN.

Verified end-to-end on X11 (`DISPLAY=:0`): `screen.getMetadata` → 1920×1080, `startCapture`
delivers valid JPEG frames, and `input.mouseClick {x,y}` / `input.mouseMove {dx,dy}` land the
pointer on exact host coordinates. Capture sessions are torn down on `stopCapture` and on
socket close (no leaked `ffmpeg`).

**How this maps to the grand design:** this path is the `direct WS (LAN)` transport in the
topology below. When the Rust sidecar + WebRTC land, capture/input become backends behind the
same RPC surface (`screen.*`, `input.*`), and the `rpc` DataChannel tunnels these exact
messages over WAN — no client changes. `xdotool`/`ffmpeg` remain the X11 fallback.

### 2.2 Shipped: Mobile OS Abstraction, LAN/X11 edition (Module B v1)

The phone home screen is now a real launcher and per-app portrait sessions work end-to-end
(pure Bun + X11 tooling; the Rust `DisplayBackend` remains the cross-platform target):

| Capability | Implementation | File |
|---|---|---|
| `window.list` | `wmctrl -lx` + `xprop` type/state filtering; windows matched to `.desktop` entries (normalized WM_CLASS fuzzy match) for names/icons | `apps/desktop/src/server/handlers/windows.ts` |
| `apps.list` | `.desktop` catalog (system, snap, flatpak dirs) + freedesktop icon resolution → base64 data URIs, cached | same |
| `window.adopt` | unmaximize + `wmctrl -e` portrait rect **right-anchored on the primary monitor**, original geometry journaled and restored on `window.release` | same |
| `apps.launch` | `gio launch` (Exec-parse fallback); client polls `window.list` until the window appears, then adopts | same + `mirror/page.tsx` |
| Per-window capture | `ffmpeg x11grab` of the window rect; **watchdog re-grabs when the window moves** and pushes `stream-region` so touch mapping follows | `handlers/capture.ts` |
| Multi-monitor | virtual-screen size from `xrandr`; full-desktop mirror captures the **primary monitor**, not `0,0`; all input offsets through the returned region | `capture.ts`, `GestureOverlay.tsx` |
| Launcher UI | home = running windows row + installed-app grid (real icons, search) + tools dock; tap → auto-adopt → auto-stream (no Start button) | `mobile-client/src/app/page.tsx` |
| Keyboard | `input.typeText` (`xdotool type`) + special keys from a phone keyboard bar in the mirror | `handlers/input.ts`, `mirror/page.tsx` |

Verified live on Zorin/X11 with stacked dual monitors (1920×2280 virtual): launcher lists
11 windows / 133 apps (100 icons), Brave and a cold-launched Calculator both adopt to
portrait and stream at 15 fps, and injected taps land within ~15 px of the touch point
(letterbox rounding) inside the adopted window.

### 2.3 Shipped: M0 + M1 — Production Flutter App & Low-Latency Foundation (2026-07-19)

**M0 — Performance Foundation** (`commit e7b3384`, LAN/X11 Bun server):
- Binary WebSocket frames (24fps): JPEG → 16-byte NLF1 header (streamId hash + timestampMs LE) + raw JPEG, no base64-JSON overhead (→ 25% bandwidth reduction, no decode jitter).
- Persistent input injector: `xdotool -` (script mode stdin) instead of per-event process spawns → **0.04ms round-trip per input event** (was 10–30ms), no process spawn overhead, ordering free.
- Full gesture forwarding: drag (via `buttonDown`/`mouseMoveAbs`/`buttonUp` RPC) + pinch-zoom (→ `input.mouseScroll` with `modifiers: ['ctrl']` at the pinch midpoint).
- Auth backdoor removed: `123456` TOTP bypass deleted; localhost auto-token gated behind `NEXUSLINK_DEV=1` env var (Module D1.1, D1.3).

**M1.0 — Server Discovery & File Transfer** (`commit 1de4c95`, Bun):
- mDNS `_nexuslink._tcp` responder (pure-Bun, no Avahi): responds to PTR/SRV/TXT/A queries, multicast replies + unicast for ephemeral ports, startup announce. Clients auto-discover on LAN.
- HTTP /files endpoints: `GET /files?path=<abs>` streams download with Content-Length/Disposition; `POST /files?path=<abs>&overwrite=1` buffers upload to memory then writes (workaround: Bun.write from live request stream stalls — requires `await req.arrayBuffer()`). Both use host-coord paths, with traversal rejection + overwrite protection.

**M1.1–M1.4 — Flutter Android App** (`commit 4826b6f` + `commit 61efeaa`, apps/flutter_client/):
- **Dart RPC client** — faithful port of the TS `WsMessage` protocol (request/response by id, topic subscriptions, auto-reconnect w/ backoff, binary NLF1 frame parsing). ~250 LOC; live-host test validates RPC + mirror frames + fs.list + HTTP round-trip.
- **Connect screen** — mDNS discovery + manual ws:// entry, zero-config on single-host LAN.
- **Launcher** — Riverpod state (connection provider, cached apps, 5s-polled windows), running windows row, searchable app grid with real icons (data-URI decode or monogram fallback), tap → auto-adopt → auto-stream.
- **Mirror** — adopt → capture → binary-frame render + full gesture input via the ported gesture engine (lib/src/gestures/: 4 Dart files, 39 unit tests, complete port of the TS FSM/inertia/scaleToHost logic). Persistent Ticker drives inertia; raw Listener + multi-touch for the FSM; live region sync. Keyboard bar + special-key buttons.
- **Files screen** — browse via `fs.list` (path bar, up button, folder entry), download (stream to temp + share_plus sheet), upload deferred (file_picker 11 fails on AGP-9/Kotlin-2.3.20 toolchain; server endpoint done & tested).
- **System screen** — static `system.getInfo` + live CPU/mem meters (perf-update push + 2s poll fallback).
- **Native vs stream registry** — dock tools are registered (`files` / `system` = native RPC UI, no capture; installed apps + open windows = adopt + stream). See §2.4.
- **Build verified** — `flutter analyze` clean, APK builds (assembleDebug ok, ~150MB debug), 41 tests pass (gesture unit + widget + live-host protocol), 24fps sustained on `:45678` host.

**Resume on another PC:**
- Clone the repo, `cd apps/desktop && bun run src/server/index.ts` starts the host (mDNS on LAN, HTTP `:45678`).
- Install Flutter 3.44.6 from ~/development/flutter (not on PATH: `export PATH="$HOME/development/flutter/bin:$PATH"`), then `flutter build apk --debug` or `flutter install` if a phone is plugged in.
- Tests: `flutter test` (41 pass), live-host test needs the server running.
- Next: git log shows commits; `plan.md` and this file document the architecture; M2 requires Rust (not yet installed — `rustup` is step one).

### 2.4 Native vs stream routing

**Rule:** registered native tool ids open RPC-backed mobile screens and must never
start screen capture. Everything else (`.desktop` apps and open windows) goes through
`window.adopt` + per-window pixel stream.

| Path | Examples | Client entry |
|---|---|---|
| Native RPC | Files, System (Flutter); Terminal / Files / Tasks / System (PWA) | `apps/flutter_client/lib/src/shell/native_registry.dart`, `apps/mobile-client/src/lib/native-registry.ts` |
| Stream | Brave, Calculator, any open window, full Desktop | `MirrorScreen` / `/mirror` after adopt |

Per-app remappers (e.g. browser chrome as a native UI) are a later product track —
add them to the registry when they ship; do not special-case in the launcher.

## 3. System Topology — The Unified Connection Engine

```
 MOBILE CLIENT (Next.js PWA)                      DESKTOP HOST
┌───────────────────────────┐                    ┌──────────────────────────────────────┐
│ Mobile Shell (launcher,   │                    │ Tauri 2.0 app                        │
│ app switcher, viewport)   │                    │  ├─ Next.js host dashboard           │
│ Gesture Engine v2         │                    │  └─ Bun server (App Component Line)   │
│ Transport Manager         │                    │       RPC dispatch, fs/proc/sys,     │
│  ├─ direct WS (LAN)       │◄──── LAN WS ──────►│       auth broker, signaling client  │
│  ├─ WebRTC (P2P WAN)      │                    │ Rust sidecar (Infra Control Line)    │
│  └─ relay WS (fallback)   │◄═ WebRTC media ═══►│  ├─ webrtc-rs peer (video+DC)        │
└───────────┬───────────────┘   + datachannels   │  ├─ capture → H.264 HW encode        │
            │                                     │  ├─ input injection (uinput/SendInput)│
            │        SELF-HOSTED EDGE             │  ├─ window orchestrator (Module B)   │
            │  ┌──────────────────────────────┐   │  └─ PTY manager                      │
            └─►│ apps/relay (Bun): rendezvous │◄──┘                                      
               │  + signaling rooms + API     │
               │ crates/relay-media (Rust):   │
               │  STUN binding + blind TCP/UDP│
               │  byte relay (TURN-lite)      │
               └──────────────────────────────┘
```

**Channel plan (one NAT traversal, everything multiplexed):**

| Channel | Transport | Reliability | Carries |
|---|---|---|---|
| `video` | WebRTC video track (H.264/RTP) | unreliable | screen stream of the managed portrait viewport |
| `input` | DataChannel, unordered, `maxRetransmits=0` | unreliable | Module C gesture events (seq-numbered, coalesced) |
| `rpc` | DataChannel, ordered reliable | reliable | the **entire existing Bun WS protocol** tunneled — `WsMessage` frames verbatim, so the dispatch and all mobile views work unchanged over WAN |
| `bulk` | DataChannel, ordered reliable | reliable | file transfer chunks, clipboard |

On LAN the Transport Manager skips WebRTC and uses the direct WS to `:45678` as today
(with mDNS `_nexuslink._tcp` discovery added). The mobile `RpcClient` gains a pluggable
`Transport` interface; its `call()` / `subscribe()` API is unchanged.

---

## Module A — Global WAN Networking Infrastructure

### A1. Roles (three self-hostable planes, two binaries)
1. **Rendezvous + Signaling** — extend `apps/relay` (Bun). Host registrations, ephemeral
   signaling rooms, relay-token minting. State in memory + optional `bun:sqlite`.
2. **STUN** — minimal RFC 5389 Binding on UDP 3478 in the new Rust `crates/relay-media`
   (reuse the webrtc-rs family `stun` crate).
3. **Relay (TURN-lite)** — same Rust binary: a blind byte splicer (RustDesk-style, *not*
   full RFC 5766). Peers present an HMAC relay token minted by rendezvous; the relay pairs
   flows and pipes bytes, never parsing payloads — fixing the current relay's JSON re-wrap.

### A2. Identity & addressing
- Each host generates a long-lived **Ed25519 device identity** (Module D).
  `deviceId = base58(SHA-256(pubkey)[0..12])`, rendered as a short code + QR.
- Host holds one outbound WSS to rendezvous:
  `REGISTER {deviceId, pubkey, sig(nonce), caps, natType}` with 25s heartbeats (TTL 60s).
  Rendezvous stores only opaque IDs and pubkeys — zero knowledge of session keys.
- Client resolves `deviceId → SESSION_REQUEST`; rendezvous opens an ephemeral room and
  pushes `SESSION_INCOMING` to the host.

### A3. WebRTC handshake
1. Client → rendezvous: `SESSION_REQUEST {deviceId, clientPubkey, authProof}` (authProof =
   signed pairing token; unpaired clients get only a pairing channel, never media).
2. Rendezvous relays SDP offer (host owns tracks) / answer + trickle ICE. All signaling
   payloads are sealed envelopes encrypted to the peer's identity key; DTLS fingerprints
   inside are signed (D3), so a rendezvous compromise cannot MITM.
3. ICE gathering: host + srflx (own STUN) + relay candidate (pre-authorized).
4. DTLS-SRTP up; sidecar attaches the video track + 3 DataChannels; the Bun server is
   bridged onto the `rpc` channel via a local loopback WS (`tunnel`).

### A4. NAT hole-punching state machine (Transport Manager, both ends)
```
IDLE → DISCOVER_LAN (mDNS, 750ms budget) ──hit──► DIRECT_WS
  │miss
  ▼
SIGNALING (rendezvous room join, exchange NAT class + candidates)
  │
  ├─ both NATs symmetric? ──yes──► RELAYED (skip futile ICE, ~0s connect)
  ▼ no
ICE_PUNCHING (simultaneous UDP bursts to srflx candidates; RFC 8445-lite; 4s timeout)
  ├─ pair succeeds ──► DIRECT_P2P (STUN keepalive every 15s)
  └─ timeout ────────► RELAYED (encrypted bytes via relay-media)
DIRECT_P2P ──network change (cellular↔wifi)──► ICE_RESTART
RELAYED ────background retry P2P every 60s──► seamless upgrade under same session keys
```
- NAT classified at registration (RFC 5780-style, two ports):
  `full-cone | restricted | port-restricted | symmetric`, stored so the client pre-decides.
- Cellular reality: many carriers are CGNAT-symmetric → relay is a first-class path.
  Budget: sub-2s relay connect, sub-4s P2P.

### A5. Relay protocol (blind)
```
frame := len:u32 | ciphertext          (already E2E encrypted, Module D)
join  := token:HMAC(rendezvous_secret, sessionId|role|exp)   validated once, then a dumb pipe.
         Per-session byte quota + bandwidth cap; metrics: bytes, sessions, punch-success-rate.
```
Bun keeps *signaling* rooms (JSON is fine there); the *data* path moves to
`crates/relay-media`.

---

## Module B — Window Control & Aspect-Ratio Enforcement

### B1. Concept: the host runs a "phone-shaped WM session"
The client never sees the raw 16:9 desktop. The sidecar's **Window Orchestrator** presents
*one app at a time* in a portrait viewport whose logical size comes from the phone
(`viewport {cssW, cssH, dpr}`, e.g. 390×844@3 → 1170×2532 capture, scaled to encoder
budget). The launcher + app switcher are Component-Line UI, not video.

### B2. `DisplayBackend` trait (the hybrid seam)
```rust
trait DisplayBackend {
    fn acquire_viewport(&mut self, spec: ViewportSpec) -> ViewportHandle;
    fn adopt_window(&mut self, win: WindowId, vp: &ViewportHandle);
    fn release_all(&mut self);
    fn capture_target(&self) -> CaptureTarget; // per-window | display-region | virtual-display
}
```
- **Phase 1 — `PhysicalBackend`**: portrait rect on the physical display (right-anchored,
  height-fit); `SetWindowPos` / `XMoveResizeWindow` the window in; save original geometry
  per window; restore on session end or crash (journal file survives a killed sidecar).
- **Phase 2 — `VirtualBackend`**: Windows IddCx indirect display (exact phone res + DPI);
  Linux evdi / wlroots headless output. Physical monitor untouched.

### B3. Per-OS window tracking & enforcement
| | Enumerate / track | Move / resize | Events | Notes |
|---|---|---|---|---|
| Windows | `EnumWindows` + `SetWinEventHook(LOCATIONCHANGE, FOREGROUND)` | `SetWindowPos` (+ `DWMWA_EXTENDED_FRAME_BOUNDS`) | WinEvent hook | Re-clamp debounced 150ms when Chrome/Brave restore-bounds fight back |
| Linux X11 | EWMH `_NET_CLIENT_LIST` via x11rb | `XMoveResizeWindow` + drop `_NET_WM_STATE` MAXIMIZED | `Property/ConfigureNotify` | Works on all major X11 WMs |
| Linux Wayland | `wlr-foreign-toplevel-management` / KDE eqv | limited → prefer `VirtualBackend` | protocol events | GNOME: no protocol → VirtualBackend / full-screen fallback |

Capture follows the backend: **per-window preferred** (Windows.Graphics.Capture per-HWND;
X11 XComposite `NameWindowPixmap`) so overlaps never bleed; fallback is display-region crop
via `scap`. Wayland: PipeWire portal.

### B4. New RPC surface (extends `packages/rpc-types`)
`window.list` (apps + icons), `window.adopt {windowId | launch: appId}`, `window.release`,
`window.switch`, `window.setViewport {cssW, cssH, dpr, orientation}`, event `window-state`.
Icons: Windows `SHGetFileInfo`; Linux `.desktop` + icon theme → base64 over `rpc`.

### B5. Mobile shell UX (App Component Line)
`apps/mobile-client/src/shell/`: home = launcher grid of host apps (from `window.list`)
alongside existing native tools; tapping an app calls `window.adopt` and swaps to the video
viewport; bottom-edge swipe-up = app switcher (cards = last capture keyframes); orientation
change re-sends `window.setViewport`. Existing routes are preserved.

---

## Module C — Touch Gesture Normalization Matrix

### C1. Paradigm: direct manipulation replaces trackpad
The finger touches *content at an absolute host coordinate* (`scaleToHost()` reused for the
mapping, including letterbox offsets). One-finger vertical pan scrolls the content under the
finger with momentum — the cursor does not chase the finger. The legacy relative-cursor path
survives only as **Precision mode** (fallback).

### C2. The Matrix
| Touch input | Classifier | Wire event (`input`) | Host injection (Win / Linux) |
|---|---|---|---|
| 1f tap (<180ms, <8px) | `tap` | `pointer.tap {x,y}` | move-abs + left down/up |
| 1f double tap | `double-tap` | `pointer.double {x,y}` | double click |
| 1f pan | `scroll` | `scroll.delta {x,y,dxPx,dyPx,seq,t}` | **hi-res wheel**: Win `MOUSEEVENTF_WHEEL` fractional; Linux uinput `REL_WHEEL_HI_RES` (120 units/notch) |
| flick release | `scroll-inertia` (client physics keeps emitting) | same `scroll.delta` | same |
| long-press 400ms (<10px) | `context` | `pointer.context {x,y}` + `vibrate(10)` | right click |
| long-press → move | `drag` | `drag.start/move/end {x,y}` | left-down, abs moves, left-up |
| 2f pinch | `zoom` | `zoom.delta {scale, cx, cy}` | Ctrl + hi-res wheel at midpoint |
| 2f pan | `scroll` | `scroll.delta` | hi-res wheel |
| 3f tap | `middle-click` | `pointer.middle {x,y}` | middle click |
| edge gestures | consumed by shell (never forwarded) | — | — |
| Precision toggle | legacy relative cursor | `mouse-move {dx,dy}` | relative move |

### C3. Scroll physics (client-side, `packages/gesture-engine/src/scroll-physics.ts`)
- Velocity: EMA over touch deltas, `v ← α·(Δx/Δt) + (1−α)·v`, α≈0.4, Δt clamped ≥ 4ms.
- On release, if `|v| > 250 px/s` → inertia on rAF: `v(t+dt) = v·e^(−λ·dt)`, λ≈3.3 s⁻¹
  (~300ms time constant, iOS-like); emit `scroll.delta` per frame until `|v| < 4 px/s`;
  a new touchstart cancels instantly (finger-catch).
- Axis lock: within the first 12px, the dominant axis wins (±22.5° cone); unlock on pinch.
- Host-side sub-pixel accumulation of fractional wheel units → slow pans stay smooth.

### C4. Wire discipline
- `input` DataChannel is unordered/lossy; every event carries `seq` + client timestamp; the
  host drops stale `scroll.delta` (seq regression) and coalesces to its injection tick
  (≤240Hz). `drag.*` / `pointer.*` are mirrored on the reliable `rpc` channel if unacked
  >80ms (clicks must never be lost; scroll may be).
- Client coalesces to 1 move/scroll per rAF and never awaits RPC responses for input
  (fire-and-forget replaces the current per-gesture round-trip).

### C5. Package refactor
Keep the public surface (`GestureEngine`, `attach/detach`, `setHostDimensions`,
`scaleToHost`, exported constants) and split internals: `classifier.ts` (FSM),
`scroll-physics.ts`, `input-mapper.ts` (classifier output → seq-numbered wire events). The
`GestureEvent` union is *extended* (adds `drag-*`, `zoom`, inertial scroll), not replaced.
Host side: `sidecar/src/input/` per-OS backends (`windows.rs` SendInput, `linux_uinput.rs`
with `REL_WHEEL_HI_RES`, XTest fallback).

---

## Module D — Security Protocol & Zero-Trust Architecture

### D1. Audited holes to close
1. Remove the `123456` universal TOTP bypass (server dispatch, `session.authenticate`).
2. Stop leaking `pairingId` in `totpIssuerUri`; the TOTP scheme is replaced by D2.
3. Localhost auto-token: gate behind `NEXUSLINK_DEV=1`; never in release builds.
4. Enforce auth middleware *per RPC method* before dispatch.
5. Relay stops parsing payloads (A5).

### D2. Identity & pairing (replaces ECDH+TOTP)
- **Device identities**: Ed25519 per host and per client, generated on first run. Host key
  in the OS keychain (DPAPI / libsecret; file fallback encrypted with a machine-derived HKDF
  key). Mobile key in IndexedDB as non-extractable WebCrypto where possible.
- **Pairing (one-time, OOB)**: desktop shows QR =
  `{deviceId, hostIdentityPubkey, rendezvousUrl, pairingNonce}`. Phone scans (or types
  deviceId + PIN). Both run ephemeral X25519 ECDH authenticated by the QR pubkey → derive a
  pairing secret → host shows a 6-digit **SAS** from the transcript hash; user confirms on
  both screens (defeats first-pair MITM). Host signs a **client certificate**
  `sig_host(clientPubkey, caps, issuedAt)`, stored on the phone.
- **Session auth (every connect)**: client presents its certificate + signs a server nonce.
  **Stateless tokens**: `token = payload{clientId, caps, exp, sessionId} + Ed25519 sig(host)`,
  verified without a store; in-memory revocation set for explicit un-pair.

### D3. Transport encryption (E2E, no third-party cloud)
- **P2P**: DTLS-SRTP natively. Each peer signs its DTLS fingerprint with its identity key
  inside the sealed signaling envelope; the peer verifies before trusting.
- **Relay**: application-layer AEAD (relay sees only bytes): ephemeral X25519 ECDH
  (identity-signed) → HKDF-SHA256 → two directional XChaCha20-Poly1305 keys;
  `frame = nonce_ctr:u64 | ciphertext|tag`; monotonic nonce window (replay protection).
  The same framing wraps the LAN direct-WS path, so LAN is E2E too (today it is plaintext).
- **Signaling envelopes**: `crypto_box`-style (X25519 + XChaCha20-Poly1305) to identity keys.

### D4. Capability-scoped authorization
Token `caps` is a scope set: `screen.view, input.inject, fs.read, fs.write, terminal,
process.kill, window.manage, clipboard`. Dispatch checks scope per method via a single
`RpcMethod → scope` map in `rpc-types`. Default pairing grants view+input+terminal;
destructive scopes require a per-device toggle. Privileged actions hit a local audit ring
buffer surfaced in the desktop UI.

### D5. Hardening baseline
Constant-time MAC/sig comparisons; 5-failure → 60s IP backoff on pairing endpoints;
rendezvous holds no secrets (opaque IDs, pubkeys, 60s-TTL HMAC relay tokens); server-side
input rate limit (~2k events/s ceiling); WSS on all rendezvous/relay listeners.

---

## 4. File Tree Modification Map

```
nexuslink/
├── architecture.md                    THIS FILE — canonical design doc
├── apps/
│   ├── desktop/
│   │   ├── src/server/
│   │   │   ├── index.ts               MODIFY — per-method auth+scope middleware; remove 123456;
│   │   │   │                                    mount tunnel bridge; keep dispatch structure
│   │   │   ├── auth/                  NEW (replaces handlers/auth.ts)
│   │   │   │   ├── identity.ts        Ed25519 device identity + keychain storage
│   │   │   │   ├── pairing.ts         QR/SAS ceremony, client-cert issuance
│   │   │   │   └── tokens.ts          stateless signed tokens, scopes, revocation
│   │   │   ├── signaling-client.ts    NEW — rendezvous registration + session broker
│   │   │   ├── tunnel.ts              NEW — sidecar `rpc` DataChannel ⇆ local Bun WS
│   │   │   ├── crypto/frames.ts       NEW — XChaCha20 AEAD framing
│   │   │   └── handlers/…             KEEP; terminal moves onto the real sidecar PTY
│   │   ├── src/app/pair/page.tsx      MODIFY — QR + SAS ceremony UI
│   │   └── src-tauri/                 MODIFY — sidecar lifecycle, orchestrator commands
│   ├── mobile-client/
│   │   ├── src/lib/transport/         NEW — Transport iface + DirectWs|WebRtc|Relay + FSM (A4)
│   │   ├── src/lib/rpc-client.ts      MODIFY — consume Transport (public API unchanged)
│   │   ├── src/shell/                 NEW — launcher, app switcher, viewport (B5)
│   │   ├── src/app/mirror/page.tsx    REWRITE — <video> + WebRTC track + GestureOverlay v2
│   │   └── src/components/GestureOverlay.tsx  MODIFY — new gesture events, fire-and-forget
│   ├── relay/                         REWRITE — rendezvous: registrations, signaling rooms,
│   │   └── src/{registry.ts,rooms.ts,tokens.ts}     relay-token minting, /health+metrics
│   └── deploy/                        NEW — docker-compose: Bun rendezvous + Rust relay-media
├── crates/                            NEW Rust workspace (sidecar joins it)
│   └── relay-media/                   NEW — STUN (RFC 5389) + blind byte relay (A1/A5)
├── packages/
│   ├── rpc-types/src/index.ts         MODIFY — window.*, signal.*, auth-v2, scope map
│   ├── protocol/                      NEW — TS wire framing + AEAD envelope (Rust mirror)
│   ├── gesture-engine/src/
│   │   ├── index.ts                   MODIFY — public API kept; internals delegated
│   │   ├── classifier.ts             NEW — FSM (C2/C5)
│   │   ├── scroll-physics.ts         NEW — inertia integrator (C3)
│   │   └── input-mapper.ts           NEW — classifier → seq-numbered wire events
│   └── ui-components/                 MODIFY — shell primitives (app cards, switcher)
└── sidecar/                           MAJOR EXPANSION (joins crates/ workspace)
    └── src/
        ├── main.rs                    MODIFY — dispatch grows; keeps stdin/stdout JSON-RPC
        ├── webrtc/                    NEW — webrtc-rs peer, track + 3 DCs, ICE, DTLS binding
        ├── capture/{mod.rs,source.rs,encode_h264.rs}  NEW — per-window sources → HW encode
        ├── input/{mod.rs,windows.rs,linux_uinput.rs,xtest.rs}  NEW — hi-res injection
        ├── window_manager/{mod.rs,physical.rs,virtual_display.rs}  NEW — Module B
        ├── pty.rs                     NEW — portable-pty sessions
        └── crypto.rs                  NEW — identity sigs, AEAD frames (relay path)
```

---

## 5. Implementation Plan — Phases 6–10

Numbering continues from `plan.md` (Phases 1–5 delivered the prototype).

### Phase 6 — Sidecar Foundation & Terminal Unblocking
Move the terminal onto a real PTY and stand up the sidecar's control surface.
- `sidecar/`: `portable-pty` + `uuid`; `pty.rs` (create/write/resize/kill, base64
  `terminal-output` to stdout); wire `terminal.*` into JSON-RPC dispatch.
- `apps/desktop/src/server/handlers/terminal.ts`: route through the sidecar; `Map<terminalId, ws>`.
- `sidecar/src/input/`: `InputDevice` trait + Win/Linux skeletons; wire `input.*`.
- `sidecar/src/capture/`: `CaptureTarget` enum + target enumeration; stub encoder.
- **Exit**: `cargo build --release` clean; mobile terminal opens a real shell with output;
  input RPC path accepted; `bun test` green.

### Phase 7 — Security v2
- `auth/identity.ts` (Ed25519 + keychain), `auth/pairing.ts` (QR/SAS + client cert),
  `auth/tokens.ts` (stateless signed tokens + scopes).
- `rpc-types`: `RPC_SCOPES` map. Server: per-method auth+scope middleware; remove all
  backdoors (`123456`, unconditional dev token).
- `packages/protocol` + `sidecar/src/crypto.rs`: XChaCha20-Poly1305 framing (LAN E2E).
- **Exit**: QR+SAS pairing works; unauthenticated / out-of-scope RPC rejected; security
  suite green; `cargo audit` clean.

### Phase 8 — WAN
- `apps/relay` rewrite (`registry.ts` / `rooms.ts` / `tokens.ts`), sealed signaling.
- `crates/relay-media` (STUN + blind relay).
- `sidecar/src/webrtc/` peer (video track + 3 DCs, ICE, DTLS binding) + `encode_h264.rs`
  (MediaFoundation / VAAPI / NVENC; openh264 fallback).
- `apps/mobile-client/src/lib/transport/` Transport Manager (A4) + `tunnel.ts` bridge.
- **Exit**: phone on cellular controls a NATed host via P2P; relay failover <3s; video
  15fps @ 1–4 Mbps; `bun test` + `cargo test` green.

### Phase 9 — Mobile OS Abstraction
- `sidecar/src/window_manager/` `DisplayBackend` + `PhysicalBackend` (+ restore journal).
- `window.*` RPC handlers + icon extraction.
- `apps/mobile-client/src/shell/` launcher / switcher / viewport.
- `packages/gesture-engine` v2 (classifier + scroll-physics + input-mapper); hi-res input
  injection in the sidecar; `GestureOverlay` v2 (fire-and-forget).
- **Exit**: Brave opens portrait-constrained; one-finger momentum scroll feels native;
  pinch-zoom + long-press context work; placement restored on disconnect.

### Phase 10 — Virtual Display (premium, post-release)
- `VirtualBackend` (Windows IddCx / Linux evdi) behind `DisplayBackend`; physical monitor
  untouched, true mobile DPI.

---

## 6. Verification Strategy

- **Unit**: `packages/gesture-engine` (inertia decay curve, axis lock, classifier FSM,
  tap/scroll/drag/zoom); `packages/protocol` AEAD round-trip + nonce-replay; relay token
  HMAC; `cargo test` for the window-restore journal and input mapper.
- **Integration (scripted)**: `bun test` E2E spawning relay + two headless clients across
  Linux network namespaces (`ip netns` + nftables masquerade) to prove DIRECT_P2P vs
  RELAYED selection; assert punch-success-rate.
- **Manual/live**: phone on cellular vs host on LAN — pair via QR, open Brave, verify
  portrait constraint, momentum scroll, pinch zoom, long-press context; kill P2P (block UDP)
  mid-session and confirm relay failover; confirm desktop placement restored on disconnect.
- **Security gates (CI)**: grep-gate that `123456` / unconditional dev tokens never ship in
  release bundles; replay a captured relay frame and assert rejection.

## 7. Environment Prerequisites

- **Bun ≥ 1.x** — present (1.3.14). Drives all TS/JS packages, the server, and tests.
- **Rust toolchain** (`rustup`, `cargo`) — **required for the sidecar, `crates/relay-media`,
  and Tauri**; not yet installed in every dev environment. Phases 6, 8, and 9 have Rust work
  items that cannot build/test without it. TS-only slices (gesture-engine v2, auth-v2 TS,
  relay rewrite, transport manager) proceed independently.
