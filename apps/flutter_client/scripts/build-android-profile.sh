#!/usr/bin/env bash
# Builds a profile APK for judging real performance on a phone. Debug APKs run
# far slower than the shipped app. Calls Gradle through bash because shared
# filesystems can't execute the wrapper, which rules out `flutter build`.
#
# Signs with the permanent test key from ~/.android/nexuslink-test.env (the
# same key CI uses for test-* releases), so the APK updates an installed
# release. Without that file it would get this machine's debug key instead.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${NEXUSLINK_TEST_ENV:-$HOME/.android/nexuslink-test.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "warning: $ENV_FILE missing; signing with the local debug key" >&2
fi
VERSION="$(sed -n 's/^version: //p' pubspec.yaml)"
# Gradle reads the version from local.properties, which only `flutter build`
# refreshes; write it from pubspec.yaml so the APK never ships a stale code.
sed -i -e "/^flutter.versionName=/d" -e "/^flutter.versionCode=/d" android/local.properties
printf 'flutter.versionName=%s\nflutter.versionCode=%s\n' "${VERSION%%+*}" "${VERSION##*+}" >> android/local.properties
cd android
bash gradlew :app:assembleProfile -Ptarget-platform=android-arm64 --console=plain
cd ..
OUT="build/app/outputs/flutter-apk"
cp "$OUT/app-profile.apk" "$OUT/nexuslink-test-$VERSION-profile.apk"
echo "$OUT/nexuslink-test-$VERSION-profile.apk"
