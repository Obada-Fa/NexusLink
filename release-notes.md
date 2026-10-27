## NexusLink Test 1.0.38+44 — Mission Control

NexusLink is now an agent monitor first. The previous version is saved as the git branch `stable` (tag `stable-1.0.36+42`, APK in `dist/stable/`).

**Monitor tab (Mission Control)**
- One screen for every agent on the PC: counters for Working / Needs you / Done today (tap to filter), "Needs you" and "Live now" cards with the current step, a ticking timer, plan progress and the last message, then recent chats grouped by day.
- Live PC vitals strip (CPU, GPU, RAM with temperatures, network).
- Agent apps strip: Claude, Codex, Antigravity, Cursor and agent CLIs with CPU/memory and one-tap Restart, Quit or Force stop. A frozen app is flagged "Frozen?".
- RustDesk alert with one-tap Restart when it can't reach the desktop.
- **Arena**: every agent is a fox at its own desk — it sprints while running commands, sniffs while reading, pounces while editing, barks when it needs you, celebrates when it finishes and naps when idle. The den's campfire burns with CPU load and the moon glows with GPU load.
- Projects view groups chats by folder.
- **Mark as done**: swipe a "Needs you" card sideways, or long-press any chat (cards, rows, Arena foxes) for Open, Mark as done, Flag again, Hide from Monitor and Open project files. Undo is offered. The mark is kept on the PC, so it applies everywhere until that chat does something new.
- "Needs you" that an app infers (for example Claude Desktop's needs-action flag) clears by itself after 8 hours without activity. Real pending approvals in chats NexusLink is running never expire.

**PC tab**
- Vitals: CPU / GPU / RAM gauges with temperature glow, detail sheets (per-core load, GPU hotspot/memory temperature, power vs cap, fan, VRAM, swap), network, disk, storage warning, peripheral batteries.
- Agent apps with Restart (closes normally, force-stops after 6 s if frozen, relaunches), Focus, Quit, Force stop; CLI agents with Stop.
- Remote access health for RustDesk, Tailscale and the NexusLink host, with Restart RustDesk.
- Top processes with End process; View desktop (control or view-only); running windows with Close / Restart menus.

**Reliability**
- Reconnects automatically to your last PC at launch; a revoked pairing shows "Pair again" instead of a silent "PC offline".
- Session tokens renew in place before they expire (they used to lapse after an hour).
- No list flicker on reconnect; live agent events are no longer dropped; Stop reports the real result.
- Approvals for chats you are not looking at appear in a banner.
- Open PC chats update live with a progress header.
- Background monitor survives reboots and app updates (if you left it on).
- Files: readable sizes and dates, image preview, Move / Delete (to the PC's Trash).

**PC host (Linux)** — deploy with `bash scripts/deploy-host.sh`
- New monitor API: vitals, agent apps, remote-access health; RustDesk watchdog.
- Apps launched or restarted from the phone survive NexusLink restarts.
- Waits for Tailscale at boot instead of staying up with no listener.
- VS Code server requires a per-session token; downloads resume correctly; screen streams stop when access expires; a frozen app can no longer hang the host.

This APK is **NexusLink Test** (com.nexuslink.nexuslink.test), built with this PC's debug signing as in the preceding Test releases, so it updates the existing Test installation.
