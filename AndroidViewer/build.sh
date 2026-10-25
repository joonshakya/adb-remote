#!/bin/sh
# Builds the TV viewer APK ("Photos from iPhone") without Gradle and copies it into
# the iOS app's resources. Signed with the local debug key.
set -eu
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/36.1.0"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"

rm -rf build
mkdir -p build/classes build/dex
"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link --manifest AndroidManifest.xml -I "$ANDROID_JAR" -R build/res.zip --auto-add-overlay \
    --min-sdk-version 16 --target-sdk-version 33 -o build/unsigned.apk
# ExoPlayer 2.19 (Apache-2.0, last version for Android 4.x) plays AirPlay videos; libs/ holds
# its jars and Guava's. R8 drops what we don't use (ExoPlayer's rules come from its AARs).
LIBS=$(ls libs/*.jar | tr '\n' ':')
javac -source 8 -target 8 -Xlint:-options -bootclasspath "$ANDROID_JAR" -cp "$LIBS" \
    -d build/classes $(find src -name '*.java')
(cd build/classes && zip -q -r ../app.jar .)
java -cp "$BT/lib/d8.jar" com.android.tools.r8.R8 --release --min-api 16 --lib "$ANDROID_JAR" \
    --pg-conf libs/app-rules.pro --pg-conf libs/exoplayer-rules.pro \
    --output build/dex build/app.jar libs/*.jar
(cd build/dex && zip -q -X ../unsigned.apk classes.dex)

# AirPlay receiver native code. NDK r27 targets API 21 at the lowest; the library only
# uses libc functions Android 4.4 has, so it loads there too.
NDK_BIN=$(ls -d "$SDK"/ndk/*/toolchains/llvm/prebuilt/*/bin | tail -n 1)
for target in armeabi-v7a:armv7a-linux-androideabi21 arm64-v8a:aarch64-linux-android21 x86_64:x86_64-linux-android21; do
    abi=${target%%:*}
    mkdir -p build/lib/$abi
    "$NDK_BIN/${target#*:}-clang" -shared -fPIC -O2 -Wno-everything -Wl,-z,max-page-size=16384 \
        -o build/lib/$abi/libairplay.so jni/airplay_jni.c jni/tweetnacl.c jni/playfair/*.c jni/alac/alac.c -lm
done
(cd build && zip -q -X -r unsigned.apk lib)
"$BT/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk
"$BT/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android \
    --key-pass pass:android --ks-key-alias androiddebugkey --out build/viewer.apk build/aligned.apk
cp build/viewer.apk ../App/Resources/adbremote-viewer.apk
echo "built build/viewer.apk"
