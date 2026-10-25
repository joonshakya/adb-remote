# Protocols

What travels between the phone and the TV, besides ADB itself.

The phone reaches each TV port in one of two ways:
- **Directly over Wi-Fi.**
- **Through ADB** by opening the ADB service `tcp:<port>` on the existing connection. This
  is the fallback when the port can't be reached directly (NAT, emulators, firewalls).

All the TV-side code is in `AndroidViewer/`. The phone side is in `AdbKit`.

## TV viewer: port 38790

Text lines (UTF-8, `\n`); some are followed by binary data of the stated length. The phone
side is `AdbKit/ViewerClient.swift`; the TV side is `ViewerActivity.java`.

| Phone → TV | TV → phone | Meaning |
| --- | --- | --- |
| `HELLO` | `VIEWER 1 <sdk> <longSide> <shortSide> <hevc 0/1>` | Handshake: Android version, screen size, HEVC decoder |
| `PHOTO <id> <length>` + JPEG | `READY <id>` or `PERR <id>` | Decode and keep a photo (not shown yet) |
| `SHOW <id>` | `SHOWN <id>` | Crossfade to that photo |
| `VIDEO <id> <size> <mime>` | `PLAYING <id>`, `ENDED <id>`, `VERR <id> <why>` | Play a video that stays on the phone |
| | `READ <id> <request> <offset> <length>` | The TV's player needs bytes |
| `DATA <request> <length>` + bytes | | The phone's answer (empty if unavailable) |
| `PAUSE`, `RESUME`, `SEEK <ms>` | `TIME <id> <posMs> <durMs> <playing 0/1>` (twice a second) | Playback control and position |
| `ZOOM <id> <scale> <u> <v>` | | Show the picture at `scale`, centred on picture point (u, v) in 0…1 |
| `CLEAR` | | Back to the waiting screen |
| `CLOSE` | | Close the viewer; the TV returns to the previous app |
| `PING` | `PONG` | |

Videos are played by the TV's own media player from a small local HTTP server (`VideoProxy`). That server
turns the player's range requests into `READ`s, so the TV never has to connect back to the
phone.

## Pointer: port 38791

Used by the trackpad on devices without a virtual mouse (`PointerService.java`):

| Phone → TV | TV → phone |
| --- | --- |
| `SIZE` | `SIZE <width> <height>` (screen pixels, current rotation) |
| `POS <x> <y>` | Moves the drawn pointer's tip |
| `HIDE` | Removes the pointer and stops the service |

The pointer is only drawn by the TV. Clicks, drags and scrolls are sent by the phone as
touch and scroll events at the pointer's position, through scrcpy.

## Android phone mirroring: port 7200

`PhoneMirror.java` on the TV, `MirrorService.kt` on the phone. The stream is one-way, phone
→ TV, and unencrypted:

```
"ADBM" 0x01                                   once
then packets:  type (1 byte) | length (4, big-endian) | time µs (8) | payload
  1  format    width (4) | height (4) | SPS+PPS (Annex-B)   on start and on every size change
  2  picture   H.264 access unit (Annex-B)
  3  key picture
  4  sound     48 kHz stereo 16-bit little-endian PCM (20 ms per packet)
```

The TV shows pictures as they arrive (lowest delay) on the same screen as AirPlay
mirroring. Closing the connection ends mirroring on either side.

## AirPlay receiver: ports 7000 (RTSP/HTTP) and 7100 (mirror video)

`airplay/` in the TV app. It is an interoperable implementation of what iPhones expect from
an Apple TV, following [UxPlay](https://github.com/FDH2/UxPlay):

- **Discovery**: mDNS (`_airplay._tcp`, `_raop._tcp`) by `Mdns.java`. Wi-Fi multicast locks
  are held while the receiver runs.
- **Pairing**: Ed25519 / X25519 (TweetNaCl, through JNI).
- **FairPlay setup**: `playfair` (GPL-3.0, through JNI).
- **Mirroring**: H.264 over port 7100, AES-CTR encrypted.
- **Audio**: AAC-ELD (mirroring) and ALAC (Music), AES-CBC encrypted. AAC-ELD is decoded
  by MediaCodec; ALAC by `alac.c`.
- **Video handed over with AirPlay** (`POST /play`):
  - Ordinary URLs are played directly.
  - YouTube sends `mlhls://` playlists. The TV asks the iPhone for them over the reverse
    event connection and serves them to ExoPlayer from 127.0.0.1.
- **Photos** (`/photo`): shown full screen.

The receiver is started over ADB from the iPhone app with
`am start-foreground-service -n local.adbremote.viewer/.airplay.AirPlayService --es name <TV name>`.
It stops after 10 minutes without use.

## The Android app's bridge to AdbKit

The Kotlin app calls Swift through one JNI function:

```kotlin
Native.call(request: String /* JSON */, input: ByteArray?): ByteArray
// reply: [JSON length: 4 bytes big-endian][JSON][binary payload]
```

- **Requests**: `{"op": "<name>", "request": "<uuid>", …arguments}`.
- **Errors**: come back as `{"error": "…"}` and become `AdbException` in Kotlin.
- **Long calls**: report progress, which Kotlin reads with `{"op": "progress",
  "request": …}`. They stop with `{"op": "cancel", "request": …}`.

Operations (`AndroidRemote/bridge/Sources/AdbBridge/Ops.swift`):

| Area | Operations |
| --- | --- |
| Setup | `init` (load or create the ADB key), `progress`, `cancel` |
| Connection | `connect`, `close`, `waitDisconnect`, `ping`, `shell`, `pair`, `openPorts`, `findAdbPorts` |
| Device | `info`, `extras`, `speedTest`, `screenshot` |
| Remote | `remoteCreate`, `remotePrepare`, `remotePress`, `remoteType`, `remoteMouse`, `remoteRestart`, `remoteClose` |
| Trackpad | `pointerCreate`, `pointerMove`, `pointerScroll`, `pointerButtons`, `pointerClick`, `pointerHide` |
| Apps | `appsCreate`, `appsList`, `appsIcons`, `appsLaunch`, `appsStop`, `appsUninstall`, `appsInstall`, `appsExtract`, `zip` |
| Files | `filesList`, `filesStat`, `filesPull`, `filesPush` |
| Screen | `screenStart`, `screenNext` (one H.264 event per call), `screenTouch`, `screenScroll`, `screenKey`, `screenClose` |
| Viewer | `viewerInstall`, `castConnect`, `castEvents` (waits for the TV's next messages), `castPhoto`, `castShow`, `castVideo`, `castData`, `castPause`, `castResume`, `castSeek`, `castZoom`, `castClear`, `castCloseViewer`, `castDisconnect` |
| Raw streams | `streamOpen`, `streamWrite`, `streamRead`, `streamClose` |
| Links | `openLink` (`kind`: youtube / web / text), `youtubeWatchURL` |
