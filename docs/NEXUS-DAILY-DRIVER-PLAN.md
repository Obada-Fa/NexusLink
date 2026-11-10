# Nexus as a daily remote worker: findings, decisions and plan

Written 2026-11-10 as a handoff. It records a critical review of the app, an investigation into starting Claude sessions from the phone, the first feature that shipped from it, and the ordered plan for what comes next. A new session can continue from this file alone.

## How the owner works

- Mostly from the phone, always on mobile data. Sometimes from a laptop on fast company Wi-Fi. A tablet or iPad is wanted later.
- About 90 % of the time is steering coding agents.
- The desktop stream was used mainly as a workaround: start a chat in the Claude desktop app (new project folder, or an Ultra Code run), then follow it in the Claude phone app.
- PC: Linux on X11 (chosen over Wayland for Input Leap and missing features), Radeon RX 9070 XT.

## Review verdict (2026-11-10)

Not ready for the public; ready for a closed alpha with technical Linux users. The review was of code, docs and rendered captures, not of a phone against a live PC.

Why the app feels like streaming and not like a phone OS:

- Ordinary apps launch on the PC's real desktop and are resized into portrait; the phone polls the window list every 800 ms for up to 25 s (`mirror_screen.dart`). Only `nexus.*` profile apps get their own phone-shaped virtual display (`app_actions.dart` `launchApp`, host `app-sessions.ts`).
- Default video is MJPEG at "medium", 24 fps (`capture.ts`). WebRTC is a best-effort upgrade for virtual sessions only (`mirror_fit.dart`, `webrtc.ts`).
- Streamed content is desktop UI with mouse-sized targets, injected through `xdotool`.
- No PC-notification mirroring, recents / app switcher, global search, home-screen widget or quick-settings tile.
- Home tiles are named after mechanisms (Remote, Audio, Desktop), not after what the user wants.

Blockers for a public release:

- No physical-phone walkthrough of recent builds (see the progress log in `NEXUS-REFINE-PLAN.md`).
- Setup needs Bun, a CLI pairing command, Tailscale, and a Remote companion installed from source.
- Linux X11 only.
- Release signing identity unresolved (`KNOWN-LIMITS.md`, `ANDROID-RELEASE.md`).
- Cleartext traffic enabled (plain `ws://` in LAN mode), overlay / boot / mic permissions, no privacy policy.
- `README.md` still says the app opens to Agents and that streaming is experimental.
- Terms: see the section below. It affects the Agents module in any public build.

## Investigation: starting Claude sessions from the phone

Done by a read-only worker with one tiny live CLI run. Each item says how sure it is.

1. **One transcript store, separate lists.** The CLI and the Claude desktop app both write `~/.claude/projects/<folder>/<sessionId>.jsonl`. The desktop app keeps its own index (`~/.config/Claude/claude-code-sessions/…/local_<uuid>.json`, each with a `cliSessionId`). A session Nexus starts is not in that index. *Verified from files; "will not appear in the desktop list" is inferred.*
2. **Same engine.** The desktop app launches the same `claude` binary with nearly the same options Nexus uses (`--output-format stream-json --input-format stream-json --permission-prompt-tool=stdio --resume=<id> …`); compare `claudeSpawnArgs` in `apps/desktop/src/server/handlers/agents.ts`. *Verified from a running process's command line.*
3. **Remote Control is the bridge to Anthropic's apps.** `claude remote-control --name <name>` in a folder registers the session so it shows in the Claude phone app, claude.ai/code and the desktop app's Code tab. It needs a claude.ai subscription login (API keys are not supported), asks "Enable Remote Control?" once per PC and "Trust this folder?" per folder, and fails without a terminal. A session is either driven by Nexus (`--print`) or shown in Anthropic's apps (Remote Control), not both from one process. *Help and docs verified; the owner confirmed with a screenshot that a Remote Control session appears in the desktop app; a live start reached "Connected".*
4. **Reverse direction.** Nexus can already list desktop-started sessions (`host-chats.ts` → `packages/chat-core/src/providers/local`) and could resume them with `--resume <id>`. Two processes on one session id both append to the same file. `--fork-session` exists for a safe copy. *Store verified; conflict behaviour inferred.*
5. **Ultra Code** is the `ultracode` session setting: `claude --effort ultracode` or `/effort ultracode`. It turns on workflow orchestration and sets effort to `xhigh`. Effort values are `low, medium, high, xhigh, max`. The owner ran `claude -p --effort ultracode "say hi"` without error, which shows the flag is accepted headless, not that orchestration ran.
6. **Multiple agents in the CLI stream.** Sub-agents appear as `system` events (`task_started`, `task_updated`, `task_notification`, `background_tasks_changed`) and as `parent_tool_use_id` on messages; identity is `task_id`, linked to the spawning call by `tool_use_id`, depth by `spawn_depth`. After the first `result` the stream can emit a second round when a background agent finishes. The Nexus adapter (`agents.ts` `onEvent`) handles none of this: a sub-agent run is one `Agent` tool card, marked done while the agent still works, with its text dropped. The monitor and Arena views do show sub-agents, derived from files (`chat-core/src/providers/live.ts`, `lib/src/chats/chat_models.dart` `ChatSubagent`). *Verified with a live run.*
7. **New folders.** The phone's folder picker creates folders through host `fs.mkdir` (`cwd_picker.dart` `_createNewFolder`). *Verified.*

### What Anthropic's terms say (a report of the documents, not legal advice)

