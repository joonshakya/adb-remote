import Foundation

extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func le32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }

    func le64(at offset: Int) -> UInt64 {
        UInt64(le32(at: offset)) | UInt64(le32(at: offset + 4)) << 32
    }

    func be32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) << 24 | UInt32(self[base + 1]) << 16 | UInt32(self[base + 2]) << 8 | UInt32(self[base + 3])
    }

    func be64(at offset: Int) -> UInt64 {
        UInt64(be32(at: offset)) << 32 | UInt64(be32(at: offset + 4))
    }
}

/// Four-character protocol ids ("CNXN", "STAT", ...) as little-endian integers.
func fourCC(_ s: StaticString) -> UInt32 {
    precondition(s.utf8CodeUnitCount == 4)
    let p = s.utf8Start
    return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
}

func fourCCString(_ v: UInt32) -> String {
    let bytes = [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]
    return String(decoding: bytes, as: UTF8.self)
}

/// Runs `operation`, failing with `AdbError.timeout` after `seconds`.
/// Returns as soon as the timer fires even if `operation` ignores cancellation
/// (e.g. a pending socket read); callers close the transport to unblock it.
func withTimeout<T: Sendable>(_ seconds: Double, _ what: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let state = TimeoutState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            guard state.install(c) else { return }
            let work = Task {
                do { state.finish(.success(try await operation())) } catch { state.finish(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                state.finish(.failure(AdbError.timeout(what)))
            }
            state.setCleanup { work.cancel(); timer.cancel() }
        }
    } onCancel: {
        state.finish(.failure(CancellationError()))
    }
}

private final class TimeoutState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var finished = false
    private var cleanup: (() -> Void)?

    /// Returns false if the result already arrived (e.g. cancelled early).
    func install(_ c: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if let pending {
            lock.unlock()
            c.resume(with: pending)
            return false
        }
        continuation = c
        lock.unlock()
        return true
    }

    func setCleanup(_ body: @escaping () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            body()
            return
        }
        cleanup = body
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished, pending == nil else {
            lock.unlock()
            return
        }
        guard let c = continuation else {
            pending = result
            lock.unlock()
            return
        }
        finished = true
        continuation = nil
        let body = cleanup
        cleanup = nil
        lock.unlock()
        c.resume(with: result)
        body?()
    }
}

public enum AdbError: LocalizedError, Equatable {
    case timeout(String)
    case connectionFailed(String)
    case closed
    case protocolError(String)
    case authRejected
    case openFailed(String)
    case tls(String)
    case pairing(String)
    case sync(String)
    case command(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let what): "Timed out: \(what)"
        case .connectionFailed(let why): "Connection failed: \(why)"
        case .closed: "Connection closed"
        case .protocolError(let why): "Protocol error: \(why)"
        case .authRejected: "Device rejected this app's key"
        case .openFailed: "The device refused the command. Its ADB / debugging access may have been turned off."
        case .tls(let why): "TLS error: \(why)"
        case .pairing(let why): "Pairing failed: \(why)"
        case .sync(let why): why
        case .command(let why): why
        }
    }
}

/// Minimal async mutex: waiters are resumed in FIFO order.
final class AsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if locked {
                waiters.append(c)
                lock.unlock()
            } else {
                locked = true
                lock.unlock()
                c.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
