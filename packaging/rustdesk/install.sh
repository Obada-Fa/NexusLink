#!/usr/bin/env bash
# One-time RustDesk boot fix for the NexusLink PC. Run with sudo:
#   sudo bash packaging/rustdesk/install.sh            # apply, takes effect next boot
#   sudo bash packaging/rustdesk/install.sh --restart  # apply and restart RustDesk now
#   sudo bash packaging/rustdesk/install.sh --keep-flatpak
# What it does:
#   1. Replaces the rustdesk.service drop-in with a sturdier "wait for the desktop" step.
#   2. Lets the desktop user restart rustdesk.service without a password (polkit), so the
#      NexusLink host watchdog and the phone's "Restart RustDesk" button work.
#   3. Removes the duplicate Flatpak RustDesk (1.4.x), which fights the system 1.5.x install
#      over /tmp/RustDesk-<uid>/ipc and port 21118 and has a different ID/config.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0 $*" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-obada}"
RESTART=0
KEEP_FLATPAK=0
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=1 ;;
    --keep-flatpak) KEEP_FLATPAK=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "→ Installing desktop-session wait helper"
install -d -m 755 /usr/local/lib/nexuslink
install -m 755 "$HERE/wait-desktop-session.sh" /usr/local/lib/nexuslink/rustdesk-wait-desktop-session.sh

echo "→ Updating rustdesk.service drop-in"
install -d -m 755 /etc/systemd/system/rustdesk.service.d
if [[ -f /etc/systemd/system/rustdesk.service.d/override.conf ]]; then
  cp /etc/systemd/system/rustdesk.service.d/override.conf \
     "/etc/systemd/system/rustdesk.service.d/override.conf.bak.$(date +%Y%m%d%H%M%S)"
fi
sed "s/@USER@/$TARGET_USER/g" "$HERE/override.conf" > /etc/systemd/system/rustdesk.service.d/override.conf
chmod 644 /etc/systemd/system/rustdesk.service.d/override.conf

echo "→ Allowing $TARGET_USER to restart rustdesk.service (polkit)"
install -d -m 755 /etc/polkit-1/rules.d
sed "s/@USER@/$TARGET_USER/g" "$HERE/50-nexuslink-rustdesk.rules" > /etc/polkit-1/rules.d/50-nexuslink-rustdesk.rules
chmod 644 /etc/polkit-1/rules.d/50-nexuslink-rustdesk.rules

if [[ $KEEP_FLATPAK -eq 0 ]] && command -v flatpak >/dev/null && flatpak info --system com.rustdesk.RustDesk >/dev/null 2>&1; then
  echo "→ Removing duplicate Flatpak RustDesk (system .deb install stays)"
  flatpak uninstall --system -y --noninteractive com.rustdesk.RustDesk || echo "  (flatpak removal failed — remove it from Software later)"
fi

systemctl daemon-reload
systemctl enable rustdesk.service >/dev/null 2>&1 || true

if [[ $RESTART -eq 1 ]]; then
  echo "→ Restarting RustDesk now (active RustDesk sessions will reconnect)"
  systemctl restart rustdesk.service
fi

echo
echo "Done. Check with:  systemctl status rustdesk --no-pager"
echo "The NexusLink app (PC → Remote access) shows RustDesk health and can restart it."
