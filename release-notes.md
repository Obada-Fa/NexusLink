## NexusLink Test 1.0.35+41 — Saved devices and PC app menus

- The login screen shows saved PCs as named cards with desktop, laptop, server, or gaming icons. Tap a card to reconnect using the existing pairing credentials.
- Long-press a device to rename it, change its icon, or remove it. The previous connection migrates automatically, and address entry is available under Add device.
- The mobile PC tab has Running apps and Favourites / most used menus. Favourites and mobile usage counts are saved separately for each PC.
- Long-press apps to favourite, close, or restart them. Desktop close/restart requires the updated Linux PC host from this release. Normal window close allows applications to display unsaved-work prompts.

This APK is **NexusLink Test** (com.nexuslink.nexuslink.test), built with debug signing as in the preceding Test releases. It installs alongside the production app. Android requires matching signing certificates to update an existing Test installation.

Validation: targeted Flutter analysis and 12 mobile tests passed; 48 host/protocol tests passed, with two environment-dependent integration tests skipped. Physical-device install and lifecycle testing have not been performed.
