# Code Agent sub-agents and Ultra Code: host → phone contract

Status: implemented on the host (`apps/desktop/src/server/handlers/agents.ts`, types in
`packages/rpc-types/src/index.ts`). Applies to the `claude` provider ("Code Agent") only; no
other provider emits any of this. Measured against `claude` CLI 2.1.319 in `--print
--input-format stream-json --output-format stream-json --verbose` mode (the host's
`claudeSpawnArgs`). Real captures are trimmed into
`apps/desktop/src/server/handlers/__tests__/fixtures/claude-subagents/`.

The phone shows sub-agents as a compact "agents" strip that opens each agent. Main-chat events
and sub-agent events are therefore cleanly separable by one field: `agentId`.

## 1. Event fields

All events still arrive as `{ type: 'agent-event', agentSessionId, event: AgentEvent }` on the
WebSocket, in `agent.history`, and in `agent.historyPage`. Nothing about existing events changes
except the optional `agentId`.

### 1.1 `agentId` on ordinary events

| field | type | meaning |
|---|---|---|
| `agentId` | `string?` | Set on `text`, `thinking`, `tool-start`, `tool-end` and `permission-request` events that belong to a sub-agent. **Absent means the main agent.** The value is the CLI's `task_id` (e.g. `"a28e4ce2f264da5bb"`). |

- Main-agent events never carry the key at all (not `null`, not `""`).
- `user`, `result`, `error`, `status` never carry `agentId`.
- `refId` keeps its meaning on tool events (the tool_use id) and is unique per tool call, so
  tool pairing by `refId` keeps working when sub-agent tools are included or excluded.

### 1.2 New kinds `agent-start`, `agent-update`, `agent-end`

Every `agent-*` event carries the **full current record** of the agent, so the phone can
replace its record wholesale on each one:

| field | type | always? | meaning |
|---|---|---|---|
| `kind` | `'agent-start' \| 'agent-update' \| 'agent-end'` | yes | |
| `agentId` | `string` | yes | the sub-agent (CLI `task_id`) |
| `refId` | `string` | yes* | `tool_use` id of the spawning `Agent` call. That call is a normal `tool-start`/`tool-end` pair with the same `refId` in the **parent's** timeline (main chat for depth 1, the parent agent for depth ≥ 2). |
| `agentName` | `string?` | usually | short description given at spawn ("Run delayed echo command") |
| `agentType` | `string?` | usually | sub-agent type ("general-purpose", "Explore", …) |
| `agentDepth` | `number` | yes | 1 = spawned by the main agent, 2 = spawned by a depth-1 agent, … |
| `agentParentId` | `string?` | when depth ≥ 2 | `agentId` of the spawning sub-agent |
| `agentBackground` | `boolean` | yes | the agent runs in the background (the main turn does not wait for it) |
| `agentStatus` | `'running' \| 'completed' \| 'failed' \| 'stopped'` | yes | `running` on start/update; never `running` on end |
| `text` | `string?` | | update: latest progress line ("Running Sleep 5 seconds then echo marker"); end: final summary (≤ 4000 chars) or the stop reason; start: absent |
| `toolName` | `string?` | update only | last tool the agent used ("Bash", "Agent") |
| `agentPrompt` | `string?` | start only | the task prompt given to the agent (≤ 4000 chars) |

\* `refId` is only missing if the CLI never named the spawning call, which was not observed.

`agentStatus` values (type `AgentSubagentStatus` in rpc-types):

- `completed`: the agent's `task_notification` said completed.
- `failed`: its status contained "fail"/"error".
- `stopped`: killed/stopped/cancelled by the CLI, **or** the host ended it: the user pressed
  Stop (`text: "Stopped."`), the CLI process ended (`text: "The agent process ended."`), or the
  host restarted (`text: "Interrupted — host restarted."`).

### 1.3 Session info

