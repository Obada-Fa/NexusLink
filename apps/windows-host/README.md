# @nexuslink/windows-host

Windows PC host for NexusLink. Separate from the Linux/X11 host in `apps/desktop`.
Same phone RPC on `:45678`.

## Start (this PC)

```bash
bun run windows          # from repo root — builds the PWA then starts this host
cd apps/windows-host && bun run start
```

Scan the LAN or Tailscale QR. Folder pickers treat `/` as **This PC** (`C:/`, `D:/`, …).

## Installer (other PCs)

Friends should not need Bun or a git clone:

```powershell
./packaging/windows/build.ps1
```

That compiles `nexuslink-host.exe`, embeds the PWA, and (if NSIS is installed) writes `dist/NexusLink-Host-Setup.exe`. Tag `v*` on GitHub to run the same path in CI.

Authenticode: set `NEXUSLINK_PFX` and run `packaging/windows/sign.ps1`. IddCx driver catalogs need Microsoft attestation signing (see `native/iddcx/README.md`).

## What works

- Pairing (tokens persisted in `%APPDATA%\NexusLink`), mDNS, QR, PWA on one port
- Files with This PC / drive letters
- Agents, clipboard, process list
- Terminal (PowerShell; ConPTY when `conpty-host.exe` is built)
- Physical desktop mirror (GDI capture + SendInput)
- Window list, Start Menu / known-app launch
- Phone-shaped browser sessions (`appSession.create`) via a sized Edge/Chrome window
- Tray icon, firewall rule for TCP 45678

## Native extras

| Piece | Path |
|---|---|
| Win32 capture / input / windows | `src/server/native/` |
| ConPTY helper | `native/conpty-host.cpp` |
| Rust sidecar (optional) | `sidecar/` |
| IddCx virtual monitor | `native/iddcx/` |
