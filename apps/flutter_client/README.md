# NexusLink Flutter Client

Native mobile client for NexusLink on **Android** and **iOS**.

Provides a responsive mobile interface to control developer AI agents, terminal sessions, file explorer, and per-app remote desktop mirroring from your PC.

---

## Supported AI Agent Themes

The client dynamically adapts its color palette, iconography, and UI controls based on the active agent:

* **Cursor CLI**: Sleek monochromatic dark theme (`#0E0E12` canvas, `#18181C` assistant bubbles, `#2B2D37` zinc user bubbles).
* **Antigravity**: Deep violet palette with purple accent highlights and interactive approval cards.
* **Claude Code**: Dark terracotta palette with styled markdown code blocks.
* **OpenCode**: Dark emerald/teal theme with reasoning transcript stream views.

---

## Development

Ensure Flutter 3.x+ is installed:

```bash
cd apps/flutter_client
flutter pub get
flutter run
```

---

## Building Releases

### Android APK (Direct Testing Distribution)
```bash
flutter build apk --release
# Generated APK: build/app/outputs/flutter-apk/app-release.apk
```

### Android App Bundle (Google Play Store)
```bash
flutter build appbundle --release
# Generated AAB: build/app/outputs/bundle/release/app-release.aab
```

### iOS Unsigned IPA (For Sideloading / AltStore)
```bash
flutter create . --platforms=ios
flutter build ios --release --no-codesign
mkdir -p Payload && cp -r build/ios/iphoneos/Runner.app Payload/
zip -r NexusLink-iOS-unsigned.ipa Payload
```

### iOS App Store / TestFlight (Requires Mac & Apple Developer Account)
```bash
flutter build ipa --release
```

---

## Required iOS Info.plist Permissions

When generating the `ios/` folder, add the following to `ios/Runner/Info.plist`:

* `NSLocalNetworkUsageDescription` & `NSBonjourServices` (`_nexuslink._tcp`): LAN host mDNS discovery.
* `NSAppTransportSecurity` (`NSAllowsLocalNetworking: true`): Local WebSocket and HTTP communication.
* `NSMicrophoneUsageDescription` & `NSSpeechRecognitionUsageDescription`: Speech-to-text voice prompts.
* `NSPhotoLibraryUsageDescription` & `NSCameraUsageDescription`: Image attachments for AI agent prompts.

### Floating pet monitor (Android)

Enable **Live activity** and **Floating pet monitor** in NexusLink settings, allow
Display over other apps, then leave NexusLink in the background. Drag the fox to
move it, tap to read updates, or long-press for hide/stop controls. Its expression
and color reflect connection, working, approval, and failure states.

The pet opens one conversation monitor, grouped into Needs attention, Running,
and Recent. Each section initially shows up to five conversations. Swipe up at
the bottom for five more recent conversations, or use a section's Show more
control. Cards update in place and include the agent, project, latest preview,
current activity and timestamp. There is no duplicate event feed in the panel.
Important notifications and the bounded on-device activity history are retained.

An updated Linux desktop host exposes `activity.monitor`: read-only bounded
summaries for up to 50 Codex and 50 Antigravity conversations, prioritizing waiting
and running conversations before recent idle ones. The phone polls every 15
seconds; discovery reconciles every 30 seconds and uses filesystem notifications
where supported. This observes saved provider data, not the GUI screen: apps that
do not expose running state cannot supply live progress. Idle never implies
successful completion. Offline cards are explicitly marked last known.
Tap a card to open its conversation in NexusLink. Monitoring does not send prompts,
resume a run, or grant transcript/control access to the background connection.

The first app tab is **Monitor**. It offers All, Running, Attention and Recent
filters, search, provider/archive filters and project folders. Host-side filtering
and priority ordering happen before pagination, so older active work remains
visible. Managed conversations expose editing, reading, commands, thinking and
responding when available; no completion percentage is inferred. Live changes are
coalesced without postponing refresh indefinitely during a stream of events.
Opening a conversation provides the existing supported remote reply, approval and
stop controls. PC statistics remain available on the PC tab and are opt-in above
navigation for new settings.

For a shared filesystem that cannot execute the Gradle wrapper directly, build the
debug APK from `android/` using `bash gradlew :app:assembleDebug --console=plain`.

