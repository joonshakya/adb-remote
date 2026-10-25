import AdbKit
import Foundation
import Observation
import UIKit

/// Connection state and cached data for one saved device.
@MainActor @Observable
final class DeviceSession {
    enum State: Equatable {
        case disconnected
        case connecting(String)
        case waitingForApproval
        case connected
        case failed(String)
    }

    struct ScanState {
        var scanned = 0
        var total = 1
        var openPorts: [UInt16] = []
        var probing = false
    }

    let deviceID: UUID
    private unowned let store: DeviceStore

    private(set) var state: State = .disconnected
    private(set) var connection: AdbConnection?
    private(set) var info: DeviceInfo?
    private(set) var extras: DeviceExtras?
    var speedTest: SpeedTestResult?
    var speedTestStatus: String?

    /// Set when the default port was refused: UI asks whether to scan.
    var offerPortScan = false
    private(set) var scan: ScanState?
    /// More than one ADB port found: UI lets the user pick.
    var portChoices: [(port: UInt16, kind: AdbProbe)] = []
    /// The device wants TLS but doesn't know our key: UI offers pairing.
    var needsPairing = false

    /// Result of the last quick port check (nil = not checked yet).
    private(set) var reachable: Bool?

    /// Key/text sender, created when the remote is first used.
    private(set) var remote: RemoteInput?
    private(set) var remoteReady = false
    var remoteError: String?

    private var apps: AppsModel?
    private var files: FilesModel?
    private var screen: ScreenModel?
    private var cast: CastModel?

    private var wantsConnection = false
    private var scanTask: Task<Void, Never>?

    /// Latest round trip to the device's adbd (nil = not measured / no answer).
    private(set) var latency: TimeInterval?
    private(set) var latencyTimedOut = false
    private var pingTask: Task<Void, Never>?

    init(deviceID: UUID, store: DeviceStore) {
        self.deviceID = deviceID
        self.store = store
    }

    var device: SavedDevice? { store.device(deviceID) }
    var isConnected: Bool { state == .connected }
    var shouldAutoReconnect: Bool { wantsConnection && connection == nil && !isBusy }
    var isBusy: Bool {
        switch state {
        case .connecting, .waitingForApproval: true
        default: scan != nil
        }
    }

    // MARK: Connect

    func connect() async {
        guard let device, !isBusy else { return }
        wantsConnection = true
        needsPairing = false
        guard await NetworkStatus.shared.check() else {
            state = .failed(NetworkStatus.wifiOffMessage)
            store.wifiPrompt = true
            return
        }
        if let port = device.port {
            await connect(port: port)
            return
        }
        // Auto port: last working port, then 5555, then ask about scanning.
        var candidates: [UInt16] = []
        if let last = device.lastPort { candidates.append(last) }
        if !candidates.contains(5555) { candidates.append(5555) }
        for port in candidates {
            if await connect(port: port, quiet: true) { return }
            if case .failed = state, !isUnreachable(lastError) { return }
            if !NetworkStatus.shared.onLocalNetwork {
                state = .failed(NetworkStatus.wifiOffMessage)
                store.wifiPrompt = true
                return
            }
        }
        state = .failed("No ADB on port \(candidates.map(String.init).joined(separator: ", "))")
        offerPortScan = true
    }

    private var lastError: Error?

    private func isUnreachable(_ error: Error?) -> Bool {
        guard let error = error as? AdbError else { return true }
        switch error {
        case .connectionFailed, .timeout, .closed: return true
        default: return false
        }
    }

