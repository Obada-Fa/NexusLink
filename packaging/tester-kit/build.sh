#!/usr/bin/env bash
# Build a shareable tester kit: Linux host, Windows host, Android APK, docs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${DEST:-$HOME/Desktop/NexusLink-Tester-Kit}"
FLUTTER="${FLUTTER:-$HOME/flutter/bin/flutter}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$HOME/.bun/bin:$PATH"

cd "$ROOT"

echo "==> Installing workspace deps"
bun install

echo "==> Building phone PWA"
bun run --cwd apps/mobile-client build
PWA_OUT="$ROOT/apps/mobile-client/out"
if [[ ! -f "$PWA_OUT/index.html" ]]; then
  echo "PWA export missing at $PWA_OUT" >&2
  exit 1
fi

LINUX_OUT="$ROOT/dist/linux"
WIN_OUT="$ROOT/dist/windows"
mkdir -p "$LINUX_OUT" "$WIN_OUT"

echo "==> Compiling Linux host"
bun build --compile --outfile "$LINUX_OUT/nexuslink-host" \
  apps/desktop/src/server/index.ts apps/desktop/src/server/workspace/agent-store-worker.ts packages/chat-core/src/worker.ts packages/chat-core/src/providers/worker.ts

echo "==> Compiling Windows host (cross)"
bun build --compile --target=bun-windows-x64 --outfile "$WIN_OUT/nexuslink-host.exe" \
  apps/windows-host/src/server/index.ts apps/desktop/src/server/workspace/agent-store-worker.ts packages/chat-core/src/worker.ts packages/chat-core/src/providers/worker.ts

APK_SRC=""
if [[ -x "$FLUTTER" ]]; then
  echo "==> Building Android APK"
  (
    cd apps/flutter_client
    "$FLUTTER" pub get
    # arm64-only: smaller, and fat APK Gradle can OOM on 8GB machines
    "$FLUTTER" build apk --release --target-platform android-arm64
  )
  APK_SRC="$ROOT/apps/flutter_client/build/app/outputs/flutter-apk/app-release.apk"
else
  echo "!! Flutter not found at $FLUTTER — skipping APK" >&2
fi

echo "==> Assembling kit at $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/linux-host/www" "$DEST/windows-host/www" "$DEST/android"

cp "$LINUX_OUT/nexuslink-host" "$DEST/linux-host/nexuslink-host"
chmod +x "$DEST/linux-host/nexuslink-host"
cp -a "$PWA_OUT/." "$DEST/linux-host/www/"

cp "$WIN_OUT/nexuslink-host.exe" "$DEST/windows-host/nexuslink-host.exe"
cp -a "$PWA_OUT/." "$DEST/windows-host/www/"

if [[ -n "$APK_SRC" && -f "$APK_SRC" ]]; then
  cp "$APK_SRC" "$DEST/android/NexusLink-Android.apk"
fi

cat > "$DEST/linux-host/run-host.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
export NEXUSLINK_STATIC_DIR="$HERE/www"
echo "NexusLink Linux host"
echo "Keep this window open. Scan the QR from your phone (same Wi-Fi or Tailscale)."
echo
exec ./nexuslink-host
EOF
chmod +x "$DEST/linux-host/run-host.sh"

cat > "$DEST/windows-host/run-host.cmd" << 'EOF'
@echo off
cd /d "%~dp0"
set NEXUSLINK_STATIC_DIR=%~dp0www
echo NexusLink Windows host
echo Keep this window open. Scan the QR from your phone (same Wi-Fi or Tailscale).
echo.
nexuslink-host.exe
pause
EOF

cp "$ROOT/packaging/tester-kit/README.md" "$DEST/README.md"
cp "$ROOT/packaging/tester-kit/TEST-PLAN.md" "$DEST/TEST-PLAN.md"
cp "$ROOT/packaging/tester-kit/linux-host.md" "$DEST/linux-host/README.md"
cp "$ROOT/packaging/tester-kit/windows-host.md" "$DEST/windows-host/README.md"
cp "$ROOT/packaging/tester-kit/android.md" "$DEST/android/README.md"

ZIP="$HOME/Desktop/NexusLink-Tester-Kit.zip"
echo "==> Zipping $ZIP"
rm -f "$ZIP"
(cd "$(dirname "$DEST")" && zip -r -q "$ZIP" "$(basename "$DEST")")

echo
echo "Kit ready:"
echo "  $DEST"
echo "  $ZIP"
find "$DEST" -maxdepth 3 -type f | sort
