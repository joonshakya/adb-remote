import Foundation

/// Android KeyEvent keycodes used by the remote.
public enum Keycode: Int32, Sendable, CaseIterable {
    case home = 3, back = 4, call = 5, endCall = 6
    case dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22, dpadCenter = 23
    case volumeUp = 24, volumeDown = 25, power = 26
    case tab = 61, space = 62, enter = 66, del = 67
    case menu = 82, search = 84
    case mediaPlayPause = 85, mediaStop = 86, mediaNext = 87, mediaPrevious = 88
    case mediaRewind = 89, mediaFastForward = 90, mute = 164
    case pageUp = 92, pageDown = 93
    case escape = 111, forwardDel = 112
    case ctrlLeft = 113, ctrlRight = 114
    case moveHome = 122, moveEnd = 123, insert = 124
    case f1 = 131, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case info = 165, channelUp = 166, channelDown = 167
    case guide = 172, settings = 176, tvInput = 178
    case captions = 175
    case appSwitch = 187
    case sleep = 223, wakeup = 224

    /// KEYCODE_A..Z = 29..54, KEYCODE_0..9 = 7..16.
    public static func forCharacter(_ c: Character) -> Int32? {
        guard let ascii = c.lowercased().unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return nil }
        switch ascii {
        case 97...122: return Int32(29 + ascii - 97)
        case 48...57: return Int32(7 + ascii - 48)
        case 32: return Keycode.space.rawValue
        case 10: return Keycode.enter.rawValue
        default: return nil
        }
    }

    public static func function(_ n: Int) -> Int32 { 130 + Int32(n) }
}

public struct MetaState: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = MetaState(rawValue: 0x1 | 0x40)
    public static let alt = MetaState(rawValue: 0x2 | 0x10)
    public static let ctrl = MetaState(rawValue: 0x1000 | 0x2000)
    public static let meta = MetaState(rawValue: 0x10000 | 0x20000)
}

/// Sends keys and text to a device: scrcpy control on Android 5+; on older devices the
/// helper jar's injector (falls back to `input`, which takes 1-2 s per key there).
public final class RemoteInput: @unchecked Sendable {
    public enum Backend: Sendable { case scrcpy, shell }

    private let adb: AdbConnection
    private let sdk: Int
    private let serverJar: Data?
    private let helperJar: Data?
    private var scrcpy: ScrcpySession?
    private var shellStream: AdbStream?
    private var injector: AdbStream?
    private var injectorFailed = false
    private let lock = AsyncLock()

    public init(adb: AdbConnection, sdk: Int, serverJar: Data?, helperJar: Data? = nil) {
        self.adb = adb
        self.sdk = sdk
        self.serverJar = serverJar
        self.helperJar = helperJar
    }

    public var backend: Backend { sdk >= 21 && serverJar != nil ? .scrcpy : .shell }

    /// For logs: "scrcpy", "injector" (helper jar) or "input" (slow shell command).
    public var backendName: String {
        if backend == .scrcpy { return "scrcpy" }
        return injector != nil ? "injector" : "input"
    }

    /// Starts the scrcpy control channel (or the injector) up front so the first key press is instant.
    public func prepare() async throws {
        try await lock.withLock {
            if try await session() == nil { _ = await injectorStream() }
        }
    }

    public func close() {
        scrcpy?.close()
        scrcpy = nil
        shellStream?.close()
        shellStream = nil
        injector?.close()
        injector = nil
    }

    private func session() async throws -> ScrcpySession? {
        guard backend == .scrcpy, let serverJar else { return nil }
        if let scrcpy, !scrcpy.isClosed { return scrcpy }
        let session = try await ScrcpySession.start(adb: adb, serverJar: serverJar)
        scrcpy = session
        return session
    }

    /// Long-lived shell for `input` commands; avoids opening a stream per key.
    private func shell() async throws -> AdbStream {
        if let shellStream, !shellStream.isClosed { return shellStream }
        let stream = try await adb.open("shell:")
        shellStream = stream
        // Drain the prompt/echo so the device never blocks on output.
        Task.detached { while (try? await stream.read()) != nil {} }
        return stream
    }

    /// The helper's `input` loop; nil if it can't start on this device (then `input` is used).
    private func injectorStream() async -> AdbStream? {
        guard let helperJar, !injectorFailed else { return nil }
        if let injector, !injector.isClosed { return injector }
        do {
            let path = try await adb.installHelper(helperJar)
            let stream = try await adb.open("shell:CLASSPATH=\(path) app_process / local.adbremote.helper.Main input")
            try await withTimeout(20, "starting key sender") {
                var seen = ""
                while !seen.contains("READY") {
                    guard let data = try await stream.read() else { throw AdbError.closed }
                    seen += String(decoding: data, as: UTF8.self)
                    if seen.contains("ERR") { throw AdbError.command(seen) }
                }
            }
            Task.detached { while (try? await stream.read()) != nil {} }
            injector = stream
            return stream
        } catch {
            injectorFailed = true
            return nil
        }
    }

    private func runShell(_ command: String) async throws {
        try await shell().write(command + "\n")
    }

