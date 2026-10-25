import AdbKit
import Foundation

/// A connection plus a way to wait for it to drop.
final class ConnectionBox: @unchecked Sendable {
    let adb: AdbConnection
    private let lock = NSLock()
    private var dropped: String?
    private var waiters: [CheckedContinuation<String, Never>] = []

    init(_ adb: AdbConnection) {
        self.adb = adb
        adb.onDisconnect { [weak self] error in self?.drop(error.localizedDescription) }
    }

    private func drop(_ message: String) {
        let waiting = lock.withLock { () -> [CheckedContinuation<String, Never>] in
            if dropped == nil { dropped = message }
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume(returning: message) }
    }

    func waitForDisconnect() async -> String {
        await withCheckedContinuation { c in
            let message = lock.withLock { () -> String? in
                if dropped == nil { waiters.append(c) }
                return dropped
            }
            if let message { c.resume(returning: message) }
        }
    }

    func close() {
        adb.close()
        drop("closed")
    }
}

/// App manager plus the last listed apps (actions refer to apps by package name).
final class AppsBox: @unchecked Sendable {
    let manager: AppManager
    private let lock = NSLock()
    private var apps: [String: InstalledApp] = [:]

    init(_ manager: AppManager) { self.manager = manager }

    func remember(_ list: [InstalledApp]) {
        lock.withLock { apps = Dictionary(list.map { ($0.packageName, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    func app(_ request: JSON) throws -> InstalledApp {
        let name = request["package"] as? String ?? ""
        guard let app = lock.withLock({ apps[name] }) else { throw BridgeError("unknown app \(name)") }
        return app
    }
}

/// A trackpad sender and its latest problem (nil when sending works).
final class PointerBox: @unchecked Sendable {
    var sender: PointerSender?
    private let lock = NSLock()
    private var problem: String?

    func report(_ message: String?) { lock.withLock { problem = message } }
    var reply: Reply { Reply(lock.withLock { problem }.map { ["problem": $0] } ?? [:]) }
}

/// A scrcpy session showing the screen, and its video reader.
final class ScreenBox: @unchecked Sendable {
    let session: ScrcpySession
    let reader: ScrcpyVideoReader

    init(_ session: ScrcpySession, reader: ScrcpyVideoReader) {
        self.session = session
        self.reader = reader
    }
}

/// A viewer connection plus its events, queued until Kotlin asks for them (op "castEvents").
final class CastBox: @unchecked Sendable {
    var client: ViewerClient?
    private let lock = NSLock()
    private var events: [JSON] = []
    private var waiter: CheckedContinuation<[JSON], Never>?

    func push(_ event: ViewerClient.Event) {
        let json: JSON
        switch event {
        case .ready(let id): json = ["type": "ready", "id": id]
        case .shown(let id): json = ["type": "shown", "id": id]
        case .photoFailed(let id): json = ["type": "photoFailed", "id": id]
        case .playing(let id): json = ["type": "playing", "id": id]
        case .ended(let id): json = ["type": "ended", "id": id]
        case .videoFailed(let id, let why): json = ["type": "videoFailed", "id": id, "why": why]
        case .time(let id, let position, let duration, let playing):
            json = ["type": "time", "id": id, "position": position, "duration": duration, "playing": playing]
        case .read(let id, let request, let offset, let length):
            json = ["type": "read", "id": id, "request": request, "offset": Int(offset), "length": length]
        case .closed: json = ["type": "closed"]
        }
        let resume = lock.withLock { () -> CheckedContinuation<[JSON], Never>? in
            events.append(json)
            guard let waiter else { return nil }
            self.waiter = nil
            return waiter
        }
        if let resume { resume.resume(returning: lock.withLock { defer { events = [] }; return events }) }
    }

    /// Waits for at least one event, then returns all queued ones.
    func next() async -> [JSON] {
        await withCheckedContinuation { c in
            let ready = lock.withLock { () -> [JSON]? in
                if events.isEmpty {
                    waiter?.resume(returning: [])
                    waiter = c
                    return nil
                }
                defer { events = [] }
                return events
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}

enum Ops {
    static func run(_ op: String, _ r: JSON, input: Data, bridge: Bridge) async throws -> Reply {
        switch op {
        // MARK: Connection
        case "connect":
            let host = try string(r, "host")
            let port = UInt16(try int(r, "port"))
            let adb = try await AdbConnection.connect(host: host, port: port, key: try bridge.adbKey()) { event in
                if case .waitingForUserApproval = event { bridge.setProgress(r, ["waitingForApproval": true]) }
            }
            let id = bridge.store(ConnectionBox(adb))
            return Reply(["id": id, "usesTLS": adb.usesTLS, "banner": adb.banner])
        case "close":
            (bridge.remove(r, "id") as? ConnectionBox)?.close()
            return Reply()
        case "waitDisconnect":
            let box: ConnectionBox = try bridge.object(r, "id")
            return Reply(["error": await box.waitForDisconnect(), "disconnected": true])
        case "ping":
            let adb = try connection(r, bridge)
            return Reply(["seconds": try await adb.ping(timeout: r["timeout"] as? Double ?? 5)])
        case "shell":
            let result = try await connection(r, bridge).shell(try string(r, "command"))
            var reply: JSON = ["stdout": result.output, "stderr": result.errorOutput]
            if let code = result.exitCode { reply["exit"] = code }
            return Reply(reply)
        case "pair":
            let name = try await AdbPairing.pair(host: try string(r, "host"), port: UInt16(try int(r, "port")),
                                                 code: try string(r, "code"), key: try bridge.adbKey())
            return Reply(["name": name])
        case "openPorts":
            let ports = (r["ports"] as? [Int] ?? []).map { UInt16($0) }
            let open = try await PortScanner.openPorts(host: try string(r, "host"), ports: ports, timeout: r["timeout"] as? Double ?? 0.8)
            return Reply(["open": open.map(Int.init)])
        case "findAdbPorts":
            let preferred = (r["preferred"] as? [Int] ?? []).map { UInt16($0) }
            let found = try await PortScanner.findAdbPorts(host: try string(r, "host"), preferred: preferred) { scanned, total, open in
                bridge.setProgress(r, ["scanned": scanned, "total": total, "open": open.map(Int.init)])
            }
            return Reply(["found": found.map { ["port": Int($0.port), "tls": $0.kind == .adbTLS] }])

        // MARK: Device info
        case "info":
            let info = try await DeviceInfo.load(from: try connection(r, bridge))
            return Reply([
                "name": info.displayName, "sdk": info.sdk, "isTV": info.isTV,
                "rows": info.rows.map { [$0.0, $0.1] }, "advanced": info.advancedRows.map { [$0.0, $0.1] },
            ])
        case "extras":
            let extras = try await DeviceExtras.load(from: try connection(r, bridge), sdk: try int(r, "sdk"))
            return Reply([
                "root": ["answer": extras.root.answer, "explanation": extras.root.explanation,
                         "details": extras.root.details.map { [$0.0, $0.1] }],
                "play": extras.play.summary,
                "playStore": extras.play.playStoreVersion ?? "", "playServices": extras.play.hasPlayServices,
                "googlePackages": extras.play.googlePackages,
                "capabilities": extras.capabilities.map { ["name": $0.name, "supported": $0.supported, "note": $0.note] },
                "adbFeatures": extras.adbFeatures,
            ])
        case "speedTest":
            let result = try await connection(r, bridge).speedTest(bytes: try int(r, "bytes")) { status in
                bridge.setProgress(r, ["status": status])
            }
            return Reply(["upload": result.uploadBytesPerSecond, "download": result.downloadBytesPerSecond,
                          "latency": result.latency, "bytes": result.bytes])

        // MARK: Remote (keys, text, mouse)
        case "remoteCreate":
            let remote = RemoteInput(adb: try connection(r, bridge), sdk: try int(r, "sdk"),
                                     serverJar: try file(r, "serverJar"), helperJar: try file(r, "helperJar"))
            return Reply(["remote": bridge.store(remote), "mouse": remote.supportsMouse])
        case "remotePrepare":
            let remote: RemoteInput = try bridge.object(r, "remote")
            try await remote.prepare()
            return Reply(["backend": remote.backendName])
        case "remotePress":
            let remote: RemoteInput = try bridge.object(r, "remote")
            try await remote.press(Int32(try int(r, "keycode")), meta: MetaState(rawValue: UInt32(r["meta"] as? Int ?? 0)),
                                   longPress: r["long"] as? Bool ?? false)
            return Reply()
        case "remoteType":
            let remote: RemoteInput = try bridge.object(r, "remote")
            try await remote.type(try string(r, "text"))
            return Reply()
        case "remoteMouse":
            let remote: RemoteInput = try bridge.object(r, "remote")
            try await remote.mouse(dx: r["dx"] as? Int ?? 0, dy: r["dy"] as? Int ?? 0, buttons: UInt8(r["buttons"] as? Int ?? 0),
                                   wheel: r["wheel"] as? Int ?? 0, pan: r["pan"] as? Int ?? 0)
            return Reply()
        case "remoteRestart":
            let remote: RemoteInput = try bridge.object(r, "remote")
            remote.close()
            return Reply()
        case "remoteClose":
            (bridge.remove(r, "remote") as? RemoteInput)?.close()
            return Reply()

        // MARK: Trackpad
        case "pointerCreate":
            let remote: RemoteInput = try bridge.object(r, "remote")
            guard let helper = try file(r, "helperJar") else { throw BridgeError("missing helperJar") }
            let box = PointerBox()
            box.sender = PointerSender(remote: remote, adb: try connection(r, bridge), host: try string(r, "host"), sdk: try int(r, "sdk"),
                                       apk: URL(fileURLWithPath: try string(r, "apk")), helperJar: helper) { [weak box] in box?.report($0) }
            return Reply(["pointer": bridge.store(box)])
        case "pointerMove", "pointerScroll", "pointerButtons", "pointerClick", "pointerHide":
            let box: PointerBox = try bridge.object(r, "pointer")
            guard let sender = box.sender else { throw BridgeError("no pointer") }
            let dx = r["dx"] as? Double ?? 0, dy = r["dy"] as? Double ?? 0
            switch op {
            case "pointerMove": sender.move(dx: dx, dy: dy)
            case "pointerScroll": sender.scroll(dx: dx, dy: dy)
            case "pointerButtons": sender.setButtons(UInt8(r["buttons"] as? Int ?? 0))
            case "pointerClick": sender.click(button: UInt8(r["button"] as? Int ?? 1))
            default: sender.hide()
            }
            return box.reply

        // MARK: Apps
        case "appsCreate":
            let manager = AppManager(adb: try connection(r, bridge), sdk: try int(r, "sdk"), helperJar: try file(r, "helperJar") ?? Data())
            return Reply(["apps": bridge.store(AppsBox(manager))])
        case "appsList":
            let box: AppsBox = try bridge.object(r, "apps")
            let apps = try await box.manager.listApps()
            box.remember(apps)
            return Reply(["list": apps.map {
                ["package": $0.packageName, "label": $0.label, "versionName": $0.versionName, "versionCode": $0.versionCode,
                 "system": $0.isSystem, "enabled": $0.isEnabled, "launchable": $0.isLaunchable]
            }])
        case "appsIcons":
            // Icons go back as one blob: JSON says where each PNG starts and how long it is.
            let box: AppsBox = try bridge.object(r, "apps")
            let icons = try await box.manager.icons(for: r["packages"] as? [String] ?? [], size: r["size"] as? Int ?? 96)
            var data = Data()
            var index: JSON = [:]
            for (name, png) in icons {
                index[name] = [data.count, png.count]
                data.append(png)
            }
            return Reply(["icons": index], data: data)
        case "appsLaunch":
            let box: AppsBox = try bridge.object(r, "apps")
            try await box.manager.launch(try box.app(r))
            return Reply()
        case "appsStop":
            let box: AppsBox = try bridge.object(r, "apps")
            try await box.manager.forceStop(try string(r, "package"))
            return Reply()
        case "appsUninstall":
            let box: AppsBox = try bridge.object(r, "apps")
            try await box.manager.uninstall(try box.app(r))
            return Reply()
        case "appsInstall":
            let box: AppsBox = try bridge.object(r, "apps")
            try await box.manager.installPackage(at: URL(fileURLWithPath: try string(r, "path")),
                                                 workDirectory: URL(fileURLWithPath: try string(r, "workDir"))) { status in
                bridge.setProgress(r, ["status": status])
            }
            return Reply()
        case "appsExtract":
            let box: AppsBox = try bridge.object(r, "apps")
            let urls = try await box.manager.extract(try box.app(r), to: URL(fileURLWithPath: try string(r, "dir"))) { bytes in
                bridge.setProgress(r, ["bytes": Int(bytes)])
            }
            return Reply(["paths": urls.map(\.path)])
        case "zip":
            // Packs files into a stored ZIP (an .apks bundle of an app's split APKs).
            let paths = r["paths"] as? [String] ?? []
            try Zip.create(at: URL(fileURLWithPath: try string(r, "path")),
                           files: paths.map { (($0 as NSString).lastPathComponent, URL(fileURLWithPath: $0)) })
            return Reply()

        // MARK: Files
        case "filesList":
            let files = try await connection(r, bridge).sync { try await $0.list(try string(r, "path")) }
            return Reply(["list": files.filter { $0.name != "." && $0.name != ".." }.map {
                ["name": $0.name, "size": Int($0.size), "modified": $0.modified.timeIntervalSince1970,
                 "dir": $0.isDirectory, "link": $0.isSymlink, "file": $0.isRegularFile, "mode": Int($0.mode)]
            }])
        case "filesStat":
            let file = try await connection(r, bridge).sync { try await $0.stat(try string(r, "path")) }
            guard let file else { return Reply(["exists": false]) }
            return Reply(["exists": true, "size": Int(file.size), "dir": file.isDirectory, "link": file.isSymlink])
        case "filesPull":
            let local = URL(fileURLWithPath: try string(r, "local"))
            try await connection(r, bridge).sync { sync in
                try await sync.pull(try string(r, "remote"), to: local) { bytes in bridge.setProgress(r, ["bytes": Int(bytes)]) }
            }
            return Reply()
        case "filesPush":
            let local = URL(fileURLWithPath: try string(r, "local"))
            try await connection(r, bridge).sync { sync in
                try await sync.push(local, to: try string(r, "remote")) { bytes in bridge.setProgress(r, ["bytes": Int(bytes)]) }
            }
            return Reply()
        case "screenshot":
            return Reply([:], data: try await connection(r, bridge).screenshotPNG())

        // MARK: Screen (scrcpy video + touch)
        case "screenStart":
            guard let jar = try file(r, "serverJar") else { throw BridgeError("missing serverJar") }
            let options = ScrcpySession.VideoOptions(maxSize: r["maxSize"] as? Int ?? 1280,
                                                     bitRate: r["bitRate"] as? Int ?? 4_000_000,
                                                     maxFps: r["maxFps"] as? Int ?? 30)
            let session = try await ScrcpySession.start(adb: try connection(r, bridge), serverJar: jar, video: options)
            guard let video = session.video else { throw BridgeError("no video") }
            let reader = ScrcpyVideoReader(stream: video)
            let codec = try await reader.readCodec()
            guard codec == ScrcpyVideoReader.h264 else {
                session.close()
                throw BridgeError("unexpected video codec")
            }
            return Reply(["screen": bridge.store(ScreenBox(session, reader: reader))])
        case "screenNext":
            let box: ScreenBox = try bridge.object(r, "screen")
            switch try await box.reader.next() {
            case .size(let width, let height): return Reply(["type": "size", "width": width, "height": height])
            case .config(let data): return Reply(["type": "config"], data: data)
            case .frame(let data, let pts, let key): return Reply(["type": "frame", "pts": Int(pts), "key": key], data: data)
            case nil: return Reply(["type": "end"])
            }
        case "screenTouch":
            let box: ScreenBox = try bridge.object(r, "screen")
            guard let action = TouchAction(rawValue: UInt8(try int(r, "action"))) else { throw BridgeError("bad action") }
            try await box.session.injectTouch(action, pointerId: UInt64(r["pointer"] as? Int ?? 0),
                                              x: Int32(try int(r, "x")), y: Int32(try int(r, "y")),
                                              width: UInt16(try int(r, "width")), height: UInt16(try int(r, "height")))
            return Reply()
        case "screenScroll":
            let box: ScreenBox = try bridge.object(r, "screen")
            try await box.session.injectScroll(x: Int32(try int(r, "x")), y: Int32(try int(r, "y")),
                                               width: UInt16(try int(r, "width")), height: UInt16(try int(r, "height")),
                                               horizontal: Float(r["horizontal"] as? Double ?? 0), vertical: Float(r["vertical"] as? Double ?? 0))
            return Reply()
        case "screenKey":
            let box: ScreenBox = try bridge.object(r, "screen")
            let keycode = Int32(try int(r, "keycode"))
            try await box.session.injectKey(.down, keycode: keycode)
            try await box.session.injectKey(.up, keycode: keycode)
            return Reply()
        case "screenClose":
            (bridge.remove(r, "screen") as? ScreenBox)?.session.close()
            return Reply()

        // MARK: Raw ADB streams (e.g. "tcp:7200" to reach a TV port through ADB)
        case "streamOpen":
            let stream = try await connection(r, bridge).open(try string(r, "service"))
            return Reply(["stream": bridge.store(stream)])
        case "streamWrite":
            let stream: AdbStream = try bridge.object(r, "stream")
            try await stream.write(input)
            return Reply()
        case "streamRead":
            let stream: AdbStream = try bridge.object(r, "stream")
            guard let data = try await stream.read(max: 65536) else { return Reply(["closed": true]) }
            return Reply([:], data: data)
        case "streamClose":
            (bridge.remove(r, "stream") as? AdbStream)?.close()
            return Reply()

        // MARK: TV viewer (photos and videos from the phone)
        case "castConnect":
            let box = CastBox()
            let id = bridge.store(box)
            do {
                guard let helper = try file(r, "helperJar") else { throw BridgeError("missing helperJar") }
                box.client = try await ViewerClient.connect(
                    adb: try connection(r, bridge), host: try string(r, "host"), sdk: try int(r, "sdk"),
                    apk: URL(fileURLWithPath: try string(r, "apk")), helperJar: helper,
                    status: { bridge.setProgress(r, ["status": $0]) },
                    onEvent: { [weak box] in box?.push($0) })
            } catch {
                _ = bridge.remove(["cast": id], "cast")
                throw error
            }
            let tv = box.client!.tv
            return Reply(["cast": id, "direct": box.client!.direct, "sdk": tv.sdk, "longSide": tv.longSide, "hevc": tv.hevc])
        case "viewerInstall":
            guard let helper = try file(r, "helperJar") else { throw BridgeError("missing helperJar") }
            try await ViewerClient.installIfNeeded(adb: try connection(r, bridge), sdk: try int(r, "sdk"),
                                                   apk: URL(fileURLWithPath: try string(r, "apk")), helperJar: helper) {
                bridge.setProgress(r, ["status": "Installing the TV app (one time)"])
            }
            return Reply()
        case "castEvents":
            let box: CastBox = try bridge.object(r, "cast")
            return Reply(["events": await box.next()])
        case "castPhoto":
            try viewer(r, bridge).sendPhoto(id: try int(r, "photo"), jpeg: input)
            return Reply()
        case "castShow":
            try viewer(r, bridge).show(id: try int(r, "photo"))
            return Reply()
        case "castVideo":
            try viewer(r, bridge).playVideo(id: try int(r, "video"), size: try int(r, "size"), mime: r["mime"] as? String ?? "video/mp4")
            return Reply()
        case "castData":
            try viewer(r, bridge).sendData(request: try int(r, "requestId"), input)
            return Reply()
        case "castPause":
            try viewer(r, bridge).pause()
            return Reply()
        case "castResume":
            try viewer(r, bridge).resume()
            return Reply()
        case "castSeek":
            try viewer(r, bridge).seek(to: r["seconds"] as? Double ?? Double(try int(r, "seconds")))
            return Reply()
        case "castZoom":
            try viewer(r, bridge).zoom(id: try int(r, "photo"), scale: r["scale"] as? Double ?? 1,
                                       u: r["u"] as? Double ?? 0.5, v: r["v"] as? Double ?? 0.5)
            return Reply()
        case "castClear":
            try viewer(r, bridge).clear()
            return Reply()
        case "castCloseViewer":
            try viewer(r, bridge).closeViewer()
            return Reply()
        case "castDisconnect":
            let box = bridge.remove(r, "cast") as? CastBox
            box?.client?.disconnect()
            box?.push(.closed)
            return Reply()

        // MARK: Links
        case "openLink":
            // "youtube" (a watch URL), "web" (any http link) or "text" (typed on the TV).
            let adb = try connection(r, bridge)
            let value = try string(r, "value")
            let message: String
            switch try string(r, "kind") {
            case "youtube":
                guard let url = URL(string: value) else { throw BridgeError("bad link") }
                message = try await LinkOpener.openYouTube(url, via: adb) { bridge.setProgress(r, ["status": $0]) }
            case "web":
                guard let url = URL(string: value) else { throw BridgeError("bad link") }
                message = try await LinkOpener.openWeb(url, via: adb)
            default:
                message = try await LinkOpener.type(value, via: adb)
            }
            return Reply(["message": message])
        case "youtubeWatchURL":
            let url = URL(string: try string(r, "url")).flatMap(LinkOpener.youtubeWatchURL)
            return Reply(url.map { ["url": $0.absoluteString] } ?? [:])

        default:
            throw BridgeError("unknown op \(op)")
        }
    }

    // MARK: Helpers

    static func connection(_ r: JSON, _ bridge: Bridge) throws -> AdbConnection {
        let box: ConnectionBox = try bridge.object(r, "id")
        return box.adb
    }

    static func viewer(_ r: JSON, _ bridge: Bridge) throws -> ViewerClient {
        let box: CastBox = try bridge.object(r, "cast")
        guard let client = box.client, !client.isClosed else { throw BridgeError("The TV viewer isn't connected") }
        return client
    }

    static func string(_ r: JSON, _ field: String) throws -> String {
        guard let value = r[field] as? String else { throw BridgeError("missing \(field)") }
        return value
    }

    static func int(_ r: JSON, _ field: String) throws -> Int {
        if let value = r[field] as? Int { return value }
        if let value = r[field] as? Double { return Int(value) }
        throw BridgeError("missing \(field)")
    }

    /// Contents of the file at the path in `field` (nil when the field is absent).
    static func file(_ r: JSON, _ field: String) throws -> Data? {
        guard let path = r[field] as? String else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}
