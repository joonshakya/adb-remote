import Foundation

/// Talks to the "Photos from iPhone" viewer app on the TV (AndroidViewer/), the part shared by
/// the iOS and Android apps: installs and opens it over ADB, connects to it directly over Wi-Fi
/// (or through ADB if that fails), sends photos and video commands and reports its events.
///
/// Protocol: lines of text, some followed by bytes. Phone: HELLO, PHOTO id size + JPEG, SHOW id,
/// VIDEO id size mime, DATA request size + bytes, PAUSE, RESUME, SEEK ms, ZOOM id scale u v,
/// CLEAR, CLOSE. TV: VIEWER 1 sdk long short hevc, READY/SHOWN/PERR/PLAYING/ENDED id,
/// VERR id why, TIME id ms ms playing, READ id request offset length.
public final class ViewerClient: @unchecked Sendable {
    public struct TV: Sendable, Equatable {
        public var sdk = 0
        public var longSide = 1920
        public var hevc = false
    }

    public enum Event: Sendable {
        case ready(Int)
        case shown(Int)
        case photoFailed(Int)
        case playing(Int)
        case ended(Int)
        case videoFailed(Int, String)
        /// Video position and length (seconds), and whether it is playing.
        case time(Int, position: Double, duration: Double, playing: Bool)
        /// The TV wants `length` bytes at `offset` of video `id`; answer with `sendData(request:_:)`.
        case read(Int, request: Int, offset: UInt64, length: Int)
        /// The connection ended.
        case closed
    }

    public static let package = "local.adbremote.viewer"
    public static let port: UInt16 = 38790
    /// Must match android:versionCode in AndroidViewer/AndroidManifest.xml.
    public static let viewerVersion = 20

    public let tv: TV
    /// Wi-Fi (fast) or through ADB (works everywhere, slower on old TVs).
    public let direct: Bool

    private let link: ViewerLink
    private let outbox: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false

    private init(link: ViewerLink, direct: Bool, tv: TV, outbox: AsyncStream<Data>.Continuation) {
        self.link = link
        self.direct = direct
        self.tv = tv
        self.outbox = outbox
    }

    // MARK: Connect

    /// Installs (if needed) and opens the viewer, then connects to it.
    /// `status` reports steps ("Installing the TV app (one time)", ...); `onEvent` gets the TV's
    /// messages on a background task until `.closed`.
    public static func connect(adb: AdbConnection, host: String, sdk: Int, apk: URL, helperJar: Data,
                               status: @escaping @Sendable (String) -> Void = { _ in },
                               onEvent: @escaping @Sendable (Event) -> Void) async throws -> ViewerClient {
        status("Checking the TV app")
        try await installIfNeeded(adb: adb, sdk: sdk, apk: apk, helperJar: helperJar) {
            status("Installing the TV app (one time)")
        }
        status("Opening on the TV")
        _ = try await adb.shell("am start -n \(package)/.ViewerActivity")
        status("Connecting")
        // The app needs a moment to start listening.
        var lastError: Error = AdbError.timeout("viewer")
        for attempt in 0..<12 {
            do {
                let (link, direct) = try await openLink(adb: adb, host: host, port: port, preferDirect: attempt < 8)
                return try await attach(link, direct: direct, onEvent: onEvent)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError
    }

    /// Installs or updates the TV app if the device has an older one (or none).
    public static func installIfNeeded(adb: AdbConnection, sdk: Int, apk: URL, helperJar: Data,
                                       installing: () -> Void = {}) async throws {
        let info = try await adb.shell("dumpsys package \(package) | grep versionCode").output
        let installed = info.split(separator: " ").compactMap { part -> Int? in
            guard part.hasPrefix("versionCode=") else { return nil }
            return Int(part.dropFirst("versionCode=".count))
        }.first
        if let installed, installed >= viewerVersion { return }
        installing()
        try await AppManager(adb: adb, sdk: sdk, helperJar: helperJar).install([apk])
    }

    /// Opens a connection to one of the TV app's ports: Wi-Fi first, then through ADB.
    static func openLink(adb: AdbConnection, host: String, port: UInt16, preferDirect: Bool) async throws -> (ViewerLink, direct: Bool) {
        if preferDirect {
            let tcp = TCPTransport(host: host, port: port)
            if (try? await tcp.start(timeout: 2)) != nil { return (TCPLink(tcp), true) }
            tcp.close()
        }
        return (try await adb.open("tcp:\(port)"), false)
    }

    private static func attach(_ link: ViewerLink, direct: Bool, onEvent: @escaping @Sendable (Event) -> Void) async throws -> ViewerClient {
        // HELLO -> "VIEWER 1 sdk long short hevc"
        try await link.write(Data("HELLO\n".utf8))
        // Reads can't be cancelled, so a timer closes the link instead.
        let timer = Task {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            link.close()
        }
        defer { timer.cancel() }
        var buffer = Data()
        var hello = ""
        while true {
            guard let chunk = try await link.read() else { throw AdbError.closed }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 10) {
                hello = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                break
            }
        }
        let fields = hello.split(separator: " ")
        guard fields.first == "VIEWER", fields.count >= 6 else {
            link.close()
            throw AdbError.command("Unexpected answer from the TV app")
        }
        let tv = TV(sdk: Int(fields[2]) ?? 0, longSide: Int(fields[3]) ?? 1920, hevc: fields[5] == "1")

        let (stream, outbox) = AsyncStream.makeStream(of: Data.self)
        let client = ViewerClient(link: link, direct: direct, tv: tv, outbox: outbox)
        // One writer keeps messages whole and in order.
        Task.detached {
            for await data in stream {
                do { try await link.write(data) } catch { break }
            }
            // Finished (disconnect/close) once everything queued was written.
            link.close()
        }
        let leftover = buffer
        Task.detached { await client.readLoop(leftover: leftover, onEvent: onEvent) }
        return client
    }

    private func readLoop(leftover: Data, onEvent: @escaping @Sendable (Event) -> Void) async {
        var buffer = leftover
        while true {
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let event = Self.parse(line) { onEvent(event) }
            }
            guard let chunk = try? await link.read() else { break }
            buffer.append(chunk)
        }
        disconnect()
        onEvent(.closed)
    }

