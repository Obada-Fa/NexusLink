# nexus_audio

Android-only Flutter plugin: Nexus Audio's PC streams (ABP v2 over TLS, port 8010) inside the Nexus app.

- **mic**: phone mic → PC virtual mic
- **playHere**: PC speakers → phone
- **sendDevice**: phone audio (MediaProjection, Android 10+) → PC speakers

Dart API, channels and error codes: `docs/NEXUS-APP-PHASE1.md` §5. The engine
(`android/src/main/kotlin/com/nexus/nexus_audio/pc`, `audio`, `model`) is copied from
`tools/audio-bridge-sync/android` (Nexus Audio), which keeps its own copy.

The plugin's manifest declares the foreground service (`PcStreamService`, types per live stream) and its
permissions, so the host app's manifest needs no edits. The app asks for RECORD_AUDIO and
POST_NOTIFICATIONS before `NexusAudio.start`; the plugin only checks RECORD_AUDIO.

Tests: `flutter test` (Dart) and `gradlew :nexus_audio:testDebugUnitTest` from a host app (JVM;
`Abp2LiveServerTest` runs only when `ABP2_TEST_PORT` / `ABP2_TEST_CODE` point at a live server).
