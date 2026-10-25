import Foundation

/// Trackpad motion for a device, shared by the iOS and Android apps. Collects pointer motion
/// and sends it as fast as the device takes it: while one report is on its way, new motion
/// adds up and goes out in the next one.
///
/// Uses a virtual USB mouse (Android draws its own pointer) when the device allows it;
/// otherwise the TV app draws a pointer and clicks/scrolls are injected at its position.
public final class PointerSender: @unchecked Sendable {
    private enum Mode {
        case undecided
        case mouse
        case drawn(DrawnPointer)
    }

    private let remote: RemoteInput
    private let makeDrawnPointer: @Sendable () -> DrawnPointer
    private let onError: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var mode = Mode.undecided
    private var dx = 0.0
    private var dy = 0.0
    private var wheel = 0.0
    private var pan = 0.0
    private var buttons: UInt8 = 0
    /// Button changes are queued so a quick click still sends down, then up.
    private var buttonChanges: [UInt8] = []
    private var sending = false

    /// Finger travel (points) per scroll step.
    private let scrollStep = 18.0

    /// `apk`/`helperJar`: the TV app, installed if a drawn pointer is needed.
    /// `onError` gets a message when sending fails, and nil once it works again.
    public init(remote: RemoteInput, adb: AdbConnection, host: String, sdk: Int, apk: URL, helperJar: Data,
                onError: @escaping @Sendable (String?) -> Void) {
        self.remote = remote
        self.onError = onError
        makeDrawnPointer = { DrawnPointer(adb: adb, host: host, sdk: sdk, remote: remote, apk: apk, helperJar: helperJar) }
    }

    public func move(dx: Double, dy: Double) {
        lock.withLock {
            self.dx += dx
            self.dy += dy
        }
        pump()
    }

    /// Natural scrolling: content follows the fingers.
    public func scroll(dx: Double, dy: Double) {
        lock.withLock {
            wheel += dy / scrollStep
            pan -= dx / scrollStep
        }
        pump()
    }

    public func setButtons(_ value: UInt8) {
        lock.withLock { buttonChanges.append(value) }
        pump()
    }

    public func click(button: UInt8) {
        lock.withLock { buttonChanges += [button, 0] }
        pump()
    }

    /// Removes a drawn pointer from the TV (leaving the trackpad); it comes back on the next touch.
    public func hide() {
        let pointer = lock.withLock { () -> DrawnPointer? in
            guard case .drawn(let pointer) = mode else { return nil }
            mode = .undecided
            return pointer
        }
        pointer?.hide()
    }

    private func pump() {
        let start = lock.withLock { () -> Bool in
            if sending { return false }
            sending = true
            return true
        }
        guard start else { return }
        Task { await run() }
    }

    private func clear() {
        lock.withLock {
            dx = 0; dy = 0; wheel = 0; pan = 0
            buttonChanges.removeAll()
            sending = false
        }
    }

    private func run() async {
        if case .undecided = lock.withLock({ mode }) {
            if await remote.virtualMouseAvailable() {
                lock.withLock { mode = .mouse }
            } else {
                let pointer = makeDrawnPointer()
                do {
                    try await pointer.start()
                    lock.withLock { mode = .drawn(pointer) }
                } catch {
                    onError("Couldn't show a pointer on this device: \(error.localizedDescription)")
                    clear()
                    return
                }
            }
        }
        while true {
            // Take whole steps; fractions wait for the next report.
            let step = lock.withLock { () -> (x: Int, y: Int, w: Int, p: Int, buttons: UInt8, previous: UInt8, mode: Mode)? in
                let x = Int(dx), y = Int(dy), w = Int(wheel), p = Int(pan)
                let change = buttonChanges.isEmpty ? nil : buttonChanges.removeFirst()
                guard x != 0 || y != 0 || w != 0 || p != 0 || change != nil else {
                    sending = false
                    return nil
                }
                dx -= Double(x)
                dy -= Double(y)
                wheel -= Double(w)
                pan -= Double(p)
                let previous = buttons
                if let change { buttons = change }
                return (x, y, w, p, buttons, previous, mode)
            }
            guard let step else { return }
            do {
                switch step.mode {
                case .drawn(let pointer):
                    try await pointer.send(dx: step.x, dy: step.y, wheel: step.w, pan: step.p, buttons: step.buttons, previous: step.previous)
                default:
                    try await remote.mouse(dx: step.x, dy: step.y, buttons: step.buttons, wheel: step.w, pan: step.p)
                }
                onError(nil)
            } catch {
                onError(error.localizedDescription)
                lock.withLock {
                    if case .drawn = mode { mode = .undecided }
                }
                if case .drawn = step.mode {} else { remote.close() }
                clear()
                return
            }
        }
    }
}