    static func parse(_ line: String) -> Event? {
        let f = line.split(separator: " ").map(String.init)
        guard let name = f.first, f.count > 1, let id = Int(f[1]) else { return nil }
        switch name {
        case "READY": return .ready(id)
        case "SHOWN": return .shown(id)
        case "PERR": return .photoFailed(id)
        case "PLAYING": return .playing(id)
        case "ENDED": return .ended(id)
        case "VERR": return .videoFailed(id, f.count > 2 ? f[2] : "")
        case "TIME":
            guard f.count >= 5, let position = Double(f[2]), let duration = Double(f[3]) else { return nil }
            return .time(id, position: position / 1000, duration: duration / 1000, playing: f[4] == "1")
        case "READ":
            guard f.count >= 5, let request = Int(f[2]), let offset = UInt64(f[3]), let length = Int(f[4]) else { return nil }
            return .read(id, request: request, offset: offset, length: length)
        default: return nil
        }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// Drops the connection (the viewer stays open on the TV).
    public func disconnect() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        link.close()
        outbox.finish()
    }

    // MARK: Commands

    private func send(_ line: String, _ payload: Data? = nil) {
        var data = Data((line + "\n").utf8)
        if let payload { data.append(payload) }
        outbox.yield(data)
    }

    /// Sends a photo; the TV answers READY when it can be shown.
    public func sendPhoto(id: Int, jpeg: Data) { send("PHOTO \(id) \(jpeg.count)", jpeg) }
    public func show(id: Int) { send("SHOW \(id)") }
    public func pause() { send("PAUSE") }
    public func resume() { send("RESUME") }
    public func seek(to seconds: Double) { send("SEEK \(Int(max(0, seconds) * 1000))") }
    public func clear() { send("CLEAR") }

    /// Zooms what's on the TV: `scale` 1 = whole picture; (u, v) = picture point (0...1) to center.
    public func zoom(id: Int, scale: Double, u: Double, v: Double) {
        send(String(format: "ZOOM %d %.3f %.4f %.4f", id, scale, u, v))
    }

    /// Starts playback on the TV right away; it asks for the bytes with `.read` events as it plays.
    public func playVideo(id: Int, size: Int, mime: String = "video/mp4") {
        send("VIDEO \(id) \(size) \(mime)")
    }

    /// Answers a `.read` event (empty data = not available).
    public func sendData(request: Int, _ data: Data) {
        send("DATA \(request) \(data.count)", data)
    }

    /// Closes the viewer so the TV goes back to the app it was showing before, then hangs up.
    public func closeViewer() {
        send("CLOSE")
        // The writer still delivers CLOSE, then hangs up.
        lock.withLock { closed = true }
        outbox.finish()
    }
}

// MARK: Links

/// A byte pipe to the viewer: a direct TCP connection or an ADB "tcp:" stream.
protocol ViewerLink: AnyObject, Sendable {
    func write(_ data: Data) async throws
    func read() async throws -> Data?
    func close()
}

extension AdbStream: ViewerLink {
    func read() async throws -> Data? { try await read(max: .max) }
}

private final class TCPLink: ViewerLink, @unchecked Sendable {
    private let tcp: TCPTransport

    init(_ tcp: TCPTransport) { self.tcp = tcp }

    func write(_ data: Data) async throws { try await tcp.send(data) }

    func read() async throws -> Data? {
        do {
            return try await tcp.receive(max: 65536)
        } catch AdbError.closed {
            return nil
        }
    }

    func close() { tcp.close() }
}
