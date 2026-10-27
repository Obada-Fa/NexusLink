# Linux host setup

NexusLink's preferred route is a Tailscale address or MagicDNS name. Install and sign in to Tailscale on the PC and phone, verify the PC has an IPv4 address with `tailscale ip -4`, then start `bun run host` from the checkout. A Tailscale-only start fails if that interface/address is missing; it never widens the listener to all interfaces. Save the PC's address once in the phone's connection screen. Pair with `bun run host:pair` on the PC.

The `host` script starts Bun's TypeScript server directly. It does not build or serve the PWA unless an exported PWA already exists. The coding paths do not need a GUI session. Python 3's `pty`, `fcntl`, and `termios` modules must be present for terminals; if absent, capabilities report terminals unavailable. Agents require their installed CLIs and their own login configuration. `bun run host:devices` and `bun run host:revoke <id>` manage pairings locally.

For a user service, copy [nexuslink-host.service](../packaging/systemd/nexuslink-host.service) to `~/.config/systemd/user/nexuslink-host.service`. Edit its `WorkingDirectory` to the absolute checkout path and verify Bun is on the service user's `PATH`. Then run:

```bash
systemctl --user daemon-reload
systemctl --user enable --now nexuslink-host.service
journalctl --user -u nexuslink-host.service -f
```

`systemctl --user status nexuslink-host.service` shows startup failures. If Tailscale is unavailable, restore it with `tailscale status` / `sudo tailscale up`, then `systemctl --user restart nexuslink-host.service`. The service restarts with backoff. Run `loginctl enable-linger "$USER"` only if you explicitly want the service running while logged out. A host restart ends all PTY shells; the Android app reports ended sessions and will not replay old commands.

Use `bun run host:lan` only for a deliberate local-network setup. Discovery is manual. The plain listener rejects public and unknown peer addresses; it does not provide TLS itself. Remote access outside Tailscale or a trusted local network needs a TLS reverse proxy terminating onto loopback. Do not expose the Bun port directly to the public internet. If you change the saved PC address after pairing, pair the phone again; credentials are deliberately bound to the saved address until verified host-key migration exists.

## Deploying and rolling back the host

The user service should not run straight out of a development checkout: an unfinished edit would take the host down at its next restart. `bash scripts/deploy-host.sh` copies just the host code into `~/.local/share/nexuslink-host/releases/<stamp>`, verifies that every import resolves, points `~/.local/share/nexuslink-host/current` at it, rewrites `~/.local/bin/nexuslink` once (a backup is kept) and restarts `nexuslink.service`. If the host does not report `listening` within about two minutes, the previous release is restored automatically.

```bash
bash scripts/deploy-host.sh              # deploy the current working tree
bash scripts/deploy-host.sh stable       # deploy a git ref, e.g. the saved stable version
bash scripts/deploy-host.sh --rollback   # return to the previous release
```

The host binds only to the PC's Tailscale address (`NEXUSLINK_TAILSCALE_ONLY=1`). At boot it waits up to two minutes for Tailscale to obtain an address, then exits with an error so systemd retries; it never stays alive without a listener.

## RustDesk at boot

On some boots `rustdesk.service` starts before the autologin desktop exists and binds its screen server to a transient display. RustDesk then refuses connections until it is restarted. Run once:

```bash
sudo bash packaging/rustdesk/install.sh
```

This replaces the service's start-up wait with one that waits for GNOME, the user's X socket and DNS; allows the desktop user (and so NexusLink) to restart `rustdesk.service` without a password; and removes a duplicate Flatpak RustDesk that competes for the same socket and port. The NexusLink host checks RustDesk every 30 seconds and restarts it when it has been unusable for 45 seconds (at most four times in 30 minutes). The phone shows RustDesk health on the PC tab and offers a manual restart.
