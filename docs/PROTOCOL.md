# Linux host protocol, version 2

The Android client uses WebSocket JSON RPC at `/rpc`; large transfers use HTTP at `/files` on the same host and port. Every request has `{type:"rpc-request",request:{id,method,params}}`; replies have `{type:"rpc-response",response:{id,result}}` or `{id,error,code}`. Stable error codes include `UNAUTHENTICATED`, `UNSUPPORTED`, `INVALID_ARGUMENT`, `NOT_FOUND`, `REVISION_CONFLICT`, `PERMISSION_DENIED`, `SESSION_EXITED`, and `LIMIT_REACHED`. `packages/rpc-types/src/workspace.ts` contains the additive version-two types. The host publishes its concrete `methods` and `features` through `session.getCapabilities`; clients must test these before using a feature.

## Pairing and identity

Call `session.hello` to determine `protocolVersion`. On Linux v2, call `session.enroll` with the short-lived eight-digit code displayed by `bun run host:pair`, or call `session.resume` with the previously paired device credential. Enrollment returns the credential once. Resume returns a one-hour control or monitor session token and the persistent `hostId`. Credentials belong in Android Keystore or a protected client store, never URLs or logs. Host SQLite keeps credential hashes; `bun run host:revoke <device-id>` invalidates control and file tokens. A monitor role can subscribe to task summaries and activity only.

The host gives no implicit privileges to a WebSocket session ID or a LAN address. `session.heartbeat` validates the current session. Subscribe explicitly with `session.subscribe`: `agents`, `metrics` (2 or 5 second interval), or `windows`. The Android app does not subscribe to `windows` outside the experimental viewer. Ordinary phone clients use one control socket. Optional Android live activity opens a second monitor socket with a smaller task-only surface.

## Terminal

`terminal.create` starts a real PTY, buffers its output, and returns an ID. The client registers output listeners before `terminal.attach({terminalId,afterSeq})`. The attach reply includes sequence and gap information, and the host replays buffered chunks. `terminal.detach` removes a socket's view; `terminal.kill` intentionally ends the shell. `terminal.list`, `terminal.input`, and `terminal.resize` cover existing sessions. Output events have `seq`; `terminal-gap` and `terminal-exit` are explicit. Android deduplicates replay by sequence and disables input until attach completes. The host keeps up to 12 live PTYs, about 2 MiB replay per PTY, and marks a truncated replay gap. Host restart ends shells and never reruns commands.

## Agents

`agent.listSessions` returns summaries; `agent.historyPage` loads the newest 100 events, older events with `beforeSeq`, or missing events with `afterSeq`. `agent.pendingApprovals` returns still actionable requests by ID. `agent.archive` affects visibility but retains history. `activity.snapshot({cursor})` returns task summaries and a bounded stream of attention events for the Android monitor. Each durable event has a task ID and sequence; `turnId` identifies the turn. The host commits events to SQLite before broadcasting them. Client operation IDs protect task creation and prompt submission from duplicate execution during a timeout. They are retained in memory during the current host run, not across a host restart.

## Files and transfer

`fs.listPage` returns host-sorted pages of up to 200 entries. `fs.readText` returns canonical path, content/preview, BOM, line endings, revision hash, editability, and metadata. `fs.writeText` requires an `expectedRevision` and operation ID, rejects observed external changes, writes a sibling temporary file, then replaces the original atomically. Symlink and hard-link writes are refused. `fs.gitChanges` and `fs.gitDiff` are read-only Git inspection.

`transfer.authorize({path})` returns a file-scoped download token. Pass it in an `Authorization: Bearer` header to `/files?path=...`. GET and HEAD include ETag, length, range support and content disposition. A ranged resume requires a matching `If-Range` or `If-Match` validator; a changed file returns 412 so the client must restart instead of concatenating versions. Android DownloadManager handles the public Downloads destination and background work. POST uploads stream to a sibling temporary file, default to no overwrite, and commit on completion. An explicit `overwrite=1` follows a user decision.

The new Linux host requires v2 pairing. The Windows host still uses its existing protocol; the PWA retains the legacy handshake for a host that does not advertise v2. Android hides unsupported v2 actions when a host lacks capabilities.
