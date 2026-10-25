import CAdbCrypto
import Foundation
#if canImport(Network)
import Network
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// A byte pipe. `enqueue` must keep call order, so writers can serialize
/// with a lock and then wait for completion outside it.
protocol AdbTransport: AnyObject, Sendable {
    /// Returns at least one byte, or throws on EOF/error.
    func receive(max: Int) async throws -> Data
    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    func close()
}

extension AdbTransport {
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            enqueue(data) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}

#if canImport(Network)
final class TCPTransport: AdbTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "adb.tcp")

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func start(timeout: Double = 8) async throws {
        let connection = connection
        let queue = queue
        // The handler stays installed: after a timeout, cancel() delivers .cancelled,
        // which resumes the pending continuation (later states are ignored).
        do {
          try await withTimeout(timeout, "connecting") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let resumed = Box(false)
                connection.stateUpdateHandler = { state in
                    let finish: (Error?) -> Void = { error in
                        guard !resumed.value else { return }
                        resumed.value = true
                        if let error { c.resume(throwing: error) } else { c.resume() }
                    }
                    switch state {
                    case .ready: finish(nil)
                    case .failed(let error): finish(AdbError.connectionFailed(error.localizedDescription))
                    case .waiting(let error): finish(AdbError.connectionFailed(error.localizedDescription))
                    case .cancelled: finish(AdbError.closed)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
          }
        } catch {
            connection.cancel()
            throw error
        }
    }

    func receive(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if let error {
                    c.resume(throwing: AdbError.connectionFailed(error.localizedDescription))
                } else if isComplete {
                    c.resume(throwing: AdbError.closed)
                } else {
                    c.resume(throwing: AdbError.closed)
                }
            }
        }
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error.map { AdbError.connectionFailed($0.localizedDescription) })
        })
    }

    func close() {
        connection.cancel()
    }
}
#else
/// Plain sockets where Network.framework doesn't exist (Android, Linux). Reads and
/// writes block on their own serial queues; `close` shuts the socket down to wake them.
final class TCPTransport: AdbTransport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private let readQueue = DispatchQueue(label: "adb.tcp.read")
    private let writeQueue = DispatchQueue(label: "adb.tcp.write")

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    deinit {
        if fd >= 0 { Posix.close(fd) }
    }

    func start(timeout: Double = 8) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    try self.connect(timeout: timeout)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    private func connect(timeout: Double) throws {
        guard let address = PortScanner.resolveIPv4(host) else { throw AdbError.connectionFailed("cannot resolve \(host)") }
        let fd = Posix.tcpSocket()
        guard fd >= 0 else { throw AdbError.connectionFailed("no socket") }
        let isClosed = lock.withLock { () -> Bool in
            if !closed { self.fd = fd }
            return closed
        }
        if isClosed {
            Posix.close(fd)
            throw AdbError.closed
        }
        Posix.setNonBlocking(fd, true)
        if Posix.connect(fd, Posix.ipv4(address, port: port)) != 0 {
            guard errno == EINPROGRESS else { throw AdbError.connectionFailed(String(cString: strerror(errno))) }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            if n == 0 { throw AdbError.timeout("connecting") }
            let err = n < 0 ? errno : Posix.socketError(fd)
            if err != 0 { throw AdbError.connectionFailed(String(cString: strerror(err))) }
        }
        if lock.withLock({ closed }) { throw AdbError.closed }
        Posix.setNonBlocking(fd, false)
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, size)
        var idle: Int32 = 15
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPIDLE, &idle, size)
    }

    private var socket: Int32? {
        lock.withLock { closed || fd < 0 ? nil : fd }
    }

    func receive(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            readQueue.async {
                guard let fd = self.socket else { return c.resume(throwing: AdbError.closed) }
                var buf = [UInt8](repeating: 0, count: Swift.min(max, 65536))
                while true {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n > 0 { return c.resume(returning: Data(buf[0..<n])) }
                    if n < 0, errno == EINTR { continue }
                    if n == 0 || self.socket == nil { return c.resume(throwing: AdbError.closed) }
                    return c.resume(throwing: AdbError.connectionFailed(String(cString: strerror(errno))))
                }
            }
        }
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        writeQueue.async {
            guard let fd = self.socket else { return completion(AdbError.closed) }
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { raw in
                    Posix.send(fd, raw.baseAddress! + offset, data.count - offset)
                }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return completion(AdbError.connectionFailed(String(cString: strerror(errno)))) }
                offset += n
            }
            completion(nil)
        }
    }

    func close() {
        lock.withLock {
            closed = true
            // The descriptor itself is closed in deinit, so a blocked read never sees it reused.
            if fd >= 0 { _ = shutdown(fd, Int32(SHUT_RDWR)) }
        }
    }
}
#endif

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// TLS 1.3 client (BoringSSL) layered over another transport.
final class TLSTransport: AdbTransport, @unchecked Sendable {
    private let inner: AdbTransport
    private let tls: OpaquePointer
    private let lock = NSLock()
    private let readLock = AsyncLock()