    @discardableResult
    func connect(port: UInt16, quiet: Bool = false) async -> Bool {
        guard let device else { return false }
        state = .connecting("Connecting to \(device.host):\(port)")
        lastError = nil
        do {
            let connection = try await AdbConnection.connect(host: device.host, port: port, key: store.key) { event in
                Task { @MainActor [weak self] in
                    if case .waitingForUserApproval = event { self?.state = .waitingForApproval }
                }
            }
            attach(connection, port: port)
            return true
        } catch {
            lastError = error
            log("connect to port \(port) failed: \(error.localizedDescription)")
            if case AdbError.tls = error { needsPairing = true }
            state = .failed(await NetworkStatus.shared.check() ? error.localizedDescription : NetworkStatus.wifiOffMessage)
            return false
        }
    }

    private func attach(_ connection: AdbConnection, port: UInt16) {
        self.connection = connection
        state = .connected
        log("connected to port \(port)\(connection.usesTLS ? " (encrypted)" : "")")
        if var device, device.port == nil, device.lastPort != port {
            device.lastPort = port
            store.update(device)
        }
        connection.onDisconnect { [weak self] error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.log("disconnected: \(error.localizedDescription)")
                self.connection = nil
                self.resetRemote()
                self.state = .failed(NetworkStatus.shared.onLocalNetwork
                    ? "Disconnected: \(error.localizedDescription)" : NetworkStatus.wifiOffMessage)
            }
        }
        startPinging(connection)
        Task {
            guard await checkAcceptsCommands(connection) else { return }
            await refreshInfo()
        }
    }

    /// Some devices keep the connection up but refuse everything once ADB access is switched
    /// off on them (BlueStacks does this). Pings still succeed then, so try a real command.
    private func checkAcceptsCommands(_ connection: AdbConnection) async -> Bool {
        do {
            _ = try await connection.shell("echo")
            return true
        } catch {
            guard self.connection === connection else { return false }
            log("connected but commands are refused: \(error.localizedDescription)")
            wantsConnection = false
            self.connection = nil
            resetRemote()
            connection.close()
            state = .failed("Connected, but \(device?.name ?? "the device") is refusing commands. Turn its debugging access back on "
                + "(BlueStacks: Settings → Advanced → Android Debug Bridge; Android: Developer options → USB / Wireless debugging), then tap Retry.")
            return false
        }
    }

    /// Measures latency every 2 s while connected, for the indicator in the title bar.
    /// Shows "No reply" after 3 s. After 10 s the connection is treated as stuck and replaced:
    /// a stalled TCP connection can stay silent for minutes while a new one works at once.
    private func startPinging(_ connection: AdbConnection) {
        pingTask?.cancel()
        latency = nil
        latencyTimedOut = false
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date()
                let watchdog = Task { @MainActor [weak self] in
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.latency = nil
                    self?.latencyTimedOut = true
                    try await Task.sleep(nanoseconds: 7_000_000_000)
                    self?.replaceStalled(connection, since: started)
                }
                do {
                    let rtt = try await connection.ping(timeout: 20)
                    watchdog.cancel()
                    guard let self, !Task.isCancelled else { return }
                    self.latency = rtt
                    self.latencyTimedOut = false
                    self.log("ping \(Int(rtt * 1000))ms\(self.activitySummary)")
                } catch {
                    watchdog.cancel()
                    guard let self, !Task.isCancelled else { return }
                    if connection.isClosed { return }
                    self.latency = nil
                    self.latencyTimedOut = true
                    self.log("ping FAILED after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error.localizedDescription)\(self.activitySummary)")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func replaceStalled(_ stalled: AdbConnection, since started: Date) {
        // Time spent in the background doesn't count: iOS pauses the app's connections there.
        guard connection === stalled, store.lastBackgrounded < started,
              UIApplication.shared.applicationState == .active else { return }
        log("no reply for 10s, reconnecting\(activitySummary)")
        connection = nil
        resetRemote()
        stalled.close()
        Task { await connect(port: stalled.port) }
    }

    /// What else is using the connection, appended to ping lines.
    private var activitySummary: String {
        var parts: [String] = []
        if screen?.isRunning == true { parts.append("screen") }
        if let cast, cast.state == .ready { parts.append(cast.direct ? "cast-wifi" : "cast-adb") }
        if pendingInputs > 0 { parts.append("inputs-queued=\(pendingInputs)") }
        return parts.isEmpty ? "" : " [" + parts.joined(separator: ",") + "]"
    }

    func log(_ message: String) {
        EventLog.shared.log(device?.name ?? deviceID.uuidString, message)
    }

    func disconnect() {
        if connection != nil { log("disconnected by user") }
        wantsConnection = false
        resetRemote()
        scanTask?.cancel()
        connection?.close()
        connection = nil
        state = .disconnected
    }

    // MARK: Apps

    /// App list for this device, created on first use and kept while connected.
    func appsModel() -> AppsModel? {
        if let apps { return apps }
        guard let connection, let info else { return nil }
        apps = AppsModel(connection: connection, sdk: info.sdk)
        return apps
    }

    func screenModel() -> ScreenModel? {
        if let screen { return screen }
        guard let connection, let info else { return nil }
        let screen = ScreenModel(connection: connection, sdk: info.sdk)
        screen.log = { [weak self] in self?.log($0) }
        self.screen = screen
        return screen
    }

    func castModel() -> CastModel? {
        if let cast { return cast }
        guard let connection, let info, let device else { return nil }
        let cast = CastModel(adb: connection, host: device.host, sdk: info.sdk)
        cast.log = { [weak self] in self?.log($0) }
        self.cast = cast
        return cast
    }

    func filesModel() -> FilesModel? {
        if let files { return files }
        guard let connection else { return nil }
        files = FilesModel(connection: connection)
        return files
    }

    // MARK: Reachability

    /// Cheap TCP check of the device's ADB port, for the online/offline badge.
    func checkReachability() async {
        guard let device else { return }
        if isConnected {
            reachable = true
            return
        }
        guard NetworkStatus.shared.onLocalNetwork else {
            reachable = false
            return
        }
        let port = device.port ?? device.lastPort ?? 5555
        let open = (try? await PortScanner.openPorts(host: device.host, ports: [port], timeout: 0.8)) ?? []
        reachable = !open.isEmpty
    }

    // MARK: Remote

    static let scrcpyServer: Data? = Bundle.main
        .url(forResource: "scrcpy-server-v\(ScrcpySession.version)", withExtension: nil)
        .flatMap { try? Data(contentsOf: $0) }

    /// Returns the remote input, starting it (scrcpy on Android 5+) on first use.
    func remoteInput() -> RemoteInput? {
        if let remote { return remote }
        guard let connection, let info else { return nil }
        let remote = RemoteInput(adb: connection, sdk: info.sdk, serverJar: Self.scrcpyServer, helperJar: AppsModel.helperJar)
        self.remote = remote
        remoteReady = false
        Task {
            do {
                try await remote.prepare()
                if self.remote === remote { remoteReady = true }
            } catch {
                remoteError = error.localizedDescription
            }
        }
        return remote
    }

    private var trackpadSender: PointerSender?

    /// Pointer sender for the trackpad (nil before info is loaded).
    func trackpad() -> PointerSender? {
        if let trackpadSender { return trackpadSender }
        guard let remote = remoteInput(), let connection, let info, let device,
              let apk = CastModel.apk, let jar = AppsModel.helperJar else { return nil }
        let sender = PointerSender(remote: remote, adb: connection, host: device.host, sdk: info.sdk, apk: apk, helperJar: jar) { error in
            Task { @MainActor [weak self] in self?.remoteError = error }
        }
        trackpadSender = sender
        return sender
    }

    typealias InputAction = (RemoteInput) async throws -> Void
    private var inputQueue: AsyncStream<(action: InputAction, queued: Date)>.Continuation?
    private var pendingInputs = 0

    /// Queues a remote action; actions run one at a time in order (typing stays in order).
    /// A failed action restarts the input channel and is retried once.
    func sendInput(_ action: @escaping InputAction) {
        guard let remote = remoteInput() else { return }
        if inputQueue == nil {
            let (stream, continuation) = AsyncStream.makeStream(of: (action: InputAction, queued: Date).self)
            inputQueue = continuation
            Task {
                for await (action, queued) in stream {
                    let started = Date()
                    // A press that couldn't go out for a while is dropped, not sent late.
                    if started.timeIntervalSince(queued) > 5 {
                        pendingInputs -= 1
                        log("input dropped after waiting \(Int(started.timeIntervalSince(queued) * 1000))ms")
                        continue
                    }
                    var outcome = "ok"
                    do {
                        try await action(remote)
                        remoteError = nil
                    } catch {
                        outcome = "retried after \(error.localizedDescription)"
                        remote.close()
                        do {
                            try await action(remote)
                            remoteError = nil
                        } catch {
                            outcome = "FAILED: \(error.localizedDescription)"
                            remoteError = error.localizedDescription
                        }
                    }
                    pendingInputs -= 1
                    let waited = Int(started.timeIntervalSince(queued) * 1000)
                    let took = Int(Date().timeIntervalSince(started) * 1000)
                    log("input waited \(waited)ms took \(took)ms via \(remote.backendName) \(outcome)")
                }
            }
        }
        pendingInputs += 1
        inputQueue?.yield((action, Date()))
    }

    private func resetRemote() {
        pingTask?.cancel()
        pingTask = nil
        latency = nil
        latencyTimedOut = false
        screen?.stop()
        screen = nil
        cast?.disconnect()
        cast = nil
        apps = nil
        files = nil
        inputQueue?.finish()
        inputQueue = nil
        pendingInputs = 0
        remote?.close()
        remote = nil
        trackpadSender = nil
        remoteReady = false
    }

    // MARK: Port scan

    func startPortScan() {
        guard let device else { return }
        offerPortScan = false
        portChoices = []
        scan = ScanState()
        state = .connecting("Scanning \(device.host) for open ports")
        scanTask = Task {
            do {
                let found = try await PortScanner.findAdbPorts(
                    host: device.host, preferred: device.lastPort.map { [$0] } ?? []
                ) { scanned, total, open in
                    Task { @MainActor [weak self] in
                        self?.scan?.scanned = scanned
                        self?.scan?.total = total
                        self?.scan?.openPorts = open
                        self?.scan?.probing = scanned == total
                    }
                }
                scan = nil
                switch found.count {
                case 0:
                    state = .failed("No ADB port found on \(device.host). Enable network debugging on the device.")
                case 1:
                    let ok = await connect(port: found[0].port)
                    if !ok && found[0].kind == .adbTLS { needsPairing = true }
                default:
                    portChoices = found
                    state = .disconnected
                }
            } catch {
                scan = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scan = nil
        state = .disconnected
    }

    // MARK: Info

    func refreshInfo() async {
        guard let connection else { return }
        do {
            let info = try await DeviceInfo.load(from: connection)
            self.info = info
            extras = try await DeviceExtras.load(from: connection, sdk: info.sdk)
        } catch {
            print("info failed: \(error)")
        }
    }

    func runSpeedTest() async {
        guard let connection else { return }
        speedTest = nil
        speedTestStatus = "Starting"
        // Old devices (4 KB packets) are slow; keep their test short.
        let bytes = (info?.sdk ?? 30) < 21 ? 1024 * 1024 : 8 * 1024 * 1024
        do {
            speedTest = try await connection.speedTest(bytes: bytes) { status in
                Task { @MainActor [weak self] in self?.speedTestStatus = status }
            }
            speedTestStatus = nil
        } catch {
            speedTestStatus = "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: Pairing

    func pair(port: UInt16, code: String) async throws {
        guard let device else { return }
        try await AdbPairing.pair(host: device.host, port: port, code: code, key: store.key)
        needsPairing = false
    }
}
