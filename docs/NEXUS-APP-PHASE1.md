# Nexus app, phase 1: "one app, one scan"

Status: approved plan, in progress (2026-11-08). Owner: orchestrator session.
App: `apps/flutter_client` (package id stays `com.nexuslink.nexuslink`, display name becomes **Nexus**).

Phase 1 changes nothing on the PC side. Every utility keeps its protocol:
NexusLink RPC on 45678, Remote pinned TLS on 45679, Audio ABP v2 (TLS) on 8010
(`nexus-utilities/docs/SPEC.md` §6.1 and §7).

## 1. Decisions fixed by this spec

| Topic | Decision |
|---|---|
| Where the module contract lives | In the app: `lib/src/shell/module.dart`. Feature packages (`nexus_remote`, `nexus_audio`) know nothing about the shell; small adapters in `lib/src/modules/<id>/` turn them into modules. Keeps packages independently testable; we can extract a shared `nexus_module` package in P3 if needed. |
| Capabilities in phase 1 | Derived statically from which utilities are paired (§3.3). No PC-side capability advertisement yet (that is P2's gateway). |
| Tiles | Paired and reachable: normal tile. Paired but unreachable: dimmed tile, "Offline", tap explains. Not paired: no tile. (Refines "tiles per paired, reachable capability" so tiles don't jump in and out while probing.) |
| Foreground services | Phase 1 keeps two: the existing `LiveActivityService` (monitor, `connectedDevice`) and **one** audio service in the audio plugin (`microphone|mediaPlayback|mediaProjection`, types set per live stream, as Nexus Audio's `PcStreamService` does today). Merging both into one shell-owned service is P2. The shell's "live bar" already shows both. |
| Party mode | **Out of phase 1.** It is ~2.5k lines (Nearby, BLE hotspot, JTransforms, Compose UI) and not cheap even as a native Activity. Nexus Audio keeps it. |
| Typed fallback | NexusLink URL + code stays as today. The pairing flow also offers manual Remote (address, code, optional fingerprint) and Audio (address, code) entry for PCs without a camera, using the same enrollers. |
| iOS | No iOS project exists. Modules still declare `platforms`; Audio is Android-only. |
| Legacy saved devices | Migrated once into saved targets (§3.2). The old pref key is left in place for rollback. NexusLink credentials stay where `RpcClient` keeps them (keyed by ws URL), so `RpcClient` does not change. |
| Retiring NexusLink's phone mic | Not in phase 1. `phone_mic.dart` / `mic.ts` stay until Audio's "Use as PC mic" is proven on a real phone. |

## 2. Package layout

```
apps/flutter_client/
  lib/
    main.dart                      app entry: shell (A)
    src/shell/                     (A) module contract, registry, home grid, live bar, device picker
      module.dart                  the contract in §4, exactly
      module_registry.dart         the list of compiled-in modules
      capabilities.dart            utility → capability mapping, reachability
      home_screen.dart, live_bar.dart, device_picker.dart, ...
    src/modules/                   adapters, one folder per module
      desktop/  agents/  terminal/ (A) wrap existing screens
      remote/                      (C) adapter over packages/nexus_remote
      audio/                       (E) adapter + Flutter Audio screen over packages/nexus_audio
    src/session/                   (D) saved targets, credential vault, enrollment, pairing flow
    src/auth/pair_bundle.dart      (D) parses the whole NXU1 bundle
    src/screens/scan_pair_screen.dart (D)
    ... existing feature code (A only where wrapping requires it)
  packages/
    nexus_remote/                  (C) Flutter package: Remote session + trackpad/keyboard/dictation UI
    nexus_audio/                   (B) Flutter plugin: Dart API + Android Kotlin engine + audio FGS
```

The app depends on the packages by path (`nexus_remote: {path: packages/nexus_remote}`). Those two lines are added by E in wave 2, so wave-1 workers never share `pubspec.yaml`.

## 3. Session core

### 3.1 Saved target (`lib/src/session/target.dart`)

```dart
/// Utility ids from the NXU1 "u" map.
abstract final class UtilityIds {
  static const nexuslink = 'nexuslink';
  static const remote = 'remote';
  static const audio = 'audio';
}

class TargetAddresses {
  const TargetAddresses({this.tailscale, this.lan = const []});
  final String? tailscale;          // addr.ts
  final List<String> lan;           // addr.lan
  /// Tailscale first, then LAN, de-duplicated.
  List<String> get ordered;
  Map<String, dynamic> toJson();
  factory TargetAddresses.fromJson(Map<String, dynamic> json);
}

/// One paired utility on a target. Never holds a secret.
class UtilityLink {
  const UtilityLink({
    required this.utility,          // UtilityIds.*
    required this.port,
    this.hostId,                    // "host" from the bundle / enroll reply
    this.fingerprint,               // pinned SHA-256 of the DER cert, 64 upper hex (remote, audio)
    this.deviceId,                  // audio: deviceId from the enroll reply
    this.preferredHost,             // the address that answered at enrollment
    this.wsUrl,                     // nexuslink only: ws://host:port/rpc, the RpcClient credential key
    required this.pairedAt,
  });
  Map<String, dynamic> toJson();
  factory UtilityLink.fromJson(Map<String, dynamic> json);
}

class SavedTarget {
  const SavedTarget({
    required this.id,               // NXU1 "hub" id, or "legacy:<wsUrl>" for typed-code / migrated PCs
    required this.name,
    this.icon = 'desktop',          // one of deviceIcons
    this.kind = 'pc',               // 'pc' now; 'tv' | 'phone' in P4
    this.addresses = const TargetAddresses(),
    this.utilities = const {},      // key: UtilityIds.*
    this.wake,                      // WakeConfig from state/wake_config.dart
  });
  bool has(String utility);
  SavedTarget copyWith({...});
  Map<String, dynamic> toJson();
  factory SavedTarget.fromJson(Map<String, dynamic> json);
}
```

### 3.2 Store and vault

```dart
/// SharedPreferences key 'nexus-targets-v1' (JSON list) and 'nexus-current-target' (id).
class TargetStore {
  static Future<List<SavedTarget>> load();          // migrates once from 'nexuslink-saved-devices'
  static Future<void> save(List<SavedTarget> targets);
  static Future<SavedTarget> upsert(SavedTarget target);   // merge by id; also merges a "legacy:<wsUrl>" target
                                                            // into a hub target with the same nexuslink wsUrl
  static Future<void> remove(String targetId);      // also wipes its vault secrets and the nexuslink credential
  static Future<String?> currentId();
  static Future<void> setCurrent(String? targetId);
}

/// Secrets in the Keystore-backed store behind PlatformBridge (in-memory off Android).
class CredentialVault {
  static String keyFor(String targetId, String utility) => 'nxu/$targetId/$utility';
  static Future<String?> read(String targetId, String utility);
  static Future<void> write(String targetId, String utility, String secret);
  static Future<void> delete(String targetId, String utility);
}
```

Secrets: Remote token and Audio token go in the vault. The NexusLink credential stays under its ws URL (written by `RpcClient`), so a NexusLink link just records `wsUrl`.

Migration: each legacy `SavedDevice {url, name, icon, wake}` becomes `SavedTarget(id: 'legacy:<url>', name, icon, wake, utilities: {nexuslink: UtilityLink(port from url, wsUrl: url)})`. The current target becomes the one whose wsUrl equals `last_host`.

### 3.3 Capabilities (`lib/src/shell/capabilities.dart`, A)

```dart
class Capability {
  const Capability(this.id, {this.version = 1, required this.utility});
  final String id;        // e.g. 'screen'
  final int version;
  final String utility;   // provider: UtilityIds.*
}

const phase1Capabilities = <String, List<String>>{
  UtilityIds.nexuslink: ['screen', 'apps', 'terminal', 'agents'],
  UtilityIds.remote:    ['input', 'dictation'],
  UtilityIds.audio:     ['audio.source', 'audio.sink', 'mic'],
  // audio.source = PC speakers can stream to the phone
  // audio.sink   = PC can play phone audio
  // mic          = PC accepts the phone as its microphone (ABP_Phone_Mic)
};
```

Reachability per utility: nexuslink = the existing connection provider is connected (or a TCP connect to the ws port succeeds); remote = TCP connect to `preferredHost`, then other addresses, on 45679; audio = TCP connect on 8010. Probe on target select, app resume and network change; at most one probe per utility every 10 s.

### 3.4 Enrollment (`lib/src/session/enrollment/`, D)

```dart
class PairBundle {                         // lib/src/auth/pair_bundle.dart
  final String hubId, pcName;
  final DateTime expiresAt;
  final TargetAddresses addresses;
  final Map<String, BundleEntry> utilities;   // only known ids; unknown keys ignored
}
class BundleEntry { final String utility; final int port; final String code; final String? fingerprint, hostId; }
PairBundle parsePairBundle(String text, {DateTime? now});   // throws PairBundleException (user-facing message)
// The old NexusLinkPairing view stays available as bundle.nexusLink (for the typed path and old tests).

enum EnrollState { pending, working, done, failed, skipped }
class EnrollProgress { final String utility; final EnrollState state; final String? message; }

/// NexusLink pairs through the app's existing connection (RpcClient pairing handshake),
/// so the shell injects it: it must connect with the code and leave the credential stored.
typedef NexusLinkEnroller = Future<void> Function(String wsUrl, String code);

class PairingFlow {
  /// Enrolls every utility in [bundle] (addresses in order: ts, then lan), each independently:
  /// one failure never blocks the others. Stores secrets in the vault, upserts ONE SavedTarget
  /// (id = bundle.hubId) and makes it current. Returns null only when nothing enrolled.
  static Future<SavedTarget?> enrollAll(
    PairBundle bundle, {
    required NexusLinkEnroller enrollNexusLink,
    String deviceName,                       // default: a phone model string, else 'Android phone'
    void Function(EnrollProgress)? onProgress,
  });

  /// UI: scan → progress list (one row per utility, retry button on failed rows) → pop with the target.
  static Future<SavedTarget?> run(BuildContext context, {required NexusLinkEnroller enrollNexusLink});
}
```

Wire formats the enrollers speak (copied from the utilities, no changes):

- Remote: HTTPS `POST https://<addr>:<port>/pair` body `{"code": "...", "device_name": "..."}`, certificate pinned to `fp` (SHA-256 of DER, upper hex, as `nexusRemote/mobile/lib/session.dart` does). Reply `{"token", "host_id"}`. Token → vault.
- Audio: TLS to `<addr>:<port>`, pin `fp`, send one line `{"abp":2,"op":"enroll","code":"...","deviceName":"..."}\n`, read one line `{"ok":true,"deviceId","token"}`. Token → vault, deviceId → link.
- NexusLink: `enrollNexusLink('ws://<addr>:<port>/rpc', code)`.

## 4. Module contract (`lib/src/shell/module.dart`, A creates it exactly; others code against it)

```dart
import 'package:flutter/widgets.dart';
import '../session/target.dart';
import 'capabilities.dart';

class CapabilityRequirement {
  const CapabilityRequirement.anyOf(this.ids, {this.minVersion = 1});
  final List<String> ids;
  final int minVersion;
  bool isMetBy(Iterable<Capability> caps);
}

/// What a module gets about the current target. Rebuilt when the target or its reachability changes.
class ModuleContext {
  const ModuleContext({required this.target, required this.capabilities, required this.reachable});
  final SavedTarget target;
  final List<Capability> capabilities;     // paired capabilities of this target
  final Set<String> reachable;             // utility ids that answered the last probe
  bool isReachable(String utility) => reachable.contains(utility);
  Future<String?> secret(String utility);  // CredentialVault.read(target.id, utility)
}

/// One running thing shown in the live bar (an audio stream, a connected trackpad...).
class LiveActivity {
  const LiveActivity({required this.moduleId, required this.label, required this.icon, this.onTap, this.onStop});
  final String moduleId;
  final String label;
  final IconData icon;
  final VoidCallback? onTap;    // opens the module
  final VoidCallback? onStop;   // stops it from the bar
}

abstract class NexusModule {
  const NexusModule();
  String get id;                                   // 'desktop' | 'agents' | 'terminal' | 'remote' | 'audio'
  String get title;
  IconData get icon;
  CapabilityRequirement get requires;
  Set<TargetPlatform> get platforms => const {TargetPlatform.android};
  int get order => 100;                            // home grid order, low first

  /// Utilities this module needs reachable to open (for the dimmed/offline state).
  Set<String> utilitiesFor(ModuleContext ctx) =>
      {for (final c in ctx.capabilities) if (requires.ids.contains(c.id)) c.utility};

  /// Optional custom tile body (live badge, level meter). Null → the standard tile.
  Widget? buildTileExtra(BuildContext context, ModuleContext ctx) => null;

  /// The screen pushed when the tile is tapped.
  Widget buildEntry(BuildContext context, ModuleContext ctx);

  /// Optional settings section shown under the target's settings.
  Widget? buildSettings(BuildContext context, ModuleContext ctx) => null;

  /// Live activities while this module runs something. Null stream → none.
  Stream<List<LiveActivity>>? liveActivities(ModuleContext ctx) => null;

  /// Called when this target becomes current (ctx) or is left (null). Start/stop background work here.
  Future<void> onTargetChanged(ModuleContext? ctx) async {}
}
```

The registry is a plain `const` list in `module_registry.dart`; the home grid shows modules whose `platforms` contains the current platform and whose `requires` is met by the target's capabilities.

Phase 1 modules: `desktop` (screen, apps: mirror, launcher, PC vitals), `agents` (monitor, arena, chats, agent screen), `terminal` (terminal, files, editor), `remote` (input/dictation), `audio` (audio.source | audio.sink | mic; Android only).

## 5. Audio plugin contract (`packages/nexus_audio`, B)

Flutter plugin package, Android only. Kotlin package `com.nexus.nexus_audio`. The engine is copied from `tools/audio-bridge-sync/android/app/src/main/java/com/nexus/audio/` (`pc/*` minus `PcLinkViewModel.kt`, `NxuBundle.kt`, `PairingStore`; plus `audio/AudioCapture.kt`, `audio/AudioPlayer.kt`, `model/StreamInfo.kt`, and the projection part of `service/MediaProjectionService.kt`), with Compose/ViewModel/`R`/`MainActivity` references removed. Its JVM unit tests come along.

Dart API (`package:nexus_audio/nexus_audio.dart`):

```dart
enum AudioStream { mic, playHere, sendDevice }        // wire names: 'mic', 'playHere', 'sendDevice'
enum StreamPhase { off, connecting, live, retrying }  // wire names: lower case

class AudioPairing {                                  // everything the engine needs, secrets included
  const AudioPairing({required this.pcName, required this.hosts, required this.port,
                      required this.fingerprint, required this.deviceId, required this.token});
  Map<String, Object?> toMap();
}
class AudioStreamStatus { final StreamPhase phase; final String? detail; bool get on; }
class AudioNotice { final AudioStream stream; final String message; final bool pairAgain; }
class AudioEngineState { final Map<AudioStream, AudioStreamStatus> streams; final double micLevel; }

class NexusAudio {
  static const methods = MethodChannel('nexus/audio');
  static const events = EventChannel('nexus/audio/events');

  static Future<void> start(AudioStream stream, AudioPairing pairing);  // sendDevice asks MediaProjection consent itself
  static Future<void> stop(AudioStream stream);
  static Future<void> stopAll();
  static Future<AudioEngineState> state();
  /// Restarts mic/playHere streams the user left on (sendDevice is never restored: it needs fresh consent).
  static Future<bool> restore(AudioPairing pairing);
  static Future<void> forgetWanted();
  static Stream<AudioEngineState> get stateStream;     // from 'streams' + 'micLevel' events
  static Stream<AudioNotice> get notices;              // from 'notice' events
}
```

Method channel `nexus/audio`:

| method | args | result / errors |
|---|---|---|
| `start` | `{stream, pairing: {pcName, hosts: [..], port, fingerprint, deviceId, token}}` | `null`. Errors: `MIC_PERMISSION` (RECORD_AUDIO not granted), `CONSENT_DENIED` (projection refused), `UNSUPPORTED` (sendDevice below Android 10), `BAD_ARGS` |
| `stop` | `{stream}` | `null` |
| `stopAll` | – | `null` |
| `state` | – | `{streams: {mic: {phase, detail}, playHere: {...}, sendDevice: {...}}, micLevel: 0.0..1.0}` |
| `restore` | `{pairing}` | `bool` (true if anything started) |
| `forgetWanted` | – | `null` |

Event channel `nexus/audio/events` sends maps:
`{type: 'streams', streams: {…as in state…}}` on every change; `{type: 'micLevel', level}` at most 15 per second while the mic is live; `{type: 'notice', stream, message, pairAgain}`.

Permissions are asked by Dart (permission_handler) before `start`; the plugin only checks. The plugin's own `AndroidManifest.xml` declares the service and `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`, `RECORD_AUDIO`, `WAKE_LOCK`, so the app manifest needs no edits. Its notification opens the app via the package's launch intent and has a Stop action.

## 6. Remote package contract (`packages/nexus_remote`, C)

Ported from `nexusRemote/mobile/lib` (session, trackpad, keyboard, taskbar, hold-to-transcribe, recording, audio). Removed: its own pairing UI and its `hosts` table / secure-storage token. Kept: drafts, recordings and settings tables (own sqlite file `nexus_remote.sqlite`).

```dart
class RemoteEndpoint {
  const RemoteEndpoint({required this.hosts, required this.port, required this.fingerprint,
                        required this.hostId, required this.token, this.pcName = 'PC'});
  final List<String> hosts;    // tried in order
  final int port;              // 45679
  final String fingerprint;    // pinned, 64 upper hex
  final String hostId, token, pcName;
}

class RemoteSession extends ChangeNotifier {      // the existing session.dart, re-keyed
  RemoteSession(this.endpoint, {this.onUnauthorized});
  final RemoteEndpoint endpoint;
  final VoidCallback? onUnauthorized;            // token revoked → shell offers "Pair again"
  Future<void> initialize();                     // opens the sqlite db, connects
  Future<void> disconnect();
  bool get connected;
  // ...existing input/dictation/windows API unchanged
}

/// Whole Remote UI (trackpad, keyboard, dictation, taskbar) for one session.
class RemoteHomeScreen extends StatelessWidget { const RemoteHomeScreen({required this.session}); }
```

## 7. Worker split and file ownership

Paths are relative to `apps/flutter_client/` unless absolute. A worker edits only its own files. Anything else it needs → it says so in its report.

**Wave 1 (parallel)**

| Worker | Model | Owns | Must not touch |
|---|---|---|---|
| **A** shell + modules + migration | Opus 5.5, high | `lib/main.dart`, `lib/src/shell/**`, `lib/src/modules/{desktop,agents,terminal}/**`, existing `lib/src/**` files it has to adapt (except D's), `pubspec.yaml`, `android/app/**`, `test/**` except D's tests | `lib/src/session/**`, `lib/src/auth/pair_bundle.dart`, `lib/src/screens/scan_pair_screen.dart`, `packages/**`, `lib/src/modules/{remote,audio}/**` |
| **B** audio plugin | Opus 5.5, high | `packages/nexus_audio/**` | everything in the app outside that folder |
| **C** remote package | Sonnet 5.5, medium | `packages/nexus_remote/**`, `lib/src/modules/remote/**` (adapter; written against §4, may land before A's `module.dart` exists—then it reports and the adapter is wired in wave 2) | everything else |
| **D** enrollment + targets | Sonnet 5.5, medium | `lib/src/session/**`, `lib/src/auth/pair_bundle.dart`, `lib/src/screens/scan_pair_screen.dart`, `test/session/**`, `test/pair_bundle_test.dart`, `test/scan_pair_screen_test.dart` | everything else (A wires `PairingFlow` into the shell) |

A codes against D's §3 API. If D hasn't landed when A integrates, A finishes everything else first and reports what is left.

**Wave 2 (after A and B are reviewed)**

| Worker | Model | Owns |
|---|---|---|
| **E** audio screen + integration | Opus 5.5, high | `lib/src/modules/audio/**`, `pubspec.yaml` (path deps on both packages), `module_registry.dart` (add remote + audio), `android/app/**` if needed, the debug APK build |

## 8. Verification (every worker, then the orchestrator)

- `flutter analyze` clean for the files the worker owns; `flutter test` green for the app and for its package.
- Debug APK built in a copy under `/tmp` (the shared drive is noexec; see `scripts/build-android-profile.sh`).
- Screenshots from widget tests (`flutter test` + `matchesGoldenFile` or `RepaintBoundary.toImage`), or a private headless emulator (`-read-only -no-window`, explicit `-s emulator-XXXX` for adb). Never the user's display `:0`, never the user's phone, never the user's app data dirs.
- Kotlin: the copied JVM unit tests run with `gradlew :nexus_audio:testDebugUnitTest` (or the plugin's equivalent) from the `/tmp` copy.

## 9. Not in phase 1

Hub gateway and multiplexed TLS (P2), merged foreground service (P2), package manager and store (P3), receiver mode, Cast, TV remote, launcher shortcuts and Quick Settings tiles (P4), iOS audio, party mode, retiring `phone_mic.dart` / `mic.ts`.
