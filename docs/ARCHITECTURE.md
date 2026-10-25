# Architecture

ADB Remote is three apps that work together, plus one engine they all share:

```
 ┌──────────────┐   ┌──────────────────┐
 │  iOS app     │   │  Android app     │      phones
 │  SwiftUI     │   │  Kotlin/Compose  │
 └──────┬───────┘   └────────┬─────────┘
        │ Swift              │ JNI (JSON calls)
        ▼                    ▼
 ┌─────────────────────────────────────┐
 │  AdbKit (Swift)                     │      shared engine
 │  ADB protocol · TLS pairing · sync  │
 │  scrcpy · apps · TV viewer client   │
 │  links · trackpad                   │
 └──────────────────┬──────────────────┘
                    │ ADB over Wi-Fi (TCP 5555 or Wireless debugging)
                    ▼
 ┌─────────────────────────────────────┐
 │  Android TV / any Android device    │
 │  adbd                               │
 │  ├─ scrcpy-server (control, video)  │      started over ADB
 │  ├─ adbremote-helper.jar            │      started over ADB
 │  └─ TV app "Photos from iPhone"     │      installed over ADB
 │      viewer · AirPlay · mirroring   │
 └─────────────────────────────────────┘
```

The phone does everything over ADB, the same protocol `adb` on a computer uses. There is
no server, account or cloud service. Nothing needs to be installed on the TV by hand: the
helper programs are pushed and started over ADB when a feature first needs them.

## Folders

| Folder | What it is | Language |
| --- | --- | --- |
| `AdbKit/` | The shared engine: a Swift package used by both phone apps | Swift + C |
| `App/` | iOS app (SwiftUI) and its "Send to TV" share extension | Swift |
| `AndroidRemote/` | Android app (Compose) and the bridge that loads AdbKit | Kotlin + Swift |
| `AndroidViewer/` | TV app: photo/video viewer, pointer, AirPlay receiver, phone mirroring | Java + C |
| `AndroidHelper/` | `adbremote-helper.jar`, run on the TV with `app_process` | Java |
| `Tools/` | Build scripts (versioned IPA/APK), icon generators | Shell / Swift |
| `docs/` | This documentation | |

## AdbKit: the shared engine

AdbKit is written once and used by both phone apps:

- `AdbConnection`, `AdbMessage`, `AdbStream`, `Transport`: the ADB wire protocol. Streams
  are multiplexed over one TCP connection. The phone's RSA key is used for `AUTH`, and TLS
  1.3 is used when the device asks for it (Android 11+ Wireless debugging).
- `AdbPairing`: pairing with a 6-digit code (SPAKE2 + AES-GCM, as in Android's `adb pair`).
- `CAdbCrypto`: a thin C layer over the BoringSSL copy that ships with swift-nio-ssl. It
  covers RSA keys, the TLS client, SPAKE2 and SHA-256.
- `CAdbZlib`: raw DEFLATE, for unpacking `.apks`/`.xapk` bundles.
- `Shell`, `Sync`: shell commands (v2 with exit codes when available) and file transfer.
- `AppManager`: lists apps with labels and icons (through the helper jar), and launches,
  stops, uninstalls, installs (including split APKs) and extracts them.
- `Scrcpy`, `ScrcpyVideo`, `RemoteInput`: keys, text, touch and a virtual mouse through
  scrcpy's control channel on Android 5+, and the live screen as H.264. On Android 4.x,
  keys go through the helper jar's injector instead.
- `ViewerClient`: talks to the TV app's viewer (photos, videos, zoom). See [PROTOCOLS](PROTOCOLS.md).
- `LinkOpener`: opens YouTube links in whichever YouTube app the TV has, and other links in
  its browser.
- `PointerSender`: trackpad motion. It uses a virtual mouse where Android allows one, and
  otherwise a pointer the TV app draws.
- `DeviceInfo`, `DeviceCapabilities`, `PortScanner`: device details, what works on it,
  speed test, and finding the ADB port.

Apple-only APIs are kept behind `#if canImport(...)`: Network.framework is used for sockets
on iOS and plain POSIX sockets on Android. The same sources build for iOS, macOS and
Android.

## The Android app and the bridge

`AndroidRemote/bridge` is a small Swift package that builds `libAdbBridge.so`. It contains
AdbKit plus:

- `jni.c`: the only JNI function, `Native.call(request: String, input: ByteArray?)`.
- `Bridge.swift`: decodes the JSON request, runs it on Swift's thread pool while the Kotlin
  thread waits, and returns `[4-byte JSON length][JSON][binary payload]`. Live objects
  (connections, remotes, screens) are kept in a table and referred to by number.
- `Ops.swift`: one `case` per operation (`connect`, `shell`, `appsList`, `screenNext`,
  `castPhoto`, `pointerMove`, …).

On the Kotlin side, `bridge/Adb.kt` turns each call into a cancellable coroutine. It polls
`progress` for long operations such as port scans and installs, and sends `cancel` when
the coroutine is cancelled. `bridge/AdbKit.kt` wraps the operations in small classes
(`AdbConnection`, `RemoteInput`, `AppManager`, `ScreenSession`, `ViewerClient`,
`PointerSender`).

To add a feature to both apps:

1. Write it in AdbKit.
2. Add a `case` to `Ops.swift`.
3. Add a Kotlin wrapper in `bridge/AdbKit.kt`.
4. Build the UI in each app.

## The TV app (`AndroidViewer`, package `local.adbremote.viewer`)

The phone installs it over ADB the first time it's needed, and updates it when the phone
carries a newer version (`ViewerClient.viewerVersion` must match `versionCode`). It runs on
Android 4.1 and newer.

| Part | Port | Purpose |
| --- | --- | --- |
| `ViewerActivity` + `VideoProxy` | 38790 | Photos (crossfade, zoom), videos streamed from the phone |
| `PointerService` | 38791 | Draws a pointer for TVs without a virtual mouse |
| `airplay.AirPlayService` | 7000, 7100 | AirPlay receiver: iPhone screen mirroring, audio, video URLs (YouTube) |
| `airplay.PhoneMirror` | 7200 | Screen + sound mirroring from the Android app |

The phone reaches these ports directly over Wi-Fi when it can. Otherwise it goes through
ADB's `tcp:` service, which works even when the device is behind NAT (emulators) or a
firewall.

Mirrored video is drawn by the TV's hardware decoder. Where the GPU supports it, it passes
through `YuvRenderer`, which does its own colour conversion so greys aren't crushed on TVs
that misread full-range video.

## The helper jar (`AndroidHelper`)

`adbremote-helper.jar` is run as the shell user with
`app_process / local.adbremote.helper.Main <command>`:

- `list`: app labels, versions and launch activities (faster and more complete than `pm`).
- `icons`: app icons as PNG.
- `input`: a long-running key injector for Android 4.x, where `input keyevent` takes 1–2 s
  per key.

## Third-party pieces on the device

- **scrcpy-server 5.0.1** (Apache-2.0) is pushed to `/data/local/tmp`. It is used for
  control (keys, text, touch, mouse) and the live screen.
- See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for everything else.