    init(inner: AdbTransport, key: AdbKey) throws {
        guard let tls = adb_tls_new(key.raw) else { throw AdbError.tls("cannot create TLS context") }
        self.inner = inner
        self.tls = tls
    }

    deinit {
        adb_tls_free(tls)
    }

    private func lastError() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        adb_tls_last_error(&buf, buf.count)
        return String(cString: buf)
    }

    /// Moves pending ciphertext to the network. Caller holds `lock`.
    private func flushLocked(completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = adb_tls_take_output(tls, &buf, buf.count)
            if n == 0 { break }
            out.append(buf, count: n)
        }
        if out.isEmpty {
            completion(nil)
        } else {
            inner.enqueue(out, completion: completion)
        }
    }

    private func handshakeStep() -> Int32 {
        lock.withLock {
            let r = adb_tls_handshake(tls)
            flushLocked()
            return r
        }
    }

    private func readStep(_ buf: inout [UInt8]) -> Int32 {
        lock.withLock {
            let n = adb_tls_read(tls, &buf, buf.count)
            flushLocked()
            return n
        }
    }

    private func feed(_ data: Data) {
        lock.withLock {
            data.withUnsafeBytes { adb_tls_feed(tls, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        }
    }

    func handshake() async throws {
        while true {
            let r = handshakeStep()
            if r == 1 { return }
            if r < 0 { throw AdbError.tls(lastError()) }
            feed(try await inner.receive(max: 65536))
        }
    }

    func exportKeyingMaterial(label: [UInt8], length: Int) throws -> Data {
        var out = [UInt8](repeating: 0, count: length)
        let ok = lock.withLock {
            label.withUnsafeBufferPointer { l in
                l.baseAddress!.withMemoryRebound(to: CChar.self, capacity: l.count) {
                    adb_tls_export_keying_material(tls, &out, length, $0, l.count)
                }
            }
        }
        guard ok == 1 else { throw AdbError.tls("keying material export failed") }
        return Data(out)
    }

    func receive(max: Int) async throws -> Data {
        // Single reader at a time; writers only take the short `lock`.
        await readLock.acquire()
        defer { readLock.release() }
        var buf = [UInt8](repeating: 0, count: Swift.min(max, 65536))
        while true {
            let n = readStep(&buf)
            if n > 0 { return Data(buf[0..<Int(n)]) }
            if n < 0 { throw AdbError.closed }
            feed(try await inner.receive(max: 65536))
        }
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw -> Int32 in
                let p = raw.bindMemory(to: UInt8.self).baseAddress! + offset
                return adb_tls_write(tls, p, data.count - offset)
            }
            if n <= 0 {
                completion(AdbError.tls(lastError()))
                return
            }
            offset += Int(n)
        }
        flushLocked(completion: completion)
    }

    func close() {
        inner.close()
    }
}

/// Reads exact byte counts from a transport. Not thread-safe: one reader only.
final class BufferedReader: @unchecked Sendable {
    let transport: AdbTransport
    private var buffer = Data()

    init(_ transport: AdbTransport) {
        self.transport = transport
    }

    func read(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await transport.receive(max: Swift.max(65536, count - buffer.count)))
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }
}
