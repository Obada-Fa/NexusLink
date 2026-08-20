# Tester checklist

Copy this into notes. Mark pass / fail / skipped. Attach screenshots or a short screen recording for failures.

**Build:** tester kit dated from the zip you received  
**PC OS:** Windows / Linux (distro + X11 or Wayland)  
**Phone:** Android app / iOS Safari PWA / other browser  
**Network:** same Wi-Fi / Tailscale / other  

---

## A. Host start

- [ ] Host starts without extra installs (aside from Linux packages in `linux-host/README.md`).
- [ ] Terminal shows a QR and an `http://…:45678` URL.
- [ ] Opening that URL **on the PC** shows the NexusLink web UI.

## B. Pairing

- [ ] Phone finds the PC (QR, discovery, or typed URL).
- [ ] Pairing completes; phone home screen loads.
- [ ] Lock the phone for 30s, unlock, app still connected or reconnects cleanly.
- [ ] Kill the app, reopen: session still usable.

## C. Agents (skip if the PC has none installed)

- [ ] Agent list shows tools actually installed (Cursor CLI, Claude Code, Antigravity, OpenCode).
- [ ] Send a trivial prompt (“reply with the word pong”).
- [ ] Streaming tokens appear; final answer is readable.
- [ ] A tool call that needs approval shows a prompt; Approve and Deny both work.

## D. Terminal

- [ ] Open a terminal, run `echo nexuslink-ok` (or `Write-Output nexuslink-ok` on Windows).
- [ ] Output appears. Resize the panel; shell still accepts input.

## E. Files

- [ ] Browse home / Documents.
- [ ] Open a small text file.
- [ ] (Optional) Upload or download one file.

## F. Desktop / apps (Linux X11 and Windows)

- [ ] Window or app list is not empty.
- [ ] Launch or adopt one app; phone shows a usable view.
- [ ] Tap / scroll on the phone moves or scrolls the host (or the virtual session).

## G. Negative cases (useful)

- [ ] Phone on a *different* isolated guest Wi-Fi: connection fails clearly (not a hang).
- [ ] Host stopped: phone shows disconnected, not a frozen spinner.

---

## Notes

Write what broke, OS versions, and whether Tailscale was used.
