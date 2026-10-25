import AdbKit
import Foundation
import Network
import Observation

/// Talks to the "Photos from iPhone" viewer app on the TV (AndroidViewer/).
/// Installs and opens it over ADB, then connects to it directly over Wi-Fi
/// (or through ADB if that fails) and sends photos and video bytes.
@MainActor @Observable
final class CastModel {
    enum State: Equatable {
        case idle
        case preparing(String)
        case ready
        case failed(String)
    }

    struct TV: Equatable {
        var sdk = 0
        var longSide = 1920
        var hevc = false
    }

    enum Event {
        case ready(Int)
        case shown(Int)
        case photoFailed(Int)
        case playing(Int)
        case ended(Int)
        case videoFailed(Int, String)
        /// Video position and length (seconds), and whether it is playing.
        case time(Int, position: Double, duration: Double, playing: Bool)
    }

    static let package = ViewerClient.package
    static let port = ViewerClient.port
    static let viewerVersion = ViewerClient.viewerVersion
    static let apk = Bundle.main.url(forResource: "adbremote-viewer", withExtension: "apk")

    private(set) var state: State = .idle
    private(set) var tv = TV()
    /// Wi-Fi (fast) or through ADB (works everywhere, slower on old TVs).
    private(set) var direct = false
    var onEvent: ((Event) -> Void)?
    /// Connection log hook (set by DeviceSession).
    var log: (String) -> Void = { _ in }

    private let adb: AdbConnection
    private let host: String
    private let sdk: Int
    private var link: CastLink?
    private var outbox: AsyncStream<Data>.Continuation?
    private var nextID = 1
    private var video: (id: Int, url: URL)?
    private var connectTask: Task<Bool, Never>?

    init(adb: AdbConnection, host: String, sdk: Int) {
        self.adb = adb
        self.host = host
        self.sdk = sdk
    }

    func newID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: Connect

    /// Makes sure the viewer is installed, open and connected. Safe to call repeatedly.
    @discardableResult
    func prepare() async -> Bool {
        if link != nil, state == .ready { return true }
        if let connectTask { return await connectTask.value }
        let task = Task { await connect() }
        connectTask = task
        let ok = await task.value
        connectTask = nil
        return ok
    }

    private func connect() async -> Bool {
        do {
            state = .preparing("Checking the TV app")
            try await installViewerIfNeeded()
            state = .preparing("Opening on the TV")
            _ = try await adb.shell("am start -n \(Self.package)/.ViewerActivity")
            state = .preparing("Connecting")
            // The app needs a moment to start listening.
            var lastError: Error = AdbError.timeout("viewer")
            for attempt in 0..<12 {
                do {
                    try await attach(try await openLink(preferDirect: attempt < 8))
                    log("cast connected via \(direct ? "Wi-Fi" : "ADB")")
                    state = .ready
                    return true
                } catch {
                    lastError = error
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            throw lastError
        } catch {
            log("cast failed: \(error.localizedDescription)")
            state = .failed("Couldn't open the viewer on the TV: \(error.localizedDescription)")
            return false
        }
    }

    private func installViewerIfNeeded() async throws {
        try await Self.installViewer(adb: adb, sdk: sdk) { [weak self] in
            self?.state = .preparing("Installing the TV app (one time)")
        }
    }

    /// Installs or updates the TV app if the device has an older one (or none).
    static func installViewer(adb: AdbConnection, sdk: Int, installing: () -> Void = {}) async throws {
        let info = try await adb.shell("dumpsys package \(package) | grep versionCode").output
        let installed = info.split(separator: " ").compactMap { part -> Int? in
            guard part.hasPrefix("versionCode=") else { return nil }
            return Int(part.dropFirst("versionCode=".count))
        }.first
        if let installed, installed >= viewerVersion { return }
        guard let apk, let jar = AppsModel.helperJar else {
            throw AdbError.command("The TV app is missing from this build.")
        }
        installing()
        try await AppManager(adb: adb, sdk: sdk, helperJar: jar).install([apk])
    }

    /// Opens a connection to one of the TV app's ports: Wi-Fi first, then through ADB.
    static func openLink(adb: AdbConnection, host: String, port: UInt16, preferDirect: Bool) async throws -> (CastLink, direct: Bool) {
        if preferDirect, let direct = try? await DirectLink.open(host: host, port: port) {
            return (direct, true)
        }
        return (try await adb.open("tcp:\(port)"), false)
    }

    private func openLink(preferDirect: Bool) async throws -> CastLink {
        let (link, direct) = try await Self.openLink(adb: adb, host: host, port: Self.port, preferDirect: preferDirect)
        self.direct = direct
        return link
    }

    private func attach(_ link: CastLink) async throws {
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
                hello = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                break
            }
        }
        let fields = hello.split(separator: " ")
        guard fields.first == "VIEWER", fields.count >= 6 else {
            link.close()
            throw AdbError.command("Unexpected answer from the TV app")
        }
        tv = TV(sdk: Int(fields[2]) ?? 0, longSide: Int(fields[3]) ?? 1920, hevc: fields[5] == "1")
        self.link = link

        let (stream, outbox) = AsyncStream.makeStream(of: Data.self)
        self.outbox = outbox
        // One writer keeps messages whole and in order.
        Task.detached {
            for await data in stream {
                do { try await link.write(data) } catch { break }
            }
            // Finished (disconnect/close) once everything queued was written.
            link.close()
        }
        let leftover = buffer
        Task { await self.readLoop(link, leftover: leftover) }
    }

