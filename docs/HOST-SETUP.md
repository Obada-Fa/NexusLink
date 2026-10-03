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