/// A pointer drawn by the TV app (PointerService) for devices without a virtual mouse.
/// The phone keeps its position; clicks become touches there, right click is Back.
final class DrawnPointer: @unchecked Sendable {
    private let adb: AdbConnection
    private let host: String
    private let sdk: Int
    private let remote: RemoteInput
    private let apk: URL
    private let helperJar: Data
    private var link: ViewerLink?
    private var width = 1920
    private var height = 1080
    private var x = 960
    private var y = 540
    private var lastSent = (x: -1, y: -1)

    static let port: UInt16 = 38791

    init(adb: AdbConnection, host: String, sdk: Int, remote: RemoteInput, apk: URL, helperJar: Data) {
        self.adb = adb
        self.host = host
        self.sdk = sdk
        self.remote = remote
        self.apk = apk
        self.helperJar = helperJar
    }

    func start() async throws {
        try await ViewerClient.installIfNeeded(adb: adb, sdk: sdk, apk: apk, helperJar: helperJar)
        if sdk >= 23 { _ = try? await adb.shell("appops set \(ViewerClient.package) SYSTEM_ALERT_WINDOW allow") }
        let verb = sdk >= 26 ? "start-foreground-service" : "startservice"
        _ = try await adb.shell("am \(verb) -n \(ViewerClient.package)/.PointerService")
        var lastError: Error = AdbError.timeout("pointer")
        for attempt in 0..<10 {
            do {
                let (link, _) = try await ViewerClient.openLink(adb: adb, host: host, port: Self.port, preferDirect: attempt < 6)
                try await link.write(Data("SIZE\n".utf8))
                let timer = Task {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    link.close()
                }
                defer { timer.cancel() }
                var buffer = Data()
                while !buffer.contains(10) {
                    guard let chunk = try await link.read() else { throw AdbError.closed }
                    buffer.append(chunk)
                }
                let f = String(decoding: buffer, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
                if f.count >= 3, let w = Int(f[1]), let h = Int(f[2]) {
                    width = w
                    height = h
                }
                x = width / 2
                y = height / 2
                self.link = link
                // Keep reading so the connection notices when it closes.
                Task.detached { while (try? await link.read()) != nil {} }
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw lastError
    }

    /// Phone points to screen pixels: bigger screens move further per swipe.
    private var scale: Double { Double(max(width, height)) / 1100 }

    func send(dx: Int, dy: Int, wheel: Int, pan: Int, buttons: UInt8, previous: UInt8) async throws {
        guard let link else { throw AdbError.closed }
        if dx != 0 || dy != 0 {
            x = min(max(x + Int((Double(dx) * scale).rounded()), 0), width - 1)
            y = min(max(y + Int((Double(dy) * scale).rounded()), 0), height - 1)
            if (x, y) != lastSent {
                lastSent = (x, y)
                try await link.write(Data("POS \(x) \(y)\n".utf8))
            }
            // Dragging: the finger follows the pointer.
            if previous & 1 != 0 && buttons & 1 != 0 { try await remote.pointerTouch(.move, x: x, y: y) }
        }
        if wheel != 0 || pan != 0 {
            try await remote.pointerScroll(x: x, y: y, horizontal: pan, vertical: wheel)
        }
        if buttons != previous {
            if buttons & 1 != 0 && previous & 1 == 0 { try await remote.pointerTouch(.down, x: x, y: y) }
            if buttons & 1 == 0 && previous & 1 != 0 { try await remote.pointerTouch(.up, x: x, y: y) }
            if buttons & 2 != 0 && previous & 2 == 0 { try await remote.press(.back) }
        }
    }

    func hide() {
        guard let link else { return }
        self.link = nil
        Task {
            try? await link.write(Data("HIDE\n".utf8))
            link.close()
        }
    }
}