#### Animated red fox

The Android pet bundles the MIT-licensed Red Fox behavior atlas from
[Virtual Pet Desktop](https://github.com/sheelarajeshkumar/virtual-pet-desktop),
pinned to `9a4f83cc277daf4869d09810256028e3dee44ec7`. The 32-frame atlas is
unchanged, decoded once per pet view, and rendered natively. Upstream provenance
and the full MIT notice ship in `android/app/src/main/assets/pets/fox/` and are
also readable from the pet's long-press **Fox artwork · credits** menu.

The fox runs/sniffs while working, looks up when attention is needed, naps offline
or after 45 seconds idle, and briefly hops with sparkles when working transitions
to completion. Repeated status snapshots do not restart reactions. Dragging tilts
the fox; releasing adds a short landing bounce and faces it inward from the edge.
Long-press **Play with fox** triggers a playful reaction. **Reduce motion** freezes
sprite frames and removes secondary motion; Android's disabled animator setting
is also respected. No sound or autonomous screen roaming is enabled.

Animation callbacks stop when detached or hidden. Active rendering is capped at
25 fps, idle/sleep follows the slower source frame cadence, and reduced motion
checks at 1 Hz. The PNG adds about 1.5 MB compressed and uses about 6.1 MiB decoded.
Native state tests: `bash gradlew :app:testDebugUnitTest` from `android/`.

#### Session overview

Tapping the pet toggles its panel open/closed. The pet stays above the panel so it
can be tapped again even when their positions overlap. **Open full monitor** returns
to the monitor root. The pet's long-press menu keeps animation and hide/stop settings
out of the conversation list.

Validation without an APK: `flutter test --no-pub` for Flutter tests;
`bash gradlew :app:testDebugUnitTest -x compileFlutterBuildDebug` from `android/`
for native compilation and tests (requires existing Flutter debug intermediates).

### Wake a saved PC from the main menu

Every saved PC has **Set up wake / Wake PC** and **Wake settings**, available while
it is offline. Settings survive renaming, changing its icon, and reconnecting.
The phone sends one wake action, checks the PC's NexusLink port for up to two
minutes, then connects using the normal saved device credentials. **Stop waiting**
stops those checks; it does not send another wake or power command.

- **Home server:** POST to an always-on server's wake endpoint. The default for
  this installation is `http://100.101.246.19:3050/wake` over Tailscale, with
  `X-API-Key` authentication. Enter its existing key once in Wake settings. The
  API key is stored using Android's existing encrypted credential store and is
  never included in saved-device JSON or the APK. Bearer-token webhooks are also
  supported. Redirects are rejected so credentials stay on the configured server.
- **Direct Wake-on-LAN:** set the PC's wired adapter MAC, LAN broadcast and UDP
  port. The phone sends three standard magic packets. This requires access to the
  PC's local network; Tailscale does not carry LAN broadcasts to the home server.
- **Home Assistant:** optionally configure its base URL, access token and
  `switch`, `button` or `script` entity. A Tapo P100 uses `switch.turn_on`; the app
  never toggles it or turns it off. The separate Tapo phone app can still be used.

The home server's existing `/home/obada/infrastructure/wol-api/server.js` was found
stopped. Its existing API key and PC MAC were preserved in a persistent user
service, `nexuslink-wake.service`, using `scripts/nexuslink_wake_relay.py`. It binds
only `100.101.246.19:3050`, targets `BC:FC:E7:1A:1D:AA`, broadcasts on
`192.168.68.255`, and starts without an SSH login. Its key file is
`/home/obada/.config/nexuslink-wake/api-key` on the server (mode 0600). A private
local copy for this setup is `/home/obada/.config/nexuslink/wake-server-key.txt`.

Health: `GET /health`; wake: `POST /wake` with the `X-API-Key` header. An accepted
request confirms only that packets were sent. PC power/firmware and the NexusLink
host starting after boot are separate requirements. An idle or unreachable PC is
never reported as connected just because the wake server returned success.

References: [Home Assistant Wake on LAN](https://www.home-assistant.io/integrations/wake_on_lan/),
[TP-Link / Tapo P100 support](https://www.home-assistant.io/integrations/tplink/).
