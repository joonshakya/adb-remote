# Third-party notices

ADB Remote includes or depends on the following software. Thank you to their authors.

## Shipped to the TV

| Component | Where | License |
| --- | --- | --- |
| [scrcpy-server](https://github.com/Genymobile/scrcpy) 5.0.1. © 2018 Genymobile, © 2018–2026 Romain Vimont | `App/Resources/scrcpy-server-v5.0.1` (official release asset, SHA-256 `764eb6f7…bc536`) | Apache-2.0 |
| playfair (FairPlay setup for AirPlay), from [UxPlay](https://github.com/FDH2/UxPlay) / [RPiPlay](https://github.com/FD-/RPiPlay) | `AndroidViewer/jni/playfair/` | GPL-3.0 (see `LICENSE.md` there) |
| ALAC decoder. © 2005 David Hammerton | `AndroidViewer/jni/alac/` | MIT |
| [TweetNaCl](https://tweetnacl.cr.yp.to) by Daniel J. Bernstein et al. | `AndroidViewer/jni/tweetnacl.c` | Public domain |
| [ExoPlayer](https://github.com/google/ExoPlayer) 2.19.1 (core, HLS, …) | `AndroidViewer/libs/` | Apache-2.0 |
| [Guava](https://github.com/google/guava) 31.1-android, failureaccess | `AndroidViewer/libs/` | Apache-2.0 |
| AndroidX Annotation 1.3.0 | `AndroidViewer/libs/` | Apache-2.0 |

The AirPlay receiver in `AndroidViewer/src/.../airplay/` is our own Java code. Its
protocol handling follows UxPlay (GPL-3.0).

## In the phone apps

| Component | Used by | License |
| --- | --- | --- |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) (includes BoringSSL) | AdbKit: TLS, RSA, SPAKE2 | Apache-2.0; BoringSSL: OpenSSL / ISC / MIT terms (see the package) |
| [swift-nio](https://github.com/apple/swift-nio), swift-atomics, swift-collections, swift-system | AdbKit (through swift-nio-ssl) | Apache-2.0 |
| zlib (system library) | AdbKit: unpacking app bundles | zlib license |
| Swift standard library and Foundation (statically linked into the Android app) | Android app | Apache-2.0 with Runtime Library Exception |
| ICU data (part of Foundation) | Android app | Unicode License v3 |
| AndroidX, Jetpack Compose, Material 3, Kotlin standard library | Android app | Apache-2.0 |

## Documentation

The stock photos in `docs/screenshots` come from [Lorem Picsum](https://picsum.photos)
(Unsplash licence).
