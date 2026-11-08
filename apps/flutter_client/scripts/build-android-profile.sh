#!/usr/bin/env bash
# Builds a profile APK for judging real performance on a phone. Debug APKs run
# far slower than the shipped app. Calls Gradle through bash because shared
# filesystems can't execute the wrapper, which rules out `flutter build`.
set -euo pipefail
cd "$(dirname "$0")/../android"
bash gradlew :app:assembleProfile -Ptarget-platform=android-arm64 --console=plain
cd ..
VERSION="$(sed -n 's/^version: //p' pubspec.yaml)"
OUT="build/app/outputs/flutter-apk"
cp "$OUT/app-profile.apk" "$OUT/nexuslink-test-$VERSION-profile.apk"
echo "$OUT/nexuslink-test-$VERSION-profile.apk"
