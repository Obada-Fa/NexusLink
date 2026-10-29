## NexusLink Test 1.0.40+46 — Agent campus and phone approvals

**Arena: a pannable pixel campus**
- Each project you worked on in the last 7 days (or that has an agent running now) gets its own room. Rooms that need you come first.
- Every agent is a pixel character at its own desk, styled by app (Claude, Codex, Antigravity, Cursor, OpenCode). It types while editing, goes to the bookshelf while reading or browsing, works at the server rack while running commands, waits by the door when it needs you, relaxes in the lounge when it's done, and sleeps after a few quiet hours. Agents walk between spots when their state changes.
- Orchestrators wear a red tie and a crown, and their workers sit right next to them. Sub-agents show up as small robots beside their agent.
- Drag to pan and pinch to zoom. Use the bottom-left buttons to zoom or fit the whole campus, and the minimap to jump around. Tap a name plate to list a room's agents, or use **List everyone**.
- Tap the **Needs you / Your turn / Working** chips to fly to the next agent in that state.
- Tap anyone to open their sheet with **Open chat**, the current step, plan, sub-agents and, if one is waiting, the approval.
- Confetti when an agent finishes, smoke when it fails, desk lamps at night.

**Answer Claude from the phone (PC tab → Phone approvals)**
- Turn on **Approve Claude from this phone** to see Claude's permission prompts on the phone: **Allow**, **Deny** or **Deny with a note**.
- Answer Claude's multiple-choice questions (or type your own answer), and approve a plan or send it back with feedback.
- This uses Claude Code's official permission hook. Whichever answers first, the phone or the PC, wins, and the PC dialog closes when you answer on the phone. If the phone isn't reachable, Claude asks on the PC as usual.
- Claude Desktop sessions always show up. Terminal `claude` sessions only show up with **Hold terminal prompts for me** turned on.
- You get a notification if a prompt is still waiting after 10 seconds.
- Codex isn't supported yet: it needs its hook trusted once in Codex's `/hooks` screen.

**Monitor accuracy**
- A finished agent no longer shows "Needs you". Claude Desktop's after-turn summary now shows as **Your turn**, a separate section you can swipe away. "Needs you" is kept for agents that are really blocked on an approval, a question or a plan.
- Workers are linked to the orchestrator that started them, and "Reported to its orchestrator" no longer asks for you.
- Sub-agents are tracked with their own state. A sub-agent waiting on approval flags its parent.
- Running commands are detected more reliably.

Needs the updated PC host: on Linux run `bash scripts/deploy-host.sh`, on Windows install `NexusLink-Host-Setup.exe` from this release. Then restart NexusLink on the PC.

## NexusLink Test 1.0.39+45 — Phone mic

**Phone mic (PC tab)**
- Use your phone as a microphone on the PC. PC apps (AI voice chats, Discord, recorders) see a new input device called **NexusLink Phone Mic**.
- Tap the mic to talk live and tap again to mute, or turn on **Hold to talk** for walkie-talkie style.
- **Make it the PC's default mic** (on by default) switches the PC's default input while the phone mic is on, then switches back to your usual mic when you stop.
- Keeps streaming while you switch to Mirror or other tabs. Turns itself off if the connection drops.
- Needs the updated Linux PC host (`bash scripts/deploy-host.sh`) with PulseAudio or PipeWire. Works while NexusLink is open on the phone.

This release also includes everything from 1.0.38+44 below, which was not published separately.

## 1.0.38+44 — Mission Control

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
