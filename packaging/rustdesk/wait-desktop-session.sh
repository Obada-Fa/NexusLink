#!/bin/sh
# ExecStartPre for rustdesk.service: hold RustDesk back until the autologin
# desktop is really up, so its --server binds to the user's X display instead
# of a transient one (observed: DISPLAY=:1 "cannot open display" until a manual
# `systemctl restart rustdesk`). Never fails: RustDesk still starts after the
# timeouts, and the NexusLink host watchdog repairs a bad bind later.
USER_NAME="${1:-obada}"
UID_NUM="$(id -u "$USER_NAME" 2>/dev/null || echo 1000)"

user_x_socket() {
  for socket in /tmp/.X11-unix/X*; do
    [ -S "$socket" ] && [ "$(stat -c %u "$socket")" = "$UID_NUM" ] && return 0
  done
  return 1
}

i=0
while [ "$i" -lt 150 ]; do
  if pgrep -u "$UID_NUM" -x gnome-shell >/dev/null 2>&1 \
     && user_x_socket \
     && [ -e "/run/user/$UID_NUM/gdm/Xauthority" ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

# The rendezvous server needs DNS; at boot it is often not ready yet.
i=0
while [ "$i" -lt 45 ]; do
  getent hosts rs-ny.rustdesk.com >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

# Let gnome-shell finish mapping its outputs before RustDesk probes displays.
sleep 4
exit 0
