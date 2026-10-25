import Foundation

/// Runs scrcpy-server (Apache-2.0, github.com/Genymobile/scrcpy) on the device and
/// talks to it over ADB local-abstract sockets: optional H.264 video + control.
/// Requires Android 5.0+ (API 21).
public final class ScrcpySession: @unchecked Sendable {
    public static let version = "5.0.1"
    static let remoteJar = "/data/local/tmp/adbremote-scrcpy-\(version).jar"

    public struct VideoOptions: Sendable {
        public var maxSize: Int
        public var bitRate: Int
        public var maxFps: Int

        public init(maxSize: Int = 1280, bitRate: Int = 4_000_000, maxFps: Int = 30) {
            self.maxSize = maxSize
            self.bitRate = bitRate
            self.maxFps = maxFps
        }
    }

    public let video: AdbStream?
    public let control: AdbStream
    private let server: AdbStream
    private let adb: AdbConnection
    private let scid: String
    private let sendLock = AsyncLock()

    private init(adb: AdbConnection, scid: String, server: AdbStream, video: AdbStream?, control: AdbStream) {
        self.adb = adb
        self.scid = scid
        self.server = server
        self.video = video
        self.control = control
    }

    /// Pushes the server if needed, starts it and connects its sockets.
    public static func start(adb: AdbConnection, serverJar: Data, video: VideoOptions? = nil) async throws -> ScrcpySession {
        let existing = try await adb.sync { try await $0.stat(remoteJar) }
        if existing?.size != UInt64(serverJar.count) {
            try await adb.sync { try await $0.push(serverJar, to: remoteJar) }
        }

        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
        var args = [
            "scid=\(scid)",
            "log_level=info",
            "tunnel_forward=true",
            "audio=false",
            "control=true",
            "cleanup=true",
            "power_on=false",
            "clipboard_autosync=false",
            "send_device_meta=false",
        ]
        if let video {
            args += ["video=true", "video_codec=h264", "max_size=\(video.maxSize)",
                     "video_bit_rate=\(video.bitRate)", "max_fps=\(video.maxFps)"]
        } else {
            args.append("video=false")
        }
        let command = "CLASSPATH=\(remoteJar) app_process / com.genymobile.scrcpy.Server \(version) " + args.joined(separator: " ")
        // The server lives as long as this shell stream stays open.
        let server = try await adb.open("shell:" + command)

        let socket = "localabstract:scrcpy_" + scid
        do {
            let first = try await connectWithRetry(adb, socket, server: server)
            // Forward tunnels get one dummy byte on the first socket.
            _ = try await first.readExactly(1)
            if video != nil {
                let control = try await adb.open(socket)
                return ScrcpySession(adb: adb, scid: scid, server: server, video: first, control: control)
            }
            return ScrcpySession(adb: adb, scid: scid, server: server, video: nil, control: first)
        } catch {
            let output = (try? await withTimeout(0.5, "server output") { try await server.read() }).flatMap { $0 }
            server.close()
            kill(adb, scid)
            if let output, !output.isEmpty {
                throw AdbError.command("scrcpy-server failed: \(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            throw error
        }
    }

    private static func connectWithRetry(_ adb: AdbConnection, _ socket: String, server: AdbStream) async throws -> AdbStream {
        let deadline = Date().addingTimeInterval(8)
        while true {
            do {
                return try await adb.open(socket)
            } catch AdbError.openFailed {
                if server.isClosed { throw AdbError.command("scrcpy-server exited") }
                if Date() > deadline { throw AdbError.timeout("scrcpy-server start") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    public var isClosed: Bool { control.isClosed || server.isClosed }

    public func close() {
        video?.close()
        control.close()
        server.close()
        Self.kill(adb, scid)
    }

    /// Closing the sockets normally ends the server, but a server that missed it would keep
    /// encoding and sending video, clogging the whole ADB connection. Make sure it is gone.
    /// "[x]" keeps the pattern from matching this kill command itself.
    private static func kill(_ adb: AdbConnection, _ scid: String) {
        guard !adb.isClosed else { return }
        let pattern = "scid=[\(scid.prefix(1))]\(scid.dropFirst())"
        Task { _ = try? await adb.run("pkill -f '\(pattern)' || true") }
    }

    // MARK: Control messages

    private func send(_ data: Data) async throws {
        try await sendLock.withLock { try await control.write(data) }
    }

    public func injectKey(_ action: KeyAction, keycode: Int32, metaState: UInt32 = 0, repeatCount: UInt32 = 0) async throws {
        var d = Data([0, action.rawValue])
        d.appendBE(UInt32(bitPattern: keycode))
        d.appendBE(repeatCount)
        d.appendBE(metaState)
        try await send(d)
    }

    public func injectText(_ text: String) async throws {
        // Server limit is 300 bytes per message.
        var chunk = ""
        for ch in text {
            if chunk.utf8.count + String(ch).utf8.count > 300 {
                try await sendText(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { try await sendText(chunk) }
    }

    private func sendText(_ text: String) async throws {
        let bytes = Data(text.utf8)
        var d = Data([1])
        d.appendBE(UInt32(bytes.count))
        d.append(bytes)
        try await send(d)
    }

    /// Sets the device clipboard, optionally pasting it (handles any Unicode text).
    public func setClipboard(_ text: String, paste: Bool) async throws {
        let bytes = Data(text.utf8)
        var d = Data([9])
        d.append(Data(count: 8)) // sequence (u64); 0 = no acknowledgement wanted
        d.append(paste ? 1 : 0)
        d.appendBE(UInt32(bytes.count))
        d.append(bytes)
        try await send(d)
    }

    /// Touch in device pixel coordinates within a `width`x`height` frame.
    public func injectTouch(_ action: TouchAction, pointerId: UInt64 = 0, x: Int32, y: Int32,
                            width: UInt16, height: UInt16, pressure: Float = 1) async throws {
        var d = Data([2, action.rawValue])
        d.appendBE(UInt32(pointerId >> 32))
        d.appendBE(UInt32(pointerId & 0xffff_ffff))
        d.appendBE(UInt32(bitPattern: x))
        d.appendBE(UInt32(bitPattern: y))
        d.appendBE16(width)
        d.appendBE16(height)
        d.appendBE16(action == .up ? 0 : UInt16(min(max(pressure, 0), 1) * 0xffff))
        // Finger touch: no mouse buttons (non-zero makes Android treat it as a mouse).
        d.appendBE(UInt32(0)) // action button
        d.appendBE(UInt32(0)) // buttons
        try await send(d)
    }

    public func injectScroll(x: Int32, y: Int32, width: UInt16, height: UInt16, horizontal: Float, vertical: Float) async throws {
        func fixed(_ v: Float) -> UInt16 {
            let n = min(max(v / 16, -1), 1)
            return UInt16(bitPattern: Int16(max(min(n * 32768, 32767), -32768)))
        }
        var d = Data([3])
        d.appendBE(UInt32(bitPattern: x))
        d.appendBE(UInt32(bitPattern: y))
        d.appendBE16(width)
        d.appendBE16(height)
        d.appendBE16(fixed(horizontal))
        d.appendBE16(fixed(vertical))
        d.appendBE(UInt32(0))
        try await send(d)
    }

    public func setDisplayPower(_ on: Bool) async throws {
        try await send(Data([10, on ? 1 : 0]))
    }

    // MARK: Virtual mouse (UHID)

    /// scrcpy's HID mouse: 5 buttons, relative X/Y, wheel and horizontal pan (app/src/hid/hid_mouse.c).
    private static let mouseDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    ]

    /// Adds a virtual USB mouse to the device; Android then shows its own pointer.
    public func createMouse(id: UInt16) async throws {
        var d = Data([12])
        d.appendBE16(id)
        d.appendBE16(0) // vendor
        d.appendBE16(0) // product
        let name = Data("ADB Remote Trackpad".utf8)
        d.append(UInt8(name.count))
        d.append(name)
        d.appendBE16(UInt16(Self.mouseDescriptor.count))
        d.append(contentsOf: Self.mouseDescriptor)
        try await send(d)
    }

    /// One mouse report: buttons bit 0 = left, 1 = right, 2 = middle; motion is relative.
    public func mouseReport(id: UInt16, buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8 = 0, pan: Int8 = 0) async throws {
        var d = Data([13])
        d.appendBE16(id)
        d.appendBE16(5)
        d.append(contentsOf: [buttons, UInt8(bitPattern: dx), UInt8(bitPattern: dy),
                              UInt8(bitPattern: wheel), UInt8(bitPattern: pan)])
        try await send(d)
    }

    public func destroyMouse(id: UInt16) async throws {
        var d = Data([14])
        d.appendBE16(id)
        try await send(d)
    }
}

public enum KeyAction: UInt8, Sendable {
    case down = 0
    case up = 1
}

public enum TouchAction: UInt8, Sendable {
    case down = 0
    case up = 1
    case move = 2
}

extension Data {
    mutating func appendBE16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