    /// Press and release a key, optionally with modifiers (Ctrl, Shift, ...).
    public func press(_ keycode: Int32, meta: MetaState = [], longPress: Bool = false) async throws {
        try await lock.withLock {
            if let scrcpy = try await session() {
                if meta.contains(.ctrl) { try await scrcpy.injectKey(.down, keycode: Keycode.ctrlLeft.rawValue, metaState: MetaState.ctrl.rawValue) }
                try await scrcpy.injectKey(.down, keycode: keycode, metaState: meta.rawValue)
                if longPress {
                    try await Task.sleep(nanoseconds: 600_000_000)
                    try await scrcpy.injectKey(.down, keycode: keycode, metaState: meta.rawValue, repeatCount: 1)
                }
                try await scrcpy.injectKey(.up, keycode: keycode, metaState: meta.rawValue)
                if meta.contains(.ctrl) { try await scrcpy.injectKey(.up, keycode: Keycode.ctrlLeft.rawValue) }
            } else if let injector = await injectorStream() {
                try await injector.write("K \(keycode) \(meta.rawValue) \(longPress ? 1 : 0)\n")
            } else {
                if !meta.isEmpty && sdk >= 33 {
                    var keys: [Int32] = []
                    if meta.contains(.ctrl) { keys.append(Keycode.ctrlLeft.rawValue) }
                    if meta.contains(.shift) { keys.append(59) }
                    if meta.contains(.alt) { keys.append(57) }
                    keys.append(keycode)
                    try await runShell("input keycombination " + keys.map(String.init).joined(separator: " "))
                } else {
                    try await runShell("input keyevent \(longPress ? "--longpress " : "")\(keycode)")
                }
            }
        }
    }

    public func press(_ key: Keycode, meta: MetaState = [], longPress: Bool = false) async throws {
        try await press(key.rawValue, meta: meta, longPress: longPress)
    }

    /// Session the virtual mouse was created on (it goes away with the session).
    private var mouseSession: ScrcpySession?
    private static let mouseID: UInt16 = 2

    public var supportsMouse: Bool { backend == .scrcpy }

    /// Moves the pointer of a virtual mouse (created on first use) and sets its buttons.
    /// Large moves are split into steps the HID report can carry (±127).
    public func mouse(dx: Int, dy: Int, buttons: UInt8, wheel: Int = 0, pan: Int = 0) async throws {
        try await lock.withLock {
            guard let scrcpy = try await session() else {
                throw AdbError.command("The trackpad needs Android 5 or newer.")
            }
            if mouseSession !== scrcpy {
                try await scrcpy.createMouse(id: Self.mouseID)
                mouseSession = scrcpy
            }
            var x = dx, y = dy, w = wheel, p = pan
            repeat {
                func step(_ v: inout Int) -> Int8 {
                    let s = max(-127, min(127, v))
                    v -= s
                    return Int8(s)
                }
                try await scrcpy.mouseReport(id: Self.mouseID, buttons: buttons,
                                             dx: step(&x), dy: step(&y), wheel: step(&w), pan: step(&p))
            } while x != 0 || y != 0 || w != 0 || p != 0
        }
    }

    /// Whether a virtual mouse can be added: needs scrcpy and a /dev/uhid the shell user may
    /// open (some builds, e.g. BlueStacks, give it to Bluetooth only).
    public func virtualMouseAvailable() async -> Bool {
        guard backend == .scrcpy else { return false }
        let out = (try? await adb.shell("[ -r /dev/uhid ] && [ -w /dev/uhid ] && echo yes").output) ?? ""
        return out.contains("yes")
    }

    /// A touch at screen pixels through the helper's injector (for the drawn pointer).
    public func pointerTouch(_ action: TouchAction, x: Int, y: Int) async throws {
        try await lock.withLock {
            guard let injector = await injectorStream() else {
                throw AdbError.command("Couldn't start the pointer helper on this device.")
            }
            try await injector.write("P \(action.rawValue) \(x) \(y)\n")
        }
    }

    /// Wheel scroll at screen pixels through the helper's injector.
    public func pointerScroll(x: Int, y: Int, horizontal: Int, vertical: Int) async throws {
        try await lock.withLock {
            guard let injector = await injectorStream() else {
                throw AdbError.command("Couldn't start the pointer helper on this device.")
            }
            try await injector.write("W \(x) \(y) \(horizontal) \(vertical)\n")
        }
    }

    /// Types text into the focused field.
    public func type(_ text: String) async throws {
        guard !text.isEmpty else { return }
        try await lock.withLock {
            if let scrcpy = try await session() {
                if text.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    try await scrcpy.injectText(text)
                } else {
                    // Characters without a key mapping (emoji, Devanagari, ...) go via paste.
                    try await scrcpy.setClipboard(text, paste: true)
                }
            } else if let injector = await injectorStream() {
                try await injector.write("T \(Data(text.utf8).base64EncodedString())\n")
            } else {
                // `input text` takes one shell word; spaces must be %s.
                let ascii = String(text.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map(Character.init))
                for line in ascii.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if line.offset > 0 { try await runShell("input keyevent \(Keycode.enter.rawValue)") }
                    let escaped = line.element.replacingOccurrences(of: " ", with: "%s")
                    if !escaped.isEmpty { try await runShell("input text " + shellQuote(escaped)) }
                }
            }
        }
    }
}
