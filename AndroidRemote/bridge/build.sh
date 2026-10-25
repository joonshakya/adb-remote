#!/bin/sh
# Builds libAdbBridge.so (AdbKit + the JSON bridge) for the Android app and puts it,
# with the NDK's libc++_shared.so, in out/jniLibs/<abi>/. See Tools/build-adbkit-android.sh
# for the one-time toolchain setup. Usage: build.sh [debug|release]
set -eu
cd "$(dirname "$0")"
CONFIG="${1:-release}"
SWIFT_VERSION=6.4.1
# The open-source toolchain (Xcode's Swift can't target Android): on a Mac from swiftly's
# toolchain folder, elsewhere (CI on Linux) whatever `swift` is on the PATH, or $SWIFT.
SWIFT="${SWIFT:-$HOME/Library/Developer/Toolchains/swift-$SWIFT_VERSION-RELEASE.xctoolchain/usr/bin/swift}"
[ -x "$SWIFT" ] || SWIFT=swift
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/30.* | tail -n 1)}"
BIN=$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin | head -n 1)
for target in arm64-v8a:aarch64; do
    abi=${target%%:*}
    arch=${target#*:}
    # Swift occasionally reports "No Android NDK is installed" with ANDROID_NDK_HOME set
    # (seen right after Xcode builds); a second attempt has always worked.
    build() {
        "$SWIFT" build -c "$CONFIG" --scratch-path .build-android --swift-sdk "swift-$SWIFT_VERSION-RELEASE_android" \
            --triple "$arch-unknown-linux-android28" --static-swift-stdlib
    }
    build || { echo "retrying the Swift build once"; build; }
    product=$(ls -d .build-android/out/Products/*-android-$arch | grep -i "$CONFIG")
    mkdir -p out/jniLibs/$abi
    "$BIN/llvm-strip" -o out/jniLibs/$abi/libAdbBridge.so "$product/libAdbBridge.so"
    cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/"*/sysroot/usr/lib/$arch-linux-android/libc++_shared.so out/jniLibs/$abi/
done
