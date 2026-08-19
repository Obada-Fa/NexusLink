# Production & Release Checklist

This guide outlines the path from **GitHub Testing Releases** to **Store Distribution (Google Play & Apple App Store)** and standalone desktop hosts.

---

## 1. Testing Distribution (Current Phase)

- [x] **Android APK Distribution**: Direct `.apk` builds attached to GitHub Releases (`NexusLink-Android.apk`).
- [x] **Web PWA Client**: `apps/mobile-client` served over HTTPS for instant iOS/Android Safari access without app store requirements.
- [ ] **iOS Sideloading**: Unsigned `.ipa` builds attached to releases for AltStore / Sideloadly / TrollStore users.
- [ ] **Windows Host Portable**: Packaged `.zip` with `run-host.cmd` for zero-setup execution.

---

## 2. Android Store Release (Google Play)

### Keystore & Signing
1. Generate an upload keystore:
   ```bash
   keytool -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Configure `apps/flutter_client/android/key.properties`:
   ```properties
   storePassword=<password>
   keyPassword=<password>
   keyAlias=upload
   storeFile=upload-keystore.jks
   ```
3. Build the Android App Bundle (`.aab`):
   ```bash
   cd apps/flutter_client
   flutter build appbundle --release
   ```

### Google Play Console Checklist
- [ ] Create App listing with screenshot mockups (Agent chat, terminal, file viewer).
- [ ] Set Content Rating questionnaire.
- [ ] Provide Privacy Policy link.
- [ ] Upload `.aab` to Internal Testing / Closed Testing track.

---

## 3. iOS Store Release (Apple App Store & TestFlight)

### Prerequisites
* Apple Developer Account ($99/year).
* macOS build environment with Xcode installed.

### Scaffolding & Configuration
1. Generate iOS scaffolding:
   ```bash
   cd apps/flutter_client
   flutter create . --platforms=ios
   ```
2. Configure `apps/flutter_client/ios/Runner/Info.plist` with required privacy descriptions:
   * `NSLocalNetworkUsageDescription` & `NSBonjourServices` (`_nexuslink._tcp`) for LAN host mDNS discovery.
   * `NSMicrophoneUsageDescription` & `NSSpeechRecognitionUsageDescription` for voice prompts.
   * `NSPhotoLibraryUsageDescription` & `NSCameraUsageDescription` for photo attachments.
   * `NSAppTransportSecurity` (`NSAllowsLocalNetworking: true`) for local IP communication.

### TestFlight & App Store Build
```bash
cd apps/flutter_client
flutter build ipa --release
```
* Upload via Xcode Organizer or `xcrun altool` to **TestFlight** for public beta testing (up to 10,000 testers via public link).
* Submit for App Store Review.

---

## 4. Desktop Host Packaging (Windows / macOS / Linux)

To eliminate the need for users to run terminal commands or install Bun manually:

- [ ] **Windows Host**: Package `apps/windows-host` as a single `.exe` or Tauri tray application with an installer (Inno Setup / NSIS).
- [ ] **macOS Host**: Implement native ScreenCaptureKit and CoreGraphics input helper to upgrade macOS from agent-only to full mirroring; package as a `.dmg` with a menu bar icon.
- [ ] **Linux Host**: Package as an AppImage or `.deb` with systemd user service integration.

---

## 5. Security & Networking

- [ ] **Authentication**: Ensure ECDH-paired session tokens use production cryptography and expire appropriately.
- [ ] **Relay Deployment**: Deploy `apps/relay` on a secure VPS with TLS termination (`wss://relay.yourdomain.com`).
- [ ] **Path Traversal Protection**: Enforce workspace boundary checks on `fs.read`, `fs.list`, and `fs.write` handlers.
- [ ] **Permissions & Tool Prompts**: Keep interactive confirmation dialogs enabled on mobile for critical agent tool executions (terminal bash execution, file writes).
