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
