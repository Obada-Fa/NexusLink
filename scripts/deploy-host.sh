#!/usr/bin/env bash
# Deploy the NexusLink Linux host into its own frozen copy, then restart the service.
# The service no longer runs out of the development checkout, so half-finished edits
# (by you or an agent) can never take the PC host down on its next restart.
#
#   scripts/deploy-host.sh                 # deploy the current working tree
#   scripts/deploy-host.sh stable          # deploy any git ref (branch, tag, commit) — e.g. roll back
#   scripts/deploy-host.sh --no-restart    # stage + verify only
#   scripts/deploy-host.sh --with-web      # build and include the browser client
#   scripts/deploy-host.sh --rollback      # switch back to the previous release
#   scripts/deploy-host.sh --now           # restart at once even inside a Nexus agent turn
#
# Run from a Nexus agent turn (NEXUSLINK_AGENT_TURN=1, set by the host on every
# agent process), an immediate restart would kill that very turn. The release is
# staged and verified as usual, then a separate systemd job restarts the host once
# no agent turn is running (the host keeps the count in busy-turns.json), still
# rolling back if the new host does not come up.
#
# Releases live in ~/.local/share/nexuslink-host/releases/<stamp>; `current` points at the live one.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${NEXUSLINK_RUNTIME_DIR:-$HOME/.local/share/nexuslink-host}"
LAUNCHER="${NEXUSLINK_LAUNCHER:-$HOME/.local/bin/nexuslink}"
BUN="${BUN:-$(command -v bun || echo "$HOME/.nvm/versions/node/v24.15.0/bin/bun")}"
REF=""
RESTART=1
ROLLBACK=0
WITH_WEB=0
NOW=0
MARKER="${NEXUSLINK_DATA_DIR:-$HOME/.cache/nexuslink}/busy-turns.json"

restart_and_wait() {
  systemctl --user restart nexuslink.service
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  # Startup can wait up to 2 min for Tailscale at boot; normally it's listening in ~10 s.
  for _ in $(seq 1 75); do
    sleep 2
    if journalctl --user -u nexuslink.service --since "$since" --no-pager 2>/dev/null | grep -q '\[rpc-server\] listening on'; then
      return 0
    fi
    systemctl --user is-active --quiet nexuslink.service || true
  done
  return 1
}

# Restart into the release `current` points at; on failure go back to $1 (a
# release dir, or empty for the development checkout, or "-" for no rollback).
restart_or_rollback() {
  local previous="$1" label="$2"
  if restart_and_wait; then
    echo "NexusLink host restarted from $label and is listening."
    return 0
  fi
  if [[ "$previous" == "-" ]]; then
    echo "Host did not report listening; check: journalctl --user -u nexuslink.service -n 50" >&2
    return 1
  fi
  echo "Host did not come up; rolling back." >&2
  if [[ -n "$previous" && -d "$previous" ]]; then ln -sfn "$previous" "$BASE/current"; else sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=\"$REPO\"|" "$LAUNCHER"; fi
  restart_and_wait && echo "Rolled back; host is listening again." || echo "Rollback restart also failed: journalctl --user -u nexuslink.service -n 80" >&2
  return 1
}

# Idle when the marker is missing, its host process is gone, or it counts 0 turns.
host_idle() {
  [[ -f "$MARKER" ]] || return 0
  local text busy pid
  text="$(cat "$MARKER" 2>/dev/null || true)"
  busy="$(grep -o '"busy":[0-9]*' <<<"$text" | cut -d: -f2)"
  pid="$(grep -o '"pid":[0-9]*' <<<"$text" | cut -d: -f2)"
  [[ -z "$pid" ]] && return 0
  kill -0 "$pid" 2>/dev/null || return 0
  [[ "${busy:-0}" -eq 0 ]]
}

# Internal: the deferred job started by defer_restart.
if [[ "${1:-}" == "--restart-when-idle" ]]; then
  previous="${2:-}" label="${3:-release}"
  idle=0 deadline=$((SECONDS + ${NEXUSLINK_DEFER_MAX_SECONDS:-1800}))
  while (( SECONDS < deadline )); do
    if host_idle; then idle=$((idle + 1)); (( idle >= 3 )) && break; else idle=0; fi
    sleep "${NEXUSLINK_DEFER_POLL_SECONDS:-2}"
  done
  (( idle >= 3 )) || echo "Agent turns still running after the wait limit; restarting anyway."
  restart_or_rollback "$previous" "$label"
  exit $?
fi

# Hand the restart to a job outside the host's service so it outlives the restart.
defer_restart() {
  local previous="$1" label="$2" unit
  unit="nexuslink-deferred-restart-$(date +%Y%m%d-%H%M%S)"
  systemctl --user stop 'nexuslink-deferred-restart-*' 2>/dev/null || true
  local env=()
  [[ -n "${NEXUSLINK_DATA_DIR:-}" ]] && env+=(--setenv=NEXUSLINK_DATA_DIR="$NEXUSLINK_DATA_DIR")
  [[ -n "${NEXUSLINK_RUNTIME_DIR:-}" ]] && env+=(--setenv=NEXUSLINK_RUNTIME_DIR="$NEXUSLINK_RUNTIME_DIR")
  [[ -n "${NEXUSLINK_LAUNCHER:-}" ]] && env+=(--setenv=NEXUSLINK_LAUNCHER="$NEXUSLINK_LAUNCHER")
  systemd-run --user --quiet --collect --unit="$unit" "${env[@]}" \
    /bin/bash "$REPO/scripts/deploy-host.sh" --restart-when-idle "$previous" "$label"
  [[ -f "$MARKER" ]] || echo "Note: the running host does not report its agent turns (older build), so it restarts right away."
  echo "This deploy runs inside a Nexus agent turn, so the host restarts once no agent turn is running"
  echo "(this one included), and rolls back if it does not come up. Follow it: journalctl --user -u $unit"
}

