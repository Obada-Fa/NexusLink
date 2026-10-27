#!/usr/bin/env bash
# Deploy the NexusLink Linux host into its own frozen copy, then restart the service.
# The service no longer runs out of the development checkout, so half-finished edits
# (by you or an agent) can never take the PC host down on its next restart.
#
#   scripts/deploy-host.sh                 # deploy the current working tree
#   scripts/deploy-host.sh stable          # deploy any git ref (branch, tag, commit) — e.g. roll back
#   scripts/deploy-host.sh --no-restart    # stage + verify only
#   scripts/deploy-host.sh --rollback      # switch back to the previous release
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
for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=0 ;;
    --rollback) ROLLBACK=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) REF="$arg" ;;
  esac
done

mkdir -p "$BASE/releases"

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

if [[ $ROLLBACK -eq 1 ]]; then
  current="$(readlink -f "$BASE/current" || true)"
  previous="$(ls -1d "$BASE"/releases/* | grep -v -F "$current" | sort | tail -1 || true)"
  [[ -n "$previous" ]] || { echo "No previous release to roll back to." >&2; exit 1; }
  ln -sfn "$previous" "$BASE/current"
  echo "Rolled back to $(cat "$previous/DEPLOYED_FROM" 2>/dev/null || basename "$previous")"
  [[ $RESTART -eq 1 ]] && { restart_and_wait && echo "Host is listening." || echo "Host did not report listening; check: journalctl --user -u nexuslink.service -n 50"; }
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
if restart_and_wait; then
  echo "NexusLink host restarted from $STAMP and is listening."
else
  echo "Host did not come up; rolling back." >&2
  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then ln -sfn "$PREVIOUS" "$BASE/current"; else sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=\"$REPO\"|" "$LAUNCHER"; fi
  restart_and_wait && echo "Rolled back; host is listening again." || echo "Rollback restart also failed: journalctl --user -u nexuslink.service -n 80" >&2
  exit 1
fi
