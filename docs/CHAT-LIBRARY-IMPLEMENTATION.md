# PC chat library implementation

Implemented from the attached plan on 2026-10-04. The code and automated checks are complete for the implemented capabilities. Release acceptance remains pending on physical Android, Windows, and Linux devices.

## Delivered behavior

Flutter opens the workspace on **Chats → Recent**. It provides compact dated rows, Folders and folder detail, provider/archive filters, debounced search, paginated results, source recovery messages, New chat, and folder file navigation. Quiet updates retain the visible page count; stale search and replaced-PC responses are discarded. Existing transcript, attachments, voice, composer settings, and current managed approvals are reused.

`packages/chat-core` is shared by both hosts. A dedicated worker owns the SQLite library, history index, aliases, source health, and durable delivery records. Discovery and transcript parsing run in separate workers, with two concurrent scans, timeouts, source isolation, watchers, and 30-second reconciliation while subscribed. Imported files are read only. Discovery retains saved rows when a provider fails or a legacy parser cannot prove a complete scan.

Windows persists its host identity and agent store in `%APPDATA%\NexusLink` (or `NEXUSLINK_DATA_DIR`). Linux uses its existing workspace store. Both advertise `chat.library.v1` after initialization; Windows retains its pairing flow. New RPC methods require authenticated control access, with Linux monitor restrictions covered by an actual dispatcher test. Existing browser RPC names and result shapes are retained.

The Android SQLite cache is scoped to authenticated host identities. It retains up to 500 summaries and 20 transcripts per PC, limits each transcript to 2 MiB and all transcripts to 40 MiB, and keeps drafts and reading positions independent of eviction. Backup rules exclude the cache. Clear saved chats retains drafts; Forget this PC and confirmed credential revocation remove that PC's saved content and drafts.

Reply operations are persisted before dispatch. Repeated operation IDs dispatch once; a crash after dispatch reports Delivery uncertain. The phone saves drafts and unresolved operation IDs and never automatically resends. Busy, imported unknown-state, missing-folder, and host-interrupted chats cannot be continued through this API.

## Provider capabilities

| Provider | Discovery and history | Continuation |
| --- | --- | --- |
| NexusLink managed sessions | Durable gateway history, stable event IDs and cursor pages | Available when the original managed session is ready and its folder exists |
| Codex | Official app-server handshake, complete paginated active/archive discovery and typed history; local read-only fallback | Managed sessions use `thread/resume` and `turn/start` with the recorded native ID; imported `notLoaded` threads remain read only because it does not prove original-run safety |
| Claude Code | Local saved transcripts, bounded metadata discovery and worker-parsed history | Existing managed sessions; imported execution state is unknown |
| Cursor | CLI and IDE local discovery/history, recorded folder metadata | Existing managed CLI sessions; imported and IDE chats remain read only |
| OpenCode | Complete CLI JSON session listing and export in workers; missing installation retains indexed rows | Existing managed sessions; imported execution state is unknown |
| Antigravity | Existing CLI/IDE database and transcript readers moved into the shared package | Existing managed sessions; imported execution state is unknown |

An installed provider or readable transcript alone does not prove that an imported conversation is idle. Unsupported continuation displays a reason and offers New chat. No imported native rename, archive, cancel, or delete controls are exposed.

Codex integration follows the [official app-server documentation](https://learn.chatgpt.com/docs/app-server). OpenCode listing/export follows the [official CLI documentation](https://dev.opencode.ai/docs/cli/). Provider formats and installed versions still require independent device acceptance.

## Verification

Latest host regression run: **74 passed, 1 skipped, 0 failed** across the shared library, Codex protocol, gateway, legacy parsers, Windows token persistence, and authenticated Linux dispatcher tests. The skipped PTY test requires an unavailable shell dependency.

Latest complete Flutter run: **159 passed, 1 skipped, 0 failed**. The skipped test requires a live host. New coverage includes initial Recent navigation, recorded Windows folders, stale search rejection, 320 dp layout with 1.8× text scaling, host cache isolation, eviction bounds, revision replacement, append-only history merging, and draft retention.

Strict TypeScript analysis passes for the shared library, provider workers, Codex protocol test, and agent gateway. Dart reports no compilation errors; the existing conversation screen retains unused-method warnings, async-context advice, and a speech API deprecation. Whole-host TypeScript checking also has outstanding platform type issues outside the new shared package; this is not recorded as a clean release build.

The 10,000-row fixture ran 25 indexed list queries and measured **0.15 ms p95** on this Windows development environment. This excludes discovery, IPC, phone rendering, and network time. The 300 ms phone cache-render target, watcher latency, and streaming under discovery load are pending device measurements.

Reproduce host checks from the repository root:

```powershell
bun test packages/chat-core/src apps/desktop/src/server/handlers/__tests__/agents.test.ts apps/desktop/src/server/handlers/__tests__/host-chats.test.ts apps/windows-host/src/server/handlers/__tests__/persist.test.ts apps/desktop/src/server/workspace/server.test.ts
```

Reproduce mobile checks from `apps/flutter_client` with an installed Flutter SDK:

```powershell
flutter pub get
flutter test --no-pub
flutter analyze
```

## Pending release acceptance

This PC has no Android SDK at the standard local installation path; the ignored Android `local.properties` still references a Linux SDK directory. No APK or physical-device result is claimed. The existing release signing requirements in [ANDROID-RELEASE.md](ANDROID-RELEASE.md) still apply.

Before release, complete [ANDROID-ACCEPTANCE.md](ANDROID-ACCEPTANCE.md) against both hosts and record each installed provider's discovery, history, and continuation separately. Verify PC-originated updates, native-ID continuity for supported managed replies, busy/unknown refusal, sleeping/waking the PC, network changes, background drafts and reading position, credential revocation, host restart, and cached launch latency. The plan's release gate remains open until those checks pass.
