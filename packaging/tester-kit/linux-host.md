# Linux host (X11)

This folder is a portable Linux host. Testers do **not** need Git, Node, or Bun.

## Requirements

- 64-bit Linux with **X11** (Wayland-only sessions often fail for screen grab and input).
- Same Wi-Fi as the phone, **or** Tailscale on both devices.
- Optional but needed for mirroring and window control:

```bash
# Debian / Ubuntu
sudo apt install ffmpeg xdotool wmctrl x11-xserver-utils

# Fedora
sudo dnf install ffmpeg xdotool wmctrl xrandr
```

## Run

```bash
chmod +x run-host.sh nexuslink-host   # once, if the zip stripped bits
./run-host.sh
```

Leave the window open. Scan the QR from the Android app, or open the printed `http://…:45678` URL on the phone.

To stop: `Ctrl+C` in that terminal.

## Firewall

If the phone cannot connect:

```bash
sudo ufw allow 45678/tcp
# or, firewalld:
sudo firewall-cmd --add-port=45678/tcp
```

## Layout

| File | Role |
| --- | --- |
| `run-host.sh` | Sets `NEXUSLINK_STATIC_DIR` and starts the host |
| `nexuslink-host` | Compiled Bun server (RPC + PWA on port 45678) |
| `www/` | Phone web UI served to browsers and used as fallback |