    private func readLoop(_ link: CastLink, leftover: Data) async {
        var buffer = leftover
        while true {
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                handle(line)
            }
            guard let chunk = try? await link.read() else { break }
            buffer.append(chunk)
        }
        if self.link === link {
            self.link = nil
            outbox?.finish()
            outbox = nil
            state = .idle
        }
    }

    private func handle(_ line: String) {
        let f = line.split(separator: " ").map(String.init)
        guard let name = f.first, f.count > 1, let id = Int(f[1]) else { return }
        switch name {
        case "READY": onEvent?(.ready(id))
        case "SHOWN": onEvent?(.shown(id))
        case "PERR": onEvent?(.photoFailed(id))
        case "PLAYING": onEvent?(.playing(id))
        case "ENDED": onEvent?(.ended(id))
        case "VERR": onEvent?(.videoFailed(id, f.count > 2 ? f[2] : ""))
        case "TIME":
            guard f.count >= 5, let position = Double(f[2]), let duration = Double(f[3]) else { return }
            onEvent?(.time(id, position: position / 1000, duration: duration / 1000, playing: f[4] == "1"))
        case "READ":
            guard f.count >= 5, let request = Int(f[2]), let offset = UInt64(f[3]), let length = Int(f[4]) else { return }
            serveVideo(id: id, request: request, offset: offset, length: length)
        default: break
        }
    }

    func disconnect() {
        link?.close()
        link = nil
        outbox?.finish()
        outbox = nil
        state = .idle
    }

    // MARK: Commands

    private func send(_ line: String, _ payload: Data? = nil) {
        var data = Data((line + "\n").utf8)
        if let payload { data.append(payload) }
        outbox?.yield(data)
    }

    /// Sends a photo; the TV answers READY when it can be shown.
    func sendPhoto(id: Int, jpeg: Data) {
        send("PHOTO \(id) \(jpeg.count)", jpeg)
    }

    func show(id: Int) { send("SHOW \(id)") }
    func pause() { send("PAUSE") }
    func resume() { send("RESUME") }
    func seek(to seconds: Double) { send("SEEK \(Int(max(0, seconds) * 1000))") }
    func clear() {
        video = nil
        send("CLEAR")
    }

    /// Zooms what's on the TV: `scale` 1 = whole picture; (u, v) = picture point (0...1) to center.
    func zoom(id: Int, scale: CGFloat, u: CGFloat, v: CGFloat) {
        send(String(format: "ZOOM %d %.3f %.4f %.4f", id, scale, u, v))
    }

    /// Closes the viewer so the TV goes back to the app it was showing before.
    func closeViewer() async {
        video = nil
        if link != nil {
            send("CLOSE")
            // Forget this connection now (the writer still delivers CLOSE, then hangs up),
            // so opening something right away starts the viewer again instead of reusing it.
            link = nil
            outbox?.finish()
            outbox = nil
            state = .idle
        } else {
            // Not connected (e.g. it dropped): stop the app over ADB instead.
            _ = try? await adb.shell("am force-stop \(Self.package)")
        }
    }

    /// Starts playback on the TV right away; it reads the file from the phone as it plays.
    func playVideo(id: Int, file: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        video = (id, file)
        send("VIDEO \(id) \(size) video/mp4")
    }

    private func serveVideo(id: Int, request: Int, offset: UInt64, length: Int) {
        guard let video, video.id == id else {
            send("DATA \(request) 0", Data())
            return
        }
        let url = video.url
        Task.detached { [weak self] in
            var data = Data()
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: offset)
                data = (try? handle.read(upToCount: length)) ?? Data()
                try? handle.close()
            }
            await self?.send("DATA \(request) \(data.count)", data)
        }
    }
}

// MARK: Links

/// A byte pipe to the viewer: a direct TCP connection or an ADB "tcp:" stream.
protocol CastLink: AnyObject, Sendable {
    func write(_ data: Data) async throws
    func read() async throws -> Data?
    func close()
}

extension AdbStream: CastLink {
    func read() async throws -> Data? { try await read(max: .max) }
}

final class DirectLink: CastLink, @unchecked Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    static func open(host: String, port: UInt16, timeout: Double = 2) async throws -> DirectLink {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let link = DirectLink(connection)
        let state = OneShot()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { s in
                switch s {
                case .ready: state.fire { c.resume() }
                case .failed(let e), .waiting(let e): state.fire { connection.cancel(); c.resume(throwing: e) }
                case .cancelled: state.fire { c.resume(throwing: AdbError.closed) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.fire { connection.cancel(); c.resume(throwing: AdbError.timeout("viewer")) }
            }
        }
        return link
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if done { c.resume(returning: nil) }
                else if let error { c.resume(throwing: error) }
                else { c.resume(returning: nil) }
            }
        }
    }

    func close() { connection.cancel() }
}

/// Runs the first of several racing callbacks only.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ action: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { action() }
    }
}