`AgentSessionInfo.runningAgents?: number` — sub-agents of this session running now (all depths).
Only claude sessions set it. It is sent in `agent-session-update` together with every
`agent-start` and `agent-end`, and it can be `> 0` while `busy` is `false` (background agents
after the turn's result). Missing means 0.

### 1.4 Ultra Code advertisement

`AgentModelOption.thinkingLevels?: string[]` — per-model thinking levels. For Code Agent models
that support effort (`default`, `sonnet` today) it is `['low','medium','high','ultracode']`; for
models without effort (`opus`, `haiku` per `isModelEffortSupported`) it is absent. The agent-wide
`capabilities.thinkingLevels` stays `['low','medium','high']`. See section 6 for why.

## 2. Lifecycle and ordering guarantees

Per session, events have increasing `seq` and arrive in `seq` order (as before). On top of that:

1. **Start first.** For every `agentId`, an `agent-start` comes before any other event carrying
   that `agentId`. (If the CLI ever sends a sub-agent message before its `task_started`, the host
   synthesizes the `agent-start` from the message, and the later `task_started` becomes an
   `agent-update` with the details.)
2. **One end per start.** Each `agent-start` is followed by exactly one `agent-end` for that
   `agentId`. In between there are zero or more `agent-update`s.
3. **Running means running.** An agent is running from `agent-start` until its `agent-end`. The
   spawning call's `tool-end` does **not** mark it finished:
   - foreground agent: `agent-end` comes *before* the spawning `tool-end`;
   - background agent: the spawning `tool-end` comes right away ("Async agent launched …") and the
     `agent-end` comes much later, possibly after the turn's `result`.
4. **Stop ends everything.** Stop (`agent.cancel`), CLI process exit, and host restart end every
   still-running agent with `agent-end` / `stopped`, deepest agents first, before the
   `status: cancelled` (cancel) or the turn's `error` (crash while busy).
5. **Nested.** A depth-2 agent's `agent-start` comes after its parent's `agent-start`, and its
   `agent-end` before its parent's `agent-end`.
6. **Restarted agents.** The same `agentId` can start again after its `agent-end` (an agent
   continued through `SendMessage`). Treat a new `agent-start` for a known `agentId` as "running
   again" and replace the record. Not observed in captures; handled defensively.
7. **Late events are dropped.** `task_progress` after an agent's end is ignored. A `text`/tool
   event carrying the `agentId` of an ended agent is still delivered (attach it to that agent).

What the stream does **not** contain (measured, CLI 2.1.319):

- A depth-1 agent's own tool calls and some of its text **are** streamed (`tool-start@id`,
  `tool-end@id`, `text@id`). Its final answer is often only in `agent-end.text`; in the
  foreground capture no `text@id` came at all.
- A depth ≥ 2 agent's own messages are **not** streamed: only its `agent-start`/`agent-update`/
  `agent-end` and its permission requests. Its tools show up as `agent-update.toolName`.
- No token-by-token text for sub-agents (no `text-delta`).

So the per-agent view must work from `agent-*` records alone and show `text@id`/tool events as a
bonus.

## 3. Busy state, turns, second rounds, notifications

- `busy` still means "the phone's turn is in progress": `true` from the phone's prompt until the
  next `result` or `error`. **Any `result` ends it.**
- With a background agent the CLI does this: main turn → `result` (agent still running) →
  agent finishes (`agent-end`) → the CLI starts a round **by itself** (`status: ready`, main
  `text`, `result`). That round is **never busy**: the phone may send a new message at any time
  after the first `result`, including while background agents run and while that round streams.
  Its events are ordinary main-agent events with the `turnId` of the last phone turn. Expect a
  second `result` for the same `turnId`.
- While `runningAgents > 0` and `busy == false`, show "N agents running" (strip / session row)
  but keep the composer enabled and do not show the "Working…" spinner of the main turn.
- `taskState` is unchanged in meaning: `completed` after a `result` even when agents still run.
  Use `runningAgents` for "still working in the background".
- Host push notifications (phone closed): a `result` while `runningAgents > 0` sends **no**
  push; the final round's `result` (after the last agent ended) sends the usual "Agent Done".
  The host does not dedupe the activity feed: `activity_v2` records a `completed` item for each
  `result` (first and second round).
- The duplicate-result rule (`result.text` is emptied when main-agent text was streamed in that
  round) now resets per round and ignores sub-agent text, so a round's answer is shown once.
- Changing model, mode or effort normally restarts the CLI process. **While sub-agents run, the
  host keeps the process** (restarting would kill them) and emits
  `status: "Sub-agents are still running, so this message keeps the current model, mode and
  effort. The new choice applies once they finish."` The new settings apply to the first
  message sent after all agents ended.

