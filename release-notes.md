## NexusLink Test 1.0.34+40 — PC chat library

Android opens on Recent chats, with Folders, search, provider/archive filters, offline saved transcripts, and retained drafts. Both PC hosts share a persistent chat index and source health reporting. Managed replies use durable operation IDs and never automatically resend uncertain deliveries. Codex managed sessions use the official app-server protocol and keep their native thread identity.

The Android asset is **NexusLink Test**, application ID `com.nexuslink.nexuslink.test`, built with debug signing. It installs alongside the production app. It is not a production-signed update. An existing Test installation signed with another certificate cannot be updated by this APK; preserve its drafts and settings before replacing it.

The Windows installer contains the shared library and embedded database/provider workers. Its standalone startup and chat-list RPC were verified outside the source checkout.

Imported conversations remain read only when the original PC run's safety cannot be established. Busy, missing-folder, unsupported IDE, and host-interrupted sessions do not silently start another run. Real Android/Windows/Linux lifecycle acceptance remains pending; see `docs/CHAT-LIBRARY-IMPLEMENTATION.md`.

Validation: 159 Flutter tests and 74 host tests passed, with one environment-dependent skip in each suite. PWA production compilation and the Windows standalone smoke check passed.
