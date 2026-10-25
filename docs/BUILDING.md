# Building

Everything builds on a Mac. Built copies of the TV-side pieces are checked in under
`App/Resources/` (`adbremote-viewer.apk`, `adbremote-helper.jar`,
`scrcpy-server-v5.0.1`), so you only need to rebuild those when you change them. Both
phone apps bundle the same files.

## iOS app

Requirements: Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
cd App
xcodegen                      # creates AdbRemote.xcodeproj from project.yml
open AdbRemote.xcodeproj
```

Before running on a device:
- Pick your own team.
- Change the bundle identifiers (`local.adbremote.app`, `local.adbremote.app.sendtotv`) and
  the app group (`group.local.adbremote`) in `project.yml`.

The app supports iOS 17 and newer. It also runs inside LiveContainer: its ADB key and
device list are stored in files, not the keychain, so they survive there.

**Release IPA for sideloading:**

```sh
Tools/build-ipa.sh            # bumps the version (0.9 → 0.10), writes dist/AdbRemote-<version>.ipa
Tools/build-ipa.sh 1.0        # or set the version
```

The IPA is ad-hoc signed. Install it with AltStore, SideStore, LiveContainer or your
own signing.

## Android app

The Android app uses the same Swift engine as the iOS app, so it needs the Swift SDK for
Android in addition to the usual Android tools.

One-time setup:

1. **Android SDK** with platform 36, build-tools 36.1.0, and **NDK r30**:
   ```sh
   sdkmanager "platforms;android-36" "build-tools;36.1.0" "ndk;30.0.16248370"
   ```
2. **Swift 6.4.1**, the open-source toolchain (Xcode's Swift can't build for Android), via
   [swiftly](https://www.swift.org/install/macos/):
   ```sh
   swiftly install 6.4.1
   ```
   The build scripts call it by its full path (`~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain`),
   so it doesn't have to be your default `swift`.
3. **Swift SDK for Android**: see swift.org's
   [Getting started](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html).
   ```sh
   ~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain/usr/bin/swift sdk install \
     https://download.swift.org/swift-6.4.1-release/android-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_android.artifactbundle.tar.gz \
     --checksum a356b79f8f1daa6ae3a66f4c556966ca20c0208b3659805cf30a83a0a31d6772
   ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/30.0.16248370 \
     sh ~/Library/org.swift.swiftpm/swift-sdks/swift-6.4.1-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
   ```

Build:

```sh
cd AndroidRemote
./gradlew assembleDebug       # runs bridge/build.sh first (Swift → libAdbBridge.so)
```

**Versioned release APK** (signed with your debug key, for sideloading):

```sh
Tools/build-apk.sh            # bumps versionName/versionCode, writes dist/AdbRemote-android-<version>.apk
```

Notes:
- `bridge/build.sh` builds arm64-v8a, the ABI of nearly every current phone. To add
  another ABI, add it to the loop in the script and to `abiFilters` in `app/build.gradle.kts`.
- `libAdbBridge.so` is about 60 MB uncompressed, mostly Foundation's Unicode data. The
  release APK is about 31 MB.
- The app needs Android 10 (API 29) or newer.

You can also build AdbKit on its own for Android (it includes a command-line tool):
`Tools/build-adbkit-android.sh [aarch64|x86_64] [debug|release]`.

## TV app (`AndroidViewer`)

```sh
AndroidViewer/build.sh        # javac + R8 + NDK; copies the APK to App/Resources/adbremote-viewer.apk
```

It needs the Android SDK (platform 36, build-tools 36.1.0) and an NDK. Gradle isn't used.
The native library (pairing, FairPlay, ALAC) is built for armeabi-v7a, arm64-v8a and
x86_64, and still loads on Android 4.4.

**When you change it:**
- Raise `android:versionCode` in `AndroidViewer/AndroidManifest.xml`.
- Raise `ViewerClient.viewerVersion` in `AdbKit/Sources/AdbKit/ViewerClient.swift` to
  match. Phones then reinstall the TV app the next time it's used.

## Helper jar (`AndroidHelper`)

```sh
AndroidHelper/build.sh        # copies to App/Resources/adbremote-helper.jar
```

## AdbKit command-line tool

Handy for trying AdbKit against a device from the Mac. It uses the Mac's `~/.android/adbkey`,
so devices that already trust `adb` accept it.

```sh
cd AdbKit && swift build
.build/debug/adbkit-cli 192.168.1.20:5555 info
.build/debug/adbkit-cli 192.168.1.20:5555 shell getprop ro.product.model
.build/debug/adbkit-cli 192.168.1.20:5555 scan
.build/debug/adbkit-cli 192.168.1.20:37000 pair 123456
```

## Screenshots

The screenshots in `docs/screenshots` come from an Android TV emulator, so no real
device, name or address appears in them.

1. **Demo TV.** Create an Android TV emulator (`system-images;android-33;android-tv;arm64-v8a`)
   and start it with `-port 5554` so its ADB listens on 127.0.0.1:5555.
2. **iOS.**
   - Make the TV reachable under a name. Keep this running:
     ```sh
     dns-sd -P "Living Room TV" _adb-demo._tcp local 5555 living-room-tv.local 127.0.0.1
     ```
   - Add photos to the simulator: `xcrun simctl addmedia <sim> *.jpg`.
   - Run the screenshot test:
     ```sh
     cd App
     TEST_RUNNER_SCREENSHOT_DIR=$PWD/../docs/screenshots/ios xcodebuild test \
       -scheme AdbRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
       -only-testing:AdbRemoteUITests/Screenshots/testReadmeScreenshots
     ```
3. **Android.** Run a phone emulator on another port (`-port 5580`). Redirect a made-up
   address to the Mac, then add "Living Room TV" at 192.168.1.20 in the app:
   ```sh
   adb -s emulator-5580 root
   adb -s emulator-5580 shell iptables -t nat -A OUTPUT -d 192.168.1.20 -p tcp -j DNAT --to-destination 10.0.2.2
   ```
4. **Clean status bars.**
   - iOS: `xcrun simctl status_bar <sim> override --time 9:41`
   - Android: SystemUI demo mode, `am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0941`

The stock photos are from [Lorem Picsum](https://picsum.photos) (Unsplash licence).
