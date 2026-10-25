import Foundation

/// A bidirectional ADB stream (one OPENed service).
public final class AdbStream: @unchecked Sendable {
    let localId: UInt32
    public let service: String
    private let connection: AdbConnection
    private let lock = NSLock()
    private let writeLock = AsyncLock()

    private var remoteId: UInt32 = 0
    private var opened = false
    private var openWaiter: CheckedContinuation<Void, Error>?
    /// Device acknowledged our last WRTE (or the OPEN); we may send another.
    private var canWrite = false
    private var writeWaiter: CheckedContinuation<Void, Error>?

    private var buffer = Data()
    private var readWaiter: CheckedContinuation<Void, Never>?
    /// We hold the OKAY for incoming data while the buffer is large, so a slow
    /// reader throttles the device instead of growing memory without bound.
    private var ackPending = false
    private static let highWater = 2 * 1024 * 1024

    private var remoteClosed = false
    private var closeError: Error?
    private var locallyClosed = false

    init(connection: AdbConnection, localId: UInt32, service: String) {
        self.connection = connection
        self.localId = localId
        self.service = service
    }

    // MARK: Called by the connection's reader

    func handleOkay(remoteId: UInt32) {
        lock.lock()
        self.remoteId = remoteId
        if !opened {
            opened = true
            canWrite = true
            let waiter = openWaiter
            openWaiter = nil
            lock.unlock()
            waiter?.resume()
            return
        }
        canWrite = true
        let waiter = writeWaiter
        writeWaiter = nil
        if waiter != nil { canWrite = false }
        lock.unlock()
        waiter?.resume()
    }

    func handleData(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let ack = buffer.count < Self.highWater
        if !ack { ackPending = true }
        let waiter = readWaiter
        readWaiter = nil
        let remote = remoteId
        lock.unlock()
        if ack { connection.sendWithoutWaiting(AdbMessage(AdbMessage.okay, localId, remote)) }
        waiter?.resume()
    }

    func handleRemoteClose(error: Error? = nil) {
        lock.lock()
        remoteClosed = true
        closeError = error
        let open = openWaiter
        let write = writeWaiter
        let read = readWaiter
        let wasOpened = opened
        openWaiter = nil
        writeWaiter = nil
        readWaiter = nil
        lock.unlock()
        open?.resume(throwing: error ?? (wasOpened ? AdbError.closed : AdbError.openFailed(service)))
        write?.resume(throwing: error ?? AdbError.closed)
        read?.resume()
    }

    func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if opened {
                lock.unlock()
                c.resume()
            } else if remoteClosed {
                lock.unlock()
                c.resume(throwing: closeError ?? AdbError.openFailed(service))
            } else {
                openWaiter = c
                lock.unlock()
            }
        }
    }

    // MARK: Public API

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remoteClosed || locallyClosed
    }

    public func write(_ data: Data) async throws {
        await writeLock.acquire()
        defer { writeLock.release() }
        var offset = 0
        let chunk = connection.maxPayload
        repeat {
            try await waitForWriteSlot()
            let end = min(offset + chunk, data.count)
            try await connection.send(AdbMessage(AdbMessage.wrte, localId, remoteId, data.subdata(in: offset..<end)))
            offset = end
        } while offset < data.count
    }

    public func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    private func waitForWriteSlot() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if remoteClosed || locallyClosed {
                lock.unlock()
                c.resume(throwing: closeError ?? AdbError.closed)
            } else if canWrite {
                canWrite = false
                lock.unlock()
                c.resume()
            } else {
                writeWaiter = c
                lock.unlock()
            }
        }
    }

    private enum ReadState {
        case data(Data, ack: UInt32?)
        case end(Error?)
        case empty
    }

    private func takeAvailable(max: Int) -> ReadState {
        lock.withLock {
            if !buffer.isEmpty {
                let count = min(max, buffer.count)
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                var ack: UInt32?
                if ackPending && buffer.count < Self.highWater / 2 {
                    ackPending = false
                    ack = remoteId
                }
                return .data(out, ack: ack)
            }
            if remoteClosed || locallyClosed { return .end(closeError) }
            return .empty
        }
    }

    /// Parks the reader until data or close arrives; false if something already did.
    private func park(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.withLock {
            guard buffer.isEmpty, !remoteClosed, !locallyClosed else { return false }
            readWaiter = c
            return true
        }
    }

    /// Returns available data (up to `max` bytes), or nil at end of stream.
    public func read(max: Int = .max) async throws -> Data? {
        while true {
            switch takeAvailable(max: max) {
            case .data(let out, let ack):
                if let ack { connection.sendWithoutWaiting(AdbMessage(AdbMessage.okay, localId, ack)) }
                return out
            case .end(let error):
                if let error, (error as? AdbError) != .closed { throw error }
                return nil
            case .empty:
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    if !park(c) { c.resume() }
                }
            }
        }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        var out = Data(capacity: count)
        while out.count < count {
            guard let chunk = try await read(max: count - out.count) else {
                throw AdbError.protocolError("stream ended early (\(service))")
            }
            out.append(chunk)
        }
        return out
    }

    /// Reads until the device closes the stream.
    public func readAll() async throws -> Data {
        var out = Data()
        while let chunk = try await read() { out.append(chunk) }
        return out
    }

    public func close() {
        lock.lock()
        guard !locallyClosed else {
            lock.unlock()
            return
        }
        locallyClosed = true
        let remote = remoteId
        let wasRemoteClosed = remoteClosed
        let write = writeWaiter
        let read = readWaiter
        writeWaiter = nil
        readWaiter = nil
        lock.unlock()
        write?.resume(throwing: AdbError.closed)
        read?.resume()
        if !wasRemoteClosed {
            connection.sendWithoutWaiting(AdbMessage(AdbMessage.clse, localId, remote))
        }
        connection.forget(self)
    }

}
