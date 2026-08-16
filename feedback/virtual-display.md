# Vertical virtual display (session viewport)

## 2026-08-16

### Idea

When a phone session starts, create a **vertical virtual display** with the phone’s
aspect ratio (from `viewportW` / `viewportH` / DPR). Run adopted apps **fullscreen on
that display** and stream only that output.

### Why

- Always vertical and fitting — no letterboxing / wrong aspect on the phone.
- Avoids fighting Chromium/Brave restore-bounds on the physical monitor.
- Leaves the user’s real desktop untouched.
- Touch mapping becomes display-local (simpler than per-window crop + letterbox).

### Relation to current code

- Today: `PhysicalBackend` via `window.adopt` (portrait rect on the primary monitor) +
  per-window `x11grab` — interim.
- Target: `VirtualBackend` already sketched in `architecture.md` Module B2 / Phase 10
  (Windows IddCx; Linux evdi / wlroots headless).

### Suggested behavior

1. Session connect → `acquire_viewport({ cssW, cssH, dpr })` creates/attaches virtual output.
2. App open → move + fullscreen onto that output (not resize-on-primary).
3. Capture → whole virtual display (or the fullscreen window on it).
4. Session end → release apps, destroy/detach virtual display, restore any saved state.

### Fallback

If virtual display cannot be created (missing driver / Wayland portal limits), keep the
current physical adopt + re-clamp path.
