#!/bin/sh
# Builds adbremote-helper.jar (dex inside a jar) for app_process on the device.
# Output is copied into the iOS app's resources.
set -eu
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/36.1.0"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"

rm -rf build
mkdir -p build/classes build/dex
javac -source 8 -target 8 -Xlint:-options -bootclasspath "$ANDROID_JAR" \
    -d build/classes $(find src -name '*.java')
"$BT/d8" --min-api 16 --lib "$ANDROID_JAR" --output build/dex $(find build/classes -name '*.class')
(cd build/dex && zip -q -X ../adbremote-helper.jar classes.dex)
cp build/adbremote-helper.jar ../App/Resources/adbremote-helper.jar
echo "built build/adbremote-helper.jar"
