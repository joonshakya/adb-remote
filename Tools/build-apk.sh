#!/bin/zsh
# Bumps the Android app's version, builds a release APK (signed with the local debug key,
# for sideloading) and writes dist/AdbRemote-android-<version>.apk.
#   Tools/build-apk.sh          0.1 -> 0.2
#   Tools/build-apk.sh 1.0      sets the version to 1.0
set -euo pipefail

ROOT=${0:A:h:h}
APP=$ROOT/AndroidRemote
GRADLE=$APP/app/build.gradle.kts
DIST=$ROOT/dist

current=$(grep -m1 'versionName = ' $GRADLE | sed -E 's/.*"(.*)".*/\1/')
code=$(grep -m1 'versionCode = ' $GRADLE | sed -E 's/[^0-9]*([0-9]+).*/\1/')
if [[ $# -ge 1 ]]; then
  version=$1
else
  major=${current%%.*}
  minor=${current#*.}
  minor=${minor%%.*}
  version="$major.$((minor + 1))"
fi
code=$((code + 1))
sed -i '' -E "s/versionName = \".*\"/versionName = \"$version\"/; s/versionCode = [0-9]+/versionCode = $code/" $GRADLE
echo "Building $version ($code)"

export JAVA_HOME=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}
(cd $APP && ./gradlew -q assembleRelease)
mkdir -p $DIST
cp $APP/app/build/outputs/apk/release/app-release.apk $DIST/AdbRemote-android-$version.apk
ls -la $DIST/AdbRemote-android-$version.apk
