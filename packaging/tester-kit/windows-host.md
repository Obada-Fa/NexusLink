# Windows host

This folder is a portable Windows host. Testers do **not** need Git, Node, or Bun.

## Requirements

- 64-bit Windows 10 or 11.
- Same Wi-Fi as the phone, **or** Tailscale on both devices.
- Windows Defender may warn on an unsigned `.exe`. Choose **More info → Run anyway** if you trust this build.

## Run

1. Unzip the kit (do not run from inside the zip).
2. Open `windows-host`.
3. Double-click **`run-host.cmd`**.

Leave the window open. Scan the QR from the Android app, or open the printed `http://…:45678` URL on the phone.

The first launch may prompt to allow **NexusLink** through the firewall. Allow it on **private** networks.

To stop: close the window or press `Ctrl+C`.

## Layout

| File | Role |
| --- | --- |
| `run-host.cmd` | Sets `NEXUSLINK_STATIC_DIR` and starts the host |
| `nexuslink-host.exe` | Compiled host (RPC + PWA on port 45678) |
| `www/` | Phone web UI |

Do not move `nexuslink-host.exe` without the `www` folder. They must stay together.
