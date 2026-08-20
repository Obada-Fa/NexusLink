# NexusLink tester kit

Use this folder to try NexusLink without cloning the repo or installing Bun.

**NexusLink** turns a PC into the computer, and a phone into the cockpit: AI agents, a remote terminal, files, and a phone-shaped view of apps on the host.

---

## What is in this kit

| Folder | Who uses it | What it is |
| --- | --- | --- |
| `linux-host/` | Tester with a **Linux PC** (X11) | Double-click / run `run-host.sh` |
| `windows-host/` | Tester with a **Windows PC** | Double-click `run-host.cmd` |
| `android/` | Tester with an **Android phone** | Install `NexusLink-Android.apk` |

iPhone testers do **not** need an IPA. After the PC host is running, open Safari to the URL the host prints (port **45678**) and use **Share → Add to Home Screen**.

Give testers the whole zip, or only the folder that matches their PC plus the Android APK.

---

## 10-minute setup

### 1. Start the host on the PC

**Linux:** see `linux-host/README.md` — run `./run-host.sh`.

**Windows:** see `windows-host/README.md` — double-click `run-host.cmd`.

Keep the terminal window open. You should see a **QR code** and a LAN (and maybe Tailscale) URL.

Allow TCP **45678** if the OS firewall asks.

### 2. Connect the phone (same Wi-Fi, or Tailscale)

**Android (recommended):** install `android/NexusLink-Android.apk` (see `android/README.md`), open the app, scan the QR or pick the discovered PC.

**Any phone browser / iOS:** open `http://<pc-ip>:45678` and pair when asked.

Phone and PC must reach each other. Guest Wi-Fi that isolates clients will fail; use the same LAN or Tailscale.

### 3. Pair

The first connection asks you to confirm a pairing code on the PC or in the app. After that, the session stays until you revoke it.

---

## What to try

A structured checklist is in **TEST-PLAN.md**. Short version:

1. Pairing and reconnect after locking the phone.
2. Agent chat (Cursor CLI, Claude Code, Antigravity, OpenCode) if those tools are installed on the PC.
3. Terminal: type a command, see output.
4. Files: browse the home folder, open a text file.
5. Mirror / app windows (Linux X11 and Windows). On macOS, mirroring is still limited.

---

## Privacy and safety

- The host binds on the local network. Do not port-forward **45678** to the public internet.
- Testers should use a spare account or a machine they are comfortable sharing with a lab phone.
- Agent tools can run commands and edit files **on the PC** after you approve them.

---

## Support snapshot

| Platform | Agents | Screen / apps | Terminal & files |
| --- | :---: | :---: | :---: |
| Windows host | Yes | Yes | Yes |
| Linux X11 host | Yes | Yes (needs `ffmpeg`, `xdotool`, `wmctrl`) | Yes |
| macOS | Yes (run from source; not in this kit) | Limited | Yes |
| Android app | Client | Client | Client |
| iOS Safari PWA | Client | Client | Client |