for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=0 ;;
    --now) NOW=1 ;;
    --rollback) ROLLBACK=1 ;;
    --with-web) WITH_WEB=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) REF="$arg" ;;
  esac
done

if [[ $WITH_WEB -eq 1 && ( -n "$REF" || $ROLLBACK -eq 1 ) ]]; then
  echo "--with-web builds the current checkout; use it without a git ref or --rollback." >&2
  exit 2
fi

# Build before staging or switching the release. A failed web build leaves the
# running host untouched and cannot silently deploy an older export.
if [[ $WITH_WEB -eq 1 ]]; then
  "$BUN" run --cwd "$REPO/apps/mobile-client" build
  [[ -s "$REPO/apps/mobile-client/out/index.html" ]] || { echo "Web build produced no index.html; not deployed." >&2; exit 1; }
fi

mkdir -p "$BASE/releases"

if [[ $ROLLBACK -eq 1 ]]; then
  current="$(readlink -f "$BASE/current" || true)"
  previous="$(ls -1d "$BASE"/releases/* | grep -v -F "$current" | sort | tail -1 || true)"
  [[ -n "$previous" ]] || { echo "No previous release to roll back to." >&2; exit 1; }
  ln -sfn "$previous" "$BASE/current"
  echo "Rolled back to $(cat "$previous/DEPLOYED_FROM" 2>/dev/null || basename "$previous")"
  if [[ $RESTART -eq 1 ]]; then
    if [[ -n "${NEXUSLINK_AGENT_TURN:-}" && $NOW -eq 0 ]]; then defer_restart - "the rolled-back release"
    else restart_or_rollback - "the rolled-back release" || true; fi
  fi
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BASE/releases/$STAMP"
PATHS=(apps/desktop/src/server apps/desktop/package.json packages/chat-core packages/rpc-types)
mkdir -p "$DEST"
if [[ -z "$REF" ]]; then
  for p in "${PATHS[@]}"; do
    mkdir -p "$DEST/$(dirname "$p")"
    rsync -a --exclude '__tests__' --exclude '*.test.ts' --exclude 'node_modules' "$REPO/$p" "$DEST/$(dirname "$p")/"
  done
  dirty="$(git -C "$REPO" status --porcelain -- "${PATHS[@]}" | wc -l)"
  LABEL="working tree on $(git -C "$REPO" rev-parse --abbrev-ref HEAD)@$(git -C "$REPO" rev-parse --short HEAD) (+$dirty changed files)"
else
  git -C "$REPO" archive "$REF" -- "${PATHS[@]}" | tar -x -C "$DEST"
  LABEL="$REF ($(git -C "$REPO" rev-parse --short "$REF"))"
fi
# The only third-party runtime dependency; everything else is Bun/Node built-ins.
mkdir -p "$DEST/apps/desktop/node_modules"
cp -aL "$REPO/apps/desktop/node_modules/qrcode-terminal" "$DEST/apps/desktop/node_modules/"
echo "$LABEL" > "$DEST/DEPLOYED_FROM"

# Freeze web assets with the backend. Keep an enabled web client on subsequent
# host-only updates; --with-web explicitly rebuilds it from the checkout.
WEB_SOURCE="$(readlink -f "$BASE/current" 2>/dev/null || true)/apps/mobile-client/out"
if [[ $WITH_WEB -eq 1 ]]; then WEB_SOURCE="$REPO/apps/mobile-client/out"; fi
if [[ -s "$WEB_SOURCE/index.html" ]]; then
  mkdir -p "$DEST/apps/mobile-client"
  cp -a "$WEB_SOURCE" "$DEST/apps/mobile-client/out"
  echo "Browser client included from $WEB_SOURCE"
fi

# Verify every import resolves and parses before switching.
if ! "$BUN" build "$DEST/apps/desktop/src/server/index.ts" --target=bun --outdir "$DEST/.verify" >/dev/null 2>"$DEST/verify.log"; then
  echo "Release failed verification; not deployed. See $DEST/verify.log" >&2
  cat "$DEST/verify.log" >&2
  exit 1
fi
rm -rf "$DEST/.verify"

PREVIOUS="$(readlink -f "$BASE/current" 2>/dev/null || true)"
ln -sfn "$DEST" "$BASE/current"

# Point the service launcher at the frozen copy (once; a backup is kept).
if [[ -f "$LAUNCHER" ]] && ! grep -q 'nexuslink-host/current' "$LAUNCHER"; then
  cp "$LAUNCHER" "$LAUNCHER.bak.$STAMP"
  sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=\"\${NEXUSLINK_PROJECT_DIR:-$BASE/current}\"|" "$LAUNCHER"
fi

# Keep the five newest releases plus whatever is live.
ls -1d "$BASE"/releases/* | sort | head -n -5 | while read -r old; do
  [[ "$(readlink -f "$BASE/current")" == "$old" || "$old" == "$PREVIOUS" ]] || rm -rf "$old"
done

echo "Staged release $STAMP from $LABEL"
if [[ $RESTART -eq 0 ]]; then exit 0; fi
if [[ -n "${NEXUSLINK_AGENT_TURN:-}" && $NOW -eq 0 ]]; then
  defer_restart "$PREVIOUS" "$STAMP"
  exit 0
fi
restart_or_rollback "$PREVIOUS" "$STAMP"