## 4. Permission requests from sub-agents

`permission-request` gets `agentId` when the CLI's `control_request` names a known agent
(`request.agent_id`; observed for a depth-2 agent). Answering is unchanged
(`agent.permission` with `refId`). The phone must keep such requests answerable from the main
chat/banner (label them with the agent's name); do not hide them inside the agent view only.

## 5. Persistence and replay

- Events are stored as JSON bodies, so `agentId` and every `agent*` field survive
  `agent.historyPage` and `agent.history` replays unchanged (tested through the SQLite store).
- Host restart: no CLI process survives, so on load the host appends, for every agent without an
  end, an `agent-end` with `agentStatus: 'stopped'`, `text: 'Interrupted — host restarted.'`,
  after the usual closing `tool-end`s for open tools, and **stores them**, so a reconnecting
  phone never sees an agent running forever. `runningAgents` is reset to 0.
- `agent.history` no longer closes open tool cards of a session whose `runningAgents > 0`
  (background agents legitimately keep tools open after the result).
- Rebuilding state from history: the latest `agent-*` event per `agentId` is the record; the
  agent is running if that event is `agent-start` or `agent-update`.

## 6. Ultra Code

- Value: thinking `"ultracode"` (send it as the existing `thinking` prompt option).
- Host: for `claude`, models that support effort get `--effort ultracode`; it is part of the
  process spawn key, so switching to/from it restarts the CLI with `--resume` (except while
  sub-agents run, section 3). Models without effort get no `--effort` flag (as for other
  levels).
- Other providers never receive it: the host maps `ultracode` to that agent's highest advertised
  level (Cursor/OpenCode `max`, Antigravity/Codex `high`, Demo `extra-high`); direct builder
  calls also treat it as `high`.
- Advertised per model (`AgentModelOption.thinkingLevels`), not in
  `capabilities.thinkingLevels`, because released phones label every unknown level "Medium"
  (`_thinkingLabel` falls through), so an agent-wide entry would show them a second "Medium"
  that silently runs Ultra Code. New phones: use `model.thinkingLevels ?? caps.thinkingLevels`
  for the selected model, label `ultracode` "Ultra Code".
- **What it does in `--print` mode (measured):** `claude -p --effort ultracode` and
  `claude -p --effort xhigh` sent byte-identical API requests (same request-shape hash, same
  system prompt, same tool list, same message attachments, `effort: "xhigh"`); a stream-json
  run with `--effort ultracode` showed no extra tools or events. So headless, Ultra Code
  **only raises effort to xhigh**; no workflow orchestration was observable. It may do more in a
  later CLI; the host passes the value through unchanged so that would apply automatically.
- Existing levels for claude are unchanged and still collapse: `thinkingToEffort` maps `xhigh`,
  `max` and `extra-high` to `high` (Code Agent advertises only low/medium/high, so this only
  matters if a phone sends those values).

## 7. Old clients

- **Released Flutter phones** (`AgentEvent.fromJson` keeps known fields, unknown `kind` →
  `SizedBox.shrink()`): no crash; `agent-*` events are invisible. Sub-agent `text`/`tool-*`
  events show in the main chat as before — the old host already emitted a sub-agent's streamed
  messages as main-chat events, so this is not worse. Visible differences on old phones:
  - a background flow raises two local "finished" notifications (one per `result`);
  - when the chat is opened while a background agent runs, its open tool cards are locally
    marked "Interrupted — host restarted." (`settleOpenTools` when `busy` is false); the real
    `tool-end` arrives later.
  - no Ultra Code choice (per-model field is ignored).
- **Web client** (`apps/mobile-client/src/app/agents/page.tsx`): unknown kinds render `null`;
  sub-agent events show inline as before.

What the new phone should do (guards for the next worker):

1. Main timeline = events without `agentId` (plus `agent-*` only as strip input, never as bubbles).
2. Do not run `settleOpenTools`/"host restarted" closing while `runningAgents > 0`, and never on
   events that carry `agentId` (the host closes them itself on stop/exit/restart).
3. Do not raise the local "finished" notification for a `result` while `runningAgents > 0`.
4. Keep `permission-request` with `agentId` in the main approval flow.
5. Keep the composer enabled when `busy == false`, whatever `runningAgents` says.

## 8. Real sequences (trimmed; `seq`/`ts`/`turnId` omitted)

### 8.1 Background agent, live run through the real ClaudeAdapter (haiku, 2026-11-11)

```json
{"kind":"user","text":"Use the Agent tool exactly once with run_in_background set to true ..."}
{"kind":"status","text":"ready"}
{"kind":"thinking","text":""}
{"kind":"tool-start","toolName":"Agent","refId":"toolu_012416RzUmsDV49c6yR436sj","toolInput":"{ \"description\": \"Run delayed echo command\", ..."}
{"kind":"agent-start","agentId":"a3a31c1d935e8cfce","refId":"toolu_012416RzUmsDV49c6yR436sj","agentName":"Run delayed echo command","agentType":"general-purpose","agentDepth":1,"agentBackground":true,"agentStatus":"running","agentPrompt":"Run the shell command: sleep 5 && echo e2e-done ..."}
{"kind":"tool-end","refId":"toolu_012416RzUmsDV49c6yR436sj","toolOutput":"Async agent launched successfully. ..."}
{"kind":"thinking","text":""}
{"kind":"text","text":"launched"}
{"kind":"tool-start","toolName":"Bash","refId":"toolu_01Qfp5qnPmHA4A7Qw5c7mu7H","agentId":"a3a31c1d935e8cfce","toolInput":"{ \"command\": \"sleep 5 && echo e2e-done\", ..."}
{"kind":"agent-update","agentId":"a3a31c1d935e8cfce","refId":"toolu_012416RzUmsDV49c6yR436sj","agentName":"Run delayed echo command","agentType":"general-purpose","agentDepth":1,"agentBackground":true,"agentStatus":"running","text":"Running Sleep 5 seconds then echo marker","toolName":"Bash"}
{"kind":"result","text":""}
                                  -- busy=false, runningAgents=1: the phone may send now
{"kind":"tool-end","refId":"toolu_01Qfp5qnPmHA4A7Qw5c7mu7H","agentId":"a3a31c1d935e8cfce","toolOutput":"e2e-done"}
{"kind":"text","text":"finished","agentId":"a3a31c1d935e8cfce"}
{"kind":"agent-end","agentId":"a3a31c1d935e8cfce","refId":"toolu_012416RzUmsDV49c6yR436sj","agentName":"Run delayed echo command","agentType":"general-purpose","agentDepth":1,"agentBackground":true,"agentStatus":"completed","text":"finished"}
                                  -- runningAgents=0; the CLI starts a round by itself
{"kind":"status","text":"ready"}
{"kind":"text","text":"The background agent finished; it ran `sleep 5 && echo e2e-done` ..."}
{"kind":"result","text":""}
```

### 8.2 Foreground agent (fixture `foreground.jsonl`, through the adapter)

```json
{"kind":"user","text":"spawn one agent"}
{"kind":"status","text":"ready"}
{"kind":"tool-start","toolName":"Agent","refId":"toolu_017FWpGsGfNFM2DJV8N95h3S","toolInput":"..."}
{"kind":"agent-start","agentId":"a981023569ae6ebcf","refId":"toolu_017FWpGsGfNFM2DJV8N95h3S","agentName":"Reply with pong","agentType":"general-purpose","agentDepth":1,"agentBackground":false,"agentStatus":"running","agentPrompt":"Reply with exactly the word pong. Do not use any tools."}
{"kind":"agent-end","agentId":"a981023569ae6ebcf","refId":"toolu_017FWpGsGfNFM2DJV8N95h3S","agentName":"Reply with pong","agentType":"general-purpose","agentDepth":1,"agentBackground":false,"agentStatus":"completed","text":"pong"}
{"kind":"tool-end","refId":"toolu_017FWpGsGfNFM2DJV8N95h3S","toolOutput":"[Subagent hand-back] ... pong ..."}
{"kind":"text","text":"Subagent replied \"pong\", so it said: \"pong\"."}
{"kind":"result","text":""}
```

### 8.3 Nested agents with a depth-2 permission request (fixture `nested-permission.jsonl`)

Abbreviated: `"...":"…"` marks record fields left out that are identical to the agent's
`agent-start`; the real events always carry the full record.

```json
{"kind":"tool-start","toolName":"Agent","refId":"toolu_01X9nYFTft2MJ5vTd6A7Rn4Z"}
{"kind":"agent-start","agentId":"a5e3038f0d177146a","refId":"toolu_01X9nYFTft2MJ5vTd6A7Rn4Z","agentName":"Nested sub-agent test","agentType":"general-purpose","agentDepth":1,"agentBackground":false,"agentStatus":"running","agentPrompt":"Use the Agent tool yourself once ..."}
{"kind":"agent-update","agentId":"a5e3038f0d177146a","refId":"toolu_01X9nYFTft2MJ5vTd6A7Rn4Z","agentDepth":1,"agentBackground":false,"agentStatus":"running","text":"Run python one-liner","toolName":"Agent", "...":"name/type as above"}
{"kind":"tool-start","toolName":"Agent","refId":"toolu_013MBeHPxxAyXR2uRGHSdHT5","agentId":"a5e3038f0d177146a"}
{"kind":"agent-start","agentId":"a9462576fd733b1e6","refId":"toolu_013MBeHPxxAyXR2uRGHSdHT5","agentName":"Run python one-liner","agentType":"general-purpose","agentDepth":2,"agentParentId":"a5e3038f0d177146a","agentBackground":false,"agentStatus":"running","agentPrompt":"Run the shell command  python3 -c \"print(6*7)\" ..."}
{"kind":"agent-update","agentId":"a9462576fd733b1e6","refId":"toolu_013MBeHPxxAyXR2uRGHSdHT5","agentDepth":2,"agentParentId":"a5e3038f0d177146a","agentStatus":"running","text":"Running Run python command printing 6*7","toolName":"Bash", "...":"name/type/background as above"}
{"kind":"permission-request","refId":"237436a0-0e7c-46c9-abec-6aedd49d8fe5","toolName":"Bash","agentId":"a9462576fd733b1e6","text":"…only when the host's safety check asks the phone…"}
{"kind":"agent-end","agentId":"a9462576fd733b1e6","refId":"toolu_013MBeHPxxAyXR2uRGHSdHT5","agentDepth":2,"agentParentId":"a5e3038f0d177146a","agentStatus":"completed","text":"42", "...":"name/type/background as above"}
{"kind":"tool-end","refId":"toolu_013MBeHPxxAyXR2uRGHSdHT5","agentId":"a5e3038f0d177146a","toolOutput":"..."}
{"kind":"agent-end","agentId":"a5e3038f0d177146a","refId":"toolu_01X9nYFTft2MJ5vTd6A7Rn4Z","agentDepth":1,"agentStatus":"completed","text":"42", "...":"name/type/background as above"}
{"kind":"tool-end","refId":"toolu_01X9nYFTft2MJ5vTd6A7Rn4Z","toolOutput":"..."}
{"kind":"text","text":"The nested sub-agent returned 42, which is the output of ..."}
```

## 9. CLI stream → event mapping (reference)

| CLI stream-json line | host event |
|---|---|
| `system/task_started` with `task_type` containing "agent" (`local_agent`) | `agent-start` (`task_id`→`agentId`, `tool_use_id`→`refId`, `description`→`agentName`, `subagent_type`→`agentType`, `spawn_depth`→`agentDepth`, `parent_task_id`→`agentParentId`, `is_backgrounded`→`agentBackground`, `prompt`→`agentPrompt`) |
| `system/task_started` with `task_type: local_bash` (background shell) | ignored: not an agent |
| `system/task_progress` | `agent-update` (`description`→`text`, `last_tool_name`→`toolName`) |
| `system/task_updated` | `agent-update` only when `patch.is_backgrounded` or `patch.description` changes; `patch.status` is ignored |
| `system/task_notification` | `agent-end` (`status`→`agentStatus`, `summary`→`text`) |
| `assistant`/`user` with `parent_tool_use_id` (and `agent_id`) | `text`/`thinking`/`tool-start`/`tool-end` with `agentId`; a sub-agent's text-only `user` message (its prompt) is dropped |
| `control_request` `can_use_tool` with `request.agent_id` | `permission-request` with `agentId` |
| `system/background_tasks_changed`, `task_summary`, `post_turn_summary`, `thinking_tokens` | ignored |
| `result` with `origin.kind: "task-notification"` | an ordinary `result` (second round) |
