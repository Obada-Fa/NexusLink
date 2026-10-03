# NexusLink

NexusLink is a mobile workspace for coding on a Linux PC over Tailscale. The Flutter Android app opens to **Agents**, with **Files**, **Terminal**, and **PC** alongside it. Desktop streaming is optional under **PC → Experimental**.

This checkout is under active implementation. A debug Android APK, host TypeScript checks, and automated tests have passed locally. The Android experience, background transfers, live activity, all real agent providers, and release signing still require the device and release checks in [the acceptance checklist](docs/ANDROID-ACCEPTANCE.md). No current release is claimed production ready.

## Run the Linux host

Install [Bun 1.3.14](https://bun.sh) and Python 3 with PTY support, connect the PC and phone to the same Tailscale network, then run:

```bash
bun install --frozen-lockfile
bun run host
```

`bun run host` starts **only** the coding host. It does not build the PWA or require X11, ffmpeg, GStreamer, or a desktop session. It binds to the active Tailscale IPv4 address and exits with an error when Tailscale is unavailable. For an intentional LAN-only setup, run `bun run host:lan` and enter that PC's address manually in the app.

In another terminal on the PC, run `bun run host:pair`. Enter the one-use eight-digit code shown there on the Android connection screen. The code lasts five minutes. `bun run host:devices` lists paired devices; `bun run host:revoke <device-id>` revokes one. Keep the persistent data directory (`~/.local/share/nexuslink` by default) in your normal PC backup. The Android device credential is held in Keystore-backed storage.

The app tries its saved host first. “Find a PC on this Wi-Fi” is a manual option. A paired PC and an arbitrary discovered machine are never interchangeable.

A Linux user-service template, logs, and Tailscale recovery instructions are in [host setup](docs/HOST-SETUP.md). The [protocol reference](docs/PROTOCOL.md) covers capabilities, authentication, and compatibility. [Agent history migration](docs/AGENT-MIGRATION.md) describes the SQLite migration and rollback. [Known limits](docs/KNOWN-LIMITS.md) records remaining work and observed test coverage.

## Development

```bash
bun install --frozen-lockfile
bun apps/desktop/node_modules/typescript/bin/tsc --project apps/desktop/tsconfig.json --incremental false
bun test apps/desktop/src/server/workspace apps/desktop/src/server/handlers/__tests__/agents.test.ts packages/rpc-types/src/__tests__
cd apps/flutter_client
flutter pub get
flutter analyze --no-pub
flutter test
cd android && bash gradlew assembleDebug
```

Tests use a fresh temporary data directory and disable outbound push notifications. Keep `bunfig.toml` active when running host tests.

The Windows host and PWA still live in `apps/windows-host` and `apps/mobile-client`. The new Android features use host capabilities; older hosts can still connect for their supported operations, but they cannot provide guarded editing or resumable PTY sessions. Streaming dependencies remain for the experimental viewer.

## License

MIT
