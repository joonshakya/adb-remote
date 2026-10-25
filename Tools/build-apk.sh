#!/bin/sh
# Builds a release APK of the Android app and writes dist/AdbRemote-android-<version>.apk.
#   Tools/build-apk.sh          bumps the version: 0.1 -> 0.2
#   Tools/build-apk.sh 1.0      sets the version to 1.0 (as the release workflow does)
# Signed with the release key when ADBREMOTE_KEYSTORE (and its passwords) are set,
# otherwise with the local debug key. Works on macOS and Linux.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$ROOT/AndroidRemote
GRADLE=$APP/app/build.gradle.kts
DIST=$ROOT/dist

current=$(grep -m1 'versionName = ' "$GRADLE" | sed -E 's/.*"(.*)".*/\1/')
code=$(grep -m1 'versionCode = ' "$GRADLE" | sed -E 's/[^0-9]*([0-9]+).*/\1/')
if [ $# -ge 1 ]; then
  version=$1
  # A version always gets the same code, increasing with it: 1.2.3 -> 10203.
  major=$(echo "$version" | cut -d. -f1)
  minor=$(echo "$version" | cut -s -d. -f2)
  patch=$(echo "$version" | cut -s -d. -f3)
  code=$(( ${major:-0} * 10000 + ${minor:-0} * 100 + ${patch:-0} ))
else
  major=${current%%.*}
  minor=${current#*.}
  minor=${minor%%.*}
  version="$major.$((minor + 1))"
  code=$((code + 1))
fi
# perl rather than sed -i: the same command works with macOS and GNU tools.
perl -pi -e "s/versionName = \".*\"/versionName = \"$version\"/; s/versionCode = [0-9]+/versionCode = $code/" "$GRADLE"
echo "Building $version ($code)"

if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
(cd "$APP" && ./gradlew -q assembleRelease)
mkdir -p "$DIST"
cp "$APP/app/build/outputs/apk/release/app-release.apk" "$DIST/AdbRemote-android-$version.apk"
ls -la "$DIST/AdbRemote-android-$version.apk"
