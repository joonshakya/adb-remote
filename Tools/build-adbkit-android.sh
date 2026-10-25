#!/bin/sh
# Builds AdbKit (and adbkit-cli) for Android with the Swift SDK for Android.
# Needs (once): the open-source Swift toolchain matching the SDK, installed with
#   swiftly install 6.4.1
#   swift sdk install <swift-6.4.1-RELEASE_android.artifactbundle.tar.gz URL> --checksum ...
# and Android NDK r30 (sdkmanager "ndk;30.0.16248370"). See swift.org "Swift SDK for Android".
# Usage: Tools/build-adbkit-android.sh [aarch64|x86_64|armv7] [debug|release]
set -eu
cd "$(dirname "$0")/../AdbKit"
ARCH="${1:-aarch64}"
CONFIG="${2:-debug}"
SWIFT_VERSION=6.4.1
SWIFT="$HOME/Library/Developer/Toolchains/swift-$SWIFT_VERSION-RELEASE.xctoolchain/usr/bin/swift"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/30.* | tail -n 1)}"
case "$ARCH" in
    armv7) TRIPLE=armv7-unknown-linux-androideabi28 ;;
    *) TRIPLE=$ARCH-unknown-linux-android28 ;;
esac
"$SWIFT" build --scratch-path .build-android -c "$CONFIG" \
    --swift-sdk "swift-$SWIFT_VERSION-RELEASE_android" --triple "$TRIPLE" --static-swift-stdlib
