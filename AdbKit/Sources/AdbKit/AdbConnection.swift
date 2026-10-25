import Foundation

public enum ConnectEvent: Sendable {
    /// The device does not know this app's key yet; the user must tap "Allow" on it.
    case waitingForUserApproval
    case upgradedToTLS
}

/// One authenticated ADB session with a device (adbd), multiplexing streams.
public final class AdbConnection: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    /// Raw banner from the device, e.g. "device::ro.product.name=...;features=...".
    public let banner: String
    public let features: Set<String>
    public let properties: [String: String]
    public let usesTLS: Bool

    let maxPayload: Int
    private let transport: AdbTransport
    private let reader: BufferedReader
    private let lock = NSLock()
    private var streams: [UInt32: AdbStream] = [:]
    private var nextLocalId: UInt32 = 1
    private var closedError: Error?
    private var disconnectHandlers: [@Sendable (Error) -> Void] = []

    private init(host: String, port: UInt16, transport: AdbTransport, reader: BufferedReader,
                 banner: String, maxPayload: Int, usesTLS: Bool) {
        self.host = host
        self.port = port
        self.transport = transport
        self.reader = reader
        self.banner = banner
        self.maxPayload = maxPayload
        self.usesTLS = usesTLS
        var props: [String: String] = [:]
        var features: Set<String> = []
        // banner: "<state>::key=value;key=value;features=a,b,c"
        if let range = banner.range(of: "::") {
            for pair in banner[range.upperBound...].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                if kv[0] == "features" {
                    features = Set(kv[1].split(separator: ",").map(String.init))
                } else {
                    props[kv[0]] = kv[1]
                }
            }
        }
        self.properties = props
        self.features = features
    }

    /// Features we implement; adbd only enables protocol variants both sides list.
    static let hostFeatures = "shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,abb_exec"

    public static func connect(
        host: String,
        port: UInt16,
        key: AdbKey,
        approvalTimeout: Double = 60,
        onEvent: @escaping @Sendable (ConnectEvent) -> Void = { _ in }
    ) async throws -> AdbConnection {
        let tcp = TCPTransport(host: host, port: port)
        try await tcp.start()
        var transport: AdbTransport = tcp
        var reader = BufferedReader(tcp)
        var usesTLS = false
        var sentSignature = false
        var sentPublicKey = false
        do {
            try await tcp.send(AdbMessage(AdbMessage.cnxn, AdbMessage.version, AdbMessage.maxPayload,
                                          Data(cString: "host::features=\(hostFeatures)")).encoded)
            while true {
                let r = reader
                let message = try await withTimeout(sentPublicKey ? approvalTimeout : 10, "device handshake") {
                    try await AdbMessage.read(from: r)
                }
                switch message.command {
                case AdbMessage.stls:
                    try await tcp.send(AdbMessage(AdbMessage.stls, AdbMessage.stlsVersion, 0).encoded)
                    let tls = try TLSTransport(inner: tcp, key: key)
                    do {
                        try await withTimeout(10, "TLS handshake") { try await tls.handshake() }
                    } catch {
                        // adbd closes the TLS session when the key is not paired/authorized.
                        throw AdbError.tls("handshake failed (pair this device first): \(error.localizedDescription)")
                    }
                    transport = tls
                    reader = BufferedReader(tls)
                    usesTLS = true
                    onEvent(.upgradedToTLS)
                case AdbMessage.auth where message.arg0 == AdbMessage.authToken:
                    if !sentSignature {
                        sentSignature = true
                        let signature = try key.signToken(message.payload)
                        try await transport.send(AdbMessage(AdbMessage.auth, AdbMessage.authSignature, 0, signature).encoded)
                    } else if !sentPublicKey {
                        sentPublicKey = true
                        try await transport.send(AdbMessage(AdbMessage.auth, AdbMessage.authPublicKey, 0,
                                                            Data(cString: key.androidPublicKey)).encoded)
                        onEvent(.waitingForUserApproval)
                    } else {
                        throw AdbError.authRejected
                    }
                case AdbMessage.cnxn:
                    let banner = String(decoding: message.payload.prefix { $0 != 0 }, as: UTF8.self)
                    let connection = AdbConnection(
                        host: host, port: port, transport: transport, reader: reader, banner: banner,
                        maxPayload: Int(min(message.arg1, AdbMessage.maxPayload)), usesTLS: usesTLS)
                    connection.startReading()
                    return connection
                default:
                    continue
                }
            }
        } catch {
            transport.close()
            if sentPublicKey, case AdbError.timeout = error { throw AdbError.authRejected }
            throw error
        }
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedError != nil
    }

    /// Called once when the session ends (network drop, device reboot, `close()`).
    public func onDisconnect(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        if let error = closedError {
            lock.unlock()
            handler(error)
            return
        }
        disconnectHandlers.append(handler)
        lock.unlock()
    }

    public func close() {
        fail(AdbError.closed)
    }

    // MARK: Streams

    /// Opens a service such as "shell:ls", "sync:", "tcp:8080" or "localabstract:scrcpy".
    public func open(_ service: String) async throws -> AdbStream {
        let stream = try register(service)
        try await send(AdbMessage(AdbMessage.open, stream.localId, 0, Data(cString: service)))
        try await stream.waitUntilOpen()
        return stream
    }

    /// Round trip to adbd without starting anything on the device: it refuses an
    /// unknown service right away, so this measures network + adbd only.
    public func ping(timeout: Double = 5) async throws -> TimeInterval {
        let start = Date()
        do {
            try await withTimeout(timeout, "ping") {
                let stream = try await self.open("adbremote-ping:")
                stream.close()
            }
        } catch AdbError.openFailed {
            // Expected answer.
        }
        return Date().timeIntervalSince(start)
    }

    private func register(_ service: String) throws -> AdbStream {
        try lock.withLock {
            if let error = closedError { throw error }
            let localId = nextLocalId
            nextLocalId &+= 1
            if nextLocalId == 0 { nextLocalId = 1 }
            let stream = AdbStream(connection: self, localId: localId, service: service)
            streams[localId] = stream
            return stream
        }
    }

    func send(_ message: AdbMessage) async throws {
        try await transport.send(message.encoded)
    }

    func sendWithoutWaiting(_ message: AdbMessage) {
        transport.enqueue(message.encoded) { _ in }
    }

    func forget(_ stream: AdbStream) {
        lock.lock()
        streams.removeValue(forKey: stream.localId)
        lock.unlock()
    }

    private func stream(_ id: UInt32) -> AdbStream? {
        lock.lock()
        defer { lock.unlock() }
        return streams[id]
    }

    private func startReading() {
        Task.detached { [self] in
            do {
                while true {
                    let message = try await AdbMessage.read(from: reader)
                    switch message.command {
                    case AdbMessage.okay:
                        stream(message.arg1)?.handleOkay(remoteId: message.arg0)
                    case AdbMessage.wrte:
                        if let stream = stream(message.arg1) {
                            stream.handleData(message.payload)
                        } else {
                            sendWithoutWaiting(AdbMessage(AdbMessage.clse, message.arg1, message.arg0))
                        }
                    case AdbMessage.clse:
                        if let stream = stream(message.arg1) {
                            stream.handleRemoteClose()
                            forget(stream)
                        }
                    default:
                        break
                    }
                }
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard closedError == nil else {
            lock.unlock()
            return
        }
        closedError = error
        let open = Array(streams.values)
        streams.removeAll()
        let handlers = disconnectHandlers
        disconnectHandlers.removeAll()
        lock.unlock()
        transport.close()
        for stream in open { stream.handleRemoteClose(error: error) }
        for handler in handlers { handler(error) }
    }
}
