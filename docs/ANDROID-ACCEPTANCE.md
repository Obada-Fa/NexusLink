# Android/Linux acceptance walkthrough

Record the phone model, Android version, Flutter/Bun versions, host commit, Tailscale route/RTT, and actual results for each item. Automated checks alone do not mark this complete.

- [ ] Pair using the PC's eight-digit code; restart both sides and reconnect using the saved MagicDNS name and a Tailscale IP. Verify invalid/expired/revoked credentials and Tailscale-only startup failure.
- [ ] Land on Agents after connection. Create, continue, cancel, archive, and approve tasks on each installed provider; verify missing CLIs are explained. Test two simultaneous approvals and provider failures after partial output.
- [ ] Open both the root terminal and a task terminal. Verify the first prompt, `pwd`, Unicode, Ctrl+C, paste, resize, full-screen programs, navigation away/back, reconnect replay without duplicates, exit, and host restart.
- [ ] Browse a very large folder, a hidden folder, broken symlink, and a permission error. Open one file from Files and from a task link; confirm they share a buffer. Edit CRLF/BOM and no-final-newline files, preserve executable mode, recover a draft after process death, and reject a remote revision conflict.
- [ ] Review staged, unstaged, untracked, renamed, deleted, and binary Git changes. Label them working-tree changes; do not attribute them to an agent.
- [ ] Download empty, small, and 100 MiB files to Android Downloads/NexusLink. Keep the app backgrounded and screen off; kill the app process; reopen and verify transfer status. Test duplicate names, cancellation, retry, expired auth, changed remote file during resume, 401/403/404/500, and full storage. Download must never open Share automatically.
- [ ] On Android 9 or earlier, deny public Downloads storage permission. Verify the explicit **Save as…** document-picker action can still save the file and that a failed transfer leaves no completed-looking document.
- [ ] Upload from a document-provider URI without a local path. Verify no-overwrite default, explicit replacement, and no final file after a failed stream.
- [ ] Enable live activity with notifications allowed and denied. Test approval, failure, completion, reconnect catch-up, notification tap, cold-launch deep link, overlay allowed/denied/revoked, lock screen, force-stop, and Stop live activity leaving PC work running.
- [ ] Confirm CPU and RAM units, stale/offline display, disk free space, and no desktop-window polling, capture process, hidden terminal, or continuous animation during normal agent use.
- [ ] Profile 100 tasks, a 1 MiB document, a 100 MiB transfer, navigation frame budget, terminal echo latency against network RTT, and repeated tab/reconnect cycles for timer/socket/shell growth.
- [ ] Check the signing certificate against an already distributed APK before offering an upgrade; perform a backup and upgrade test without losing drafts or host settings.
