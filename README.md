# NexusLink

Remote desktop and AI agent controller that feels like a native phone OS: the PC runs the apps and AI agents, and your phone acts as the mobile cockpit.

* **AI Agent Control**: Seamless mobile chat interface for **Antigravity**, **Cursor CLI**, **Claude Code**, and **OpenCode** running on your PC.
* **Per-App Virtual Display**: Tapping an app opens it in a phone-shaped virtual display on the host (your physical desktop is never resized).
* **Remote Terminal & Files**: PTY terminal, live file browser, Git working tree inspector, and process manager.

---

## Supported Platforms

### 📱 Mobile Clients (Phone Controller)
| Platform | Client Type | Status | How to Test / Run |
| :--- | :--- | :--- | :--- |
| **Android** | Flutter App | **Production Ready** | Install `NexusLink-Android.apk` from GitHub Releases. |
| **iOS** | Flutter App | **Testing Ready** | Sideload `NexusLink-iOS.ipa` via AltStore/Sideloadly or build via Xcode. |
| **Any Device (iOS/Android/Desktop)** | Next.js PWA | **Production Ready** | Open browser → Tap *Add to Home Screen* (Full screen, zero install). |

### 💻 Desktop Hosts (Running the Agents & Apps)
| Host OS | Agent Control | Screen Mirroring | Terminal / Files | Notes |
| :--- | :---: | :---: | :---: | :--- |
| **Windows** (`apps/windows-host`) | ✅ Full | ✅ Full | ✅ Full | Native Windows PowerShell & RPC service. |
| **Linux/X11** (`apps/desktop`) | ✅ Full | ✅ Full (Xvfb/WebRTC) | ✅ Full | X11 virtual displays with GStreamer WebRTC. |
| **macOS** (`apps/desktop`) | ✅ Full | ⚠️ In Progress | ✅ Full | Agent chat, zsh terminal, and file manager work via `bun run server`. |

---

## Quick Start for Testing

### 1. Start the Host on your PC

#### Windows Host:
```powershell
bun run windows
# Or double-click run-host.cmd from the release zip
```

#### Linux Host:
```bash
bun run lan
```

#### macOS Host (Agent & Terminal control):
```bash
bun run server
```

The host prints a **QR code** for local Wi-Fi and **Tailscale** addresses.

---

### 2. Connect from your Phone

1. **Android**: Download and install the latest `NexusLink-*.apk` from the GitHub Releases page. Launch the app and scan the QR code (or let mDNS auto-discover the PC).
2. **iOS (Web PWA - Instant)**: Open Safari, navigate to `http://<your-pc-ip>:45678`, and tap **Share → Add to Home Screen**.
3. **iOS (Native IPA)**: Sideload the provided `NexusLink-iOS-unsigned.ipa` using AltStore, Sideloadly, or TrollStore.

---

## AI Agent Integration

NexusLink provides native mobile chat surfaces for major developer AI agents running locally on your workstation:

* **Antigravity**: Full tool execution view, diff review, permission approvals, and model picker.
* **Cursor CLI**: Sleek zinc/charcoal dark theme matching the Cursor IDE palette, multi-model selection (Composer, Codex, Grok, Claude).
* **Claude Code**: Native markdown rendering, code block syntax highlighting, and bash tool inspection.
* **OpenCode**: DeepSeek / MiMo model switching with real-time reasoning transcript streaming.

---

## Development

```bash
bun install
bun run dev          # Runs all workspaces concurrently
```

### Workspace Commands:
* `apps/windows-host`: Windows RPC daemon (`bun run start`)
* `apps/desktop`: Linux/macOS host UI and server (`bun run dev`)
* `apps/flutter_client`: Flutter mobile app (`flutter run`)
* `apps/mobile-client`: Next.js PWA client (`bun run dev`)
* `apps/relay`: Signaling server for remote NAT traversal (`bun run start`)

---

## Building Releases

### Android APK:
```bash
cd apps/flutter_client
flutter build apk --release
# Output: apps/flutter_client/build/app/outputs/flutter-apk/app-release.apk
```

### iOS Unsigned IPA (macOS):
```bash
cd apps/flutter_client
flutter create . --platforms=ios
flutter build ios --release --no-codesign
mkdir -p Payload && cp -r build/ios/iphoneos/Runner.app Payload/
zip -r NexusLink-iOS-unsigned.ipa Payload
```

---

## License

MIT
