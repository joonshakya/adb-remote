import AdbKit
import Foundation

// Dev tool for exercising AdbKit against real devices from the Mac.
// Usage: adbkit-cli <host:port> <command> [args...]
//   shell <cmd...> | info | ls <path> | pull <remote> <local> | push <local> <remote>
//   pair <host:port> <code>

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: adbkit-cli <host:port> shell|info|ls|pull|push|pair ...\n".utf8))
    exit(2)
}

func loadKey() throws -> AdbKey {
    // Reuse the Mac's adb key so devices already authorized for `adb` accept us.
    // ADBKEY overrides the path (e.g. when run on an Android device).
    let url = ProcessInfo.processInfo.environment["ADBKEY"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/adbkey")
    return try AdbKey(pem: String(contentsOf: url, encoding: .utf8), name: "adbkit-cli@mac")
}

/// App/Resources/adbremote-helper.jar in this repository (found from this source file's path).
let helperJarURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("App/Resources/adbremote-helper.jar")

func parseTarget(_ s: String) -> (String, UInt16) {
    let parts = s.split(separator: ":")
    guard parts.count == 2, let port = UInt16(parts[1]) else { usage() }
    return (String(parts[0]), port)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }
let (host, port) = parseTarget(args[0])
let command = args[1]
let rest = Array(args.dropFirst(2))

do {
    let key = try loadKey()
    if command == "ziptest" {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZIPTEST"] ?? "/tmp/ziptest")
        try Zip.create(at: dir.appendingPathComponent("out.apks"), files: rest.map { (($0 as NSString).lastPathComponent, URL(fileURLWithPath: $0)) })
        for e in try Zip.entries(of: dir.appendingPathComponent("in.zip")) {
            try Zip.extract(e, from: dir.appendingPathComponent("in.zip"), to: dir.appendingPathComponent("x-" + e.name))
            print("extracted", e.name)
        }
        exit(0)
    }
    if command == "scan" {
        let t = Date()
        let found = try await PortScanner.findAdbPorts(host: host) { scanned, total, open in
            if scanned % 8192 < 128 || scanned == total { print("scanned \(scanned)/\(total) open=\(open)") }
        }
        print("adb ports: \(found.map { "\($0.port) \($0.kind)" }) in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
        exit(0)
    }
    if command == "pair" {
        guard rest.count == 1 else { usage() }
        try await AdbPairing.pair(host: host, port: port, code: rest[0], key: key)
        print("paired")
        exit(0)
    }
    let start = Date()
    let adb = try await AdbConnection.connect(host: host, port: port, key: key) { event in
        print("event: \(event)")
    }
    print("connected in \(String(format: "%.2f", Date().timeIntervalSince(start)))s tls=\(adb.usesTLS)")
    switch command {
    case "shell":
        let result = try await adb.shell(rest.joined(separator: " "))
        FileHandle.standardOutput.write(result.stdout)
        FileHandle.standardError.write(result.stderr)
        print("exit: \(result.exitCode.map(String.init) ?? "?")")
    case "info":
        print(adb.banner)
        let info = try await DeviceInfo.load(from: adb)
        for (label, value) in info.rows { print("\(label): \(value)") }
    case "extras":
        let info = try await DeviceInfo.load(from: adb)
        let extras = try await DeviceExtras.load(from: adb, sdk: info.sdk)
        for (k, v) in extras.root.details { print("\(k): \(v)") }
        print("Google Play: \(extras.play.summary) store=\(extras.play.playStoreVersion ?? "-") gms=\(extras.play.playServicesVersion ?? "-")")
        print("Google packages: \(extras.play.googlePackages)")
        print("ADB features: \(extras.adbFeatures)")
        for c in extras.capabilities { print("\(c.supported ? "yes" : "no ") \(c.name) — \(c.note)") }
    case "mouse":
        // mouse dx dy [click]: moves the virtual mouse, optionally clicks, waits so you can look.
        let info = try await DeviceInfo.load(from: adb)
        let jar = try? Data(contentsOf: URL(fileURLWithPath: "../App/Resources/scrcpy-server-v5.0.1"))
        let input = RemoteInput(adb: adb, sdk: info.sdk, serverJar: jar)
        try await input.prepare()
        let dx = Int(rest.first ?? "") ?? 200, dy = Int(rest.dropFirst().first ?? "") ?? 200
        for _ in 0..<10 { try await input.mouse(dx: dx / 10, dy: dy / 10, buttons: 0); try await Task.sleep(nanoseconds: 30_000_000) }
        if rest.contains("click") {
            try await input.mouse(dx: 0, dy: 0, buttons: 1)
            try await input.mouse(dx: 0, dy: 0, buttons: 0)
        }
        try await Task.sleep(nanoseconds: 12_000_000_000)
    case "ping":
        for _ in 0..<5 { print("ping \(Int(try await adb.ping() * 1000)) ms") }
    case "speed":
        let r = try await adb.speedTest(bytes: Int(rest.first ?? "") ?? 4 * 1024 * 1024) { print($0) }
        print("latency \(Int(r.latency * 1000))ms up \(SpeedTestResult.format(r.uploadBytesPerSecond)) down \(SpeedTestResult.format(r.downloadBytesPerSecond))")
    case "keys", "type":
        // keys: names or numbers, e.g. "home dpadDown 23 ctrl+b f5"; type: text
        let info = try await DeviceInfo.load(from: adb)
        let jar = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/scrcpy/scrcpy-server"))
        let helper = try? Data(contentsOf: URL(fileURLWithPath: "../App/Resources/adbremote-helper.jar"))
        let input = RemoteInput(adb: adb, sdk: info.sdk, serverJar: jar, helperJar: helper)
        let t0 = Date()
        try await input.prepare()
        print("backend \(input.backend) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        if command == "type" {
            try await input.type(rest.joined(separator: " "))
        } else {
            for token in rest {
                var meta: MetaState = []
                var name = Substring(token)
                if name.hasPrefix("ctrl+") { meta.insert(.ctrl); name = name.dropFirst(5) }
                let code: Int32
                if let n = Int32(name) { code = n }
                else if name.count == 1, let c = Keycode.forCharacter(name.first!) { code = c }
                else if let k = Keycode.allCases.first(where: { "\($0)".lowercased() == name.lowercased() }) { code = k.rawValue }
                else { print("unknown key \(name)"); continue }
                let t = Date()
                try await input.press(code, meta: meta)
                print("\(token) sent in \(Int(Date().timeIntervalSince(t) * 1000))ms")
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        input.close()
    case "apps":
        let info = try await DeviceInfo.load(from: adb)
        let jar = try Data(contentsOf: helperJarURL)
        let manager = AppManager(adb: adb, sdk: info.sdk, helperJar: jar)
        var t = Date()
        let apps = try await manager.listApps()
        print("\(apps.count) apps (\(apps.filter { !$0.isSystem }.count) user, \(apps.filter(\.isLaunchable).count) launchable) in \(String(format: "%.2f", Date().timeIntervalSince(t)))s")
        t = Date()
        let launchable = apps.filter(\.isLaunchable).map(\.packageName)
        let icons = try await manager.icons(for: launchable)
        print("\(icons.count) icons, \(icons.values.reduce(0) { $0 + $1.count } / 1024) KB in \(String(format: "%.2f", Date().timeIntervalSince(t)))s")
        for app in apps where !app.isSystem { print(" ", app.label, "|", app.packageName, app.versionName) }
        if let pkg = rest.first, let app = apps.first(where: { $0.packageName == pkg }) {
            let urls = try await manager.extract(app, to: URL(fileURLWithPath: "/tmp/extract"))
            print("extracted", urls.map(\.lastPathComponent))
        }
    case "install":
        let info = try await DeviceInfo.load(from: adb)
        let jar = try Data(contentsOf: helperJarURL)
        let manager = AppManager(adb: adb, sdk: info.sdk, helperJar: jar)
        let t = Date()
        do {
            try await manager.installPackage(at: URL(fileURLWithPath: rest[0]), workDirectory: URL(fileURLWithPath: "/tmp/install-parts")) { print("  \($0)") }
            print("installed in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
        } catch {
            print("install error: \(error.localizedDescription)")
        }
    case "video":
        let jar = try Data(contentsOf: URL(fileURLWithPath: "/tmp/scrcpy/scrcpy-server"))
        let t0 = Date()
        let session = try await ScrcpySession.start(adb: adb, serverJar: jar, video: .init(maxSize: 1280, bitRate: 4_000_000, maxFps: 30))
        let reader = ScrcpyVideoReader(stream: session.video!)
        print("codec \(String(format: "%08x", try await reader.readCodec())) after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        var out = Data(); var frames = 0; var keys = 0; var firstFrame: Date?
        let end = Date().addingTimeInterval(4)
        // Nudge the screen so frames keep coming.
        Task { for _ in 0..<4 { try? await Task.sleep(nanoseconds: 800_000_000); try? await session.injectKey(.down, keycode: 22); try? await session.injectKey(.up, keycode: 22) } }
        while Date() < end, let event = try await reader.next() {
            switch event {
            case .size(let w, let h): print("size \(w)x\(h)")
            case .config(let d): print("config \(d.count) bytes"); out.append(d)
            case .frame(let d, _, let key): frames += 1; if key { keys += 1 }; if firstFrame == nil { firstFrame = Date(); print("first frame after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s") }; out.append(d)
            }
        }
        print("\(frames) frames (\(keys) key) \(out.count / 1024) KB")
        try out.write(to: URL(fileURLWithPath: "/tmp/shots/stream.h264"))
        session.close()
    case "tap":
        // tap x y in 1920x1080 device pixels
        let jar = try Data(contentsOf: URL(fileURLWithPath: "/tmp/scrcpy/scrcpy-server"))
        let session = try await ScrcpySession.start(adb: adb, serverJar: jar, video: .init())
        let reader = ScrcpyVideoReader(stream: session.video!)
        _ = try await reader.readCodec()
        var w = 0, h = 0
        while w == 0, let e = try await reader.next() { if case .size(let a, let b) = e { w = a; h = b } }
        Task { while (try? await reader.next()) != nil {} }
        print("video \(w)x\(h)")
        let x = Int32(Int(rest[0])! * w / 1920), y = Int32(Int(rest[1])! * h / 1080)
        try await session.injectTouch(.down, x: x, y: y, width: UInt16(w), height: UInt16(h))
        try await Task.sleep(nanoseconds: 80_000_000)
        try await session.injectTouch(.up, x: x, y: y, width: UInt16(w), height: UInt16(h))
        try await Task.sleep(nanoseconds: 500_000_000)
        session.close()
    case "ls":
        for entry in try await adb.sync { try await $0.list(rest.first ?? "/sdcard") } {
            print(entry.isDirectory ? "d" : "-", entry.size, entry.name)
        }
    case "pull":
        guard rest.count == 2 else { usage() }
        let t = Date()
        try await adb.sync { try await $0.pull(rest[0], to: URL(fileURLWithPath: rest[1])) { _ in } }
        print("pulled in \(Date().timeIntervalSince(t))s")
    case "push":
        guard rest.count == 2 else { usage() }
        let t = Date()
        try await adb.sync { try await $0.push(URL(fileURLWithPath: rest[0]), to: rest[1]) { _ in } }
        print("pushed in \(Date().timeIntervalSince(t))s")
    default:
        usage()
    }
    adb.close()
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
