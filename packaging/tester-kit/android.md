# Android app

Install **`NexusLink-Android.apk`** on a physical Android phone or tablet (Android 8+, **64-bit ARM**). It will not install on x86 emulators.

## Install

1. Copy the APK to the phone (USB, Drive, or AirDrop-style share).
2. Open the file. If Android blocks it, allow install from that source (Files / Chrome / Drive).
3. Open **nexuslink**. Allow local-network / notifications if asked.

This build is **not** from Play Store, so the OS will show an unknown-source prompt. That is expected.

## Connect

1. PC host must already be running (`linux-host` or `windows-host`).
2. Phone and PC on the same LAN **or** both on Tailscale.
3. Scan the host QR, or wait for mDNS discovery, or type `http://<pc-ip>:45678`.

## If it will not install

- Uninstall any older `com.nexuslink.nexuslink` build first.
- Enable **Install unknown apps** for the app you used to open the APK.

## iPhone instead?

Do not install this APK. On the PC host URL in **Safari**, use **Share → Add to Home Screen**.