- Claude Code legal page: subscription sign-in is for the unmodified Claude Code binary; third-party developers may not offer claude.ai login in their own apps or handle those credentials; products built on the Agent SDK should use API-key authentication.
- Consumer Terms §3 restricts access "through automated or non-human means" except where explicitly permitted.
- **Owner's personal use:** not addressed directly. Nexus runs the unmodified binary under the owner's own login on the owner's own PC, which is in its favour; the automated-access wording cuts the other way.
- **Public distribution:** an app that drives users' Claude subscriptions through itself is on the wrong side of the docs as written, unless approved. A public build would need API-key authentication for its own chat, or to rely on Remote Control, which is part of the official CLI.

Sources: `code.claude.com/docs/en/legal-and-compliance`, `code.claude.com/docs/en/agent-sdk/overview`, `code.claude.com/docs/en/remote-control`, `anthropic.com/legal/consumer-terms`, `anthropic.com/legal/aup`.

## Shipped: Start on PC (test build 1.0.50+56)

Commit `926bcf8`, released as `test-v1.0.50+56`. Code in `apps/flutter_client/lib/src/claude_app/`.

- **Agents → New chat** asks, after the folder picker: **Chat here in Nexus** or **Start for Claude app**.
- The second creates an ordinary Nexus shell in that folder and types `exec claude remote-control --name='<name>'`. The name is single-quoted, stripped of control characters and capped at 80 characters; the folder goes only into the shell's working directory.
- The shell is shown under a banner with **Running / Ended**, **Open Claude** (launches `com.anthropic.claude`) and **Stop**.
- Sessions are listed under **Agents → Live** and reconciled against the host's shell list. Records live on the phone under `claude-app-sessions:<hostId>`. No host change.

Verified: analysis clean; 534 tests passed, 4 skipped; hostile names against real bash and the host's PTY path; a real Remote Control session through the host's terminal handlers reached "Connected" and stopped cleanly; the release APK built in CI.

Not verified, needs the owner's phone:

1. **Open Claude** launching the Claude app.
2. Sending a message to the session from the Claude app.
3. Which name the session shows under (the CLI printed the folder name, not the typed name).
4. The full WebSocket path for `terminal.create` / `terminal.input` against the deployed host.

Known limits: the session ends when the host restarts; no "Copy link" action; POSIX shells only (fish is untested); disabled for Windows PCs.

## Plan, in order

One feature at a time. Each is discussed and agreed with the owner before a worker starts.

1. **Close out Start on PC.** Get the four phone checks above. Likely follow-ups: fix the name if it shows the folder, add "Copy link", and decide whether the session should survive a host restart (run it outside the host's shell lifetime).
2. **Nexus chat parity, for the owner's own use.** Add Ultra Code as a choice next to effort (`--effort ultracode`), and show sub-agents in the chat: handle `task_*` events and `parent_tool_use_id`, keep an agent "running" until its `task_notification`, and keep reading after the first `result`. Open question to settle first: a per-agent timeline in the chat, or a compact "agents" strip that opens each one.
3. **Continue a desktop-app session from Nexus.** List is already possible; the design question is how to avoid two processes on one session (`--fork-session`, or only when the desktop process is not running).
4. **H.264 as the default video.** For every stream, hardware-encoded through VA-API on the RX 9070 XT, MJPEG as fallback. The phone is always on mobile data, so this is the biggest gain for the remaining streaming use. Measure bitrate, frame rate and tap-to-picture delay before and after. Benefits the web client too.
5. **PC notifications on the phone.** Mirror desktop notifications into Android notifications.
6. **Recents and instant launch.** A switcher with live thumbnails of running sessions; keep sessions warm; show the last frame while connecting.
7. **Virtual sessions: decide the rule.** A virtual session starts a fresh instance; resuming what is already open on the PC needs the real window. Do not switch everything to virtual sessions without settling this.
8. **Tablet layout**, then an iOS / iPad build as its own project.
9. **Public-release track**, separate from the above: signing identity, one-step host install, Wayland, API-key authentication for a public Agents module, removing cleartext, privacy policy, rewriting the README, and a full physical-phone acceptance run (`ANDROID-ACCEPTANCE.md`).

## How the work is run

The owner's orchestrator rules (in the user-level instructions on the Linux machine) apply; they are restated here because that file is not on `/mnt/shared`:

- Plan with the owner first; push back and recommend. No code until the plan is agreed. The owner does not want to be asked to run checks an agent can do itself.
- The orchestrator writes no code. It starts one visible worker session per independent piece, with an explicit list of owned files, "don't commit", verification steps, and a final `REPORT.md`.
- Review lean: read the report, run the suite once, look at the one or two captures that matter, skim only the risky diff. Commit locally after review. Push only when the owner says so, each time.
- No AI attribution in commits, PRs or releases.
- Workers never use the owner's real display or data directories, kill only their own processes by PID, and leave nothing running.

### Continuing from Windows

- The checkout is the same one on the shared drive, so local commits are visible. Branch `nexus-app-phase1`; everything up to the 1.0.50+56 release is pushed.
- Flutter analysis and widget tests can run on Windows. The Linux-only parts cannot: the host's terminal, capture, virtual-session and Remote Control checks, and anything needing Xvfb. Features 2 to 6 all have host or live-CLI verification steps, so plan those checks for the Linux machine or state them as unverified.
- The APK is built by CI on a `test-v<version>` tag (`.github/workflows/android-apk-release.yml`); bump `apps/flutter_client/pubspec.yaml` and add an entry to `release-notes.md` first.
- The project notes file `CLAUDE.md` at the repo root is untracked but lives on the shared drive; its "Current state" section points here.
