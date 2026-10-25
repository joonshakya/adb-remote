import AdbKit
import CAdbBridgeJNI
import Foundation

// The Android app's way into AdbKit. Kotlin sends one JSON request per call
// ({"op": "...", ...}) plus optional bytes, and gets JSON back (plus optional bytes).
// Calls block the calling Kotlin thread (Kotlin runs them on Dispatchers.IO).
// Live objects (connections, remotes, screens) are kept here and referred to by number.
//
// Long calls can take a "request" id: their progress is read with op "progress" and
// they can be stopped with op "cancel".

struct BridgeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias JSON = [String: Any]

/// A reply: JSON and optional binary payload.
struct Reply {
    var json: JSON
    var data = Data()
    init(_ json: JSON = [:], data: Data = Data()) {
        self.json = json
        self.data = data
    }
}

final class Bridge: @unchecked Sendable {
    static let shared = Bridge()

    private let lock = NSLock()
    private var objects: [Int: AnyObject] = [:]
    private var nextID = 1
    private var progress: [String: JSON] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var key: AdbKey?

    // MARK: Object table

    func store(_ object: AnyObject) -> Int {
        lock.withLock {
            let id = nextID
            nextID += 1
            objects[id] = object
            return id
        }
    }

    func object<T>(_ request: JSON, _ field: String, as type: T.Type = T.self) throws -> T {
        guard let id = request[field] as? Int else { throw BridgeError("missing \(field)") }
        guard let object = lock.withLock({ objects[id] }) as? T else { throw BridgeError("\(field) \(id) is gone") }
        return object
    }

    func remove(_ request: JSON, _ field: String) -> AnyObject? {
        guard let id = request[field] as? Int else { return nil }
        return lock.withLock { objects.removeValue(forKey: id) }
    }

    func setProgress(_ request: JSON, _ value: JSON) {
        guard let id = request["request"] as? String else { return }
        lock.withLock { progress[id] = value }
    }

    func adbKey() throws -> AdbKey {
        guard let key = lock.withLock({ key }) else { throw BridgeError("call init first") }
        return key
    }

    // MARK: Calls

    func call(_ request: JSON, input: Data) -> Reply {
        guard let op = request["op"] as? String else { return Reply(["error": "missing op"]) }
        do {
            switch op {
            // Quick calls that don't need async.
            case "init":
                guard let path = request["keyPath"] as? String else { throw BridgeError("missing keyPath") }
                let key = try AdbKey.loadOrCreate(at: URL(fileURLWithPath: path), name: request["name"] as? String ?? "AdbRemote@Android")
                lock.withLock { self.key = key }
                return Reply(["publicKey": key.androidPublicKey])
            case "progress":
                let id = request["request"] as? String ?? ""
                return Reply(lock.withLock { progress[id] } ?? [:])
            case "cancel":
                let id = request["request"] as? String ?? ""
                lock.withLock { tasks[id] }?.cancel()
                return Reply()
            default:
                return try runBlocking(request) { try await Ops.run(op, request, input: input, bridge: self) }
            }
        } catch {
            return Reply(["error": error.localizedDescription])
        }
    }

    /// Runs async work to completion on Swift's thread pool while the Kotlin thread waits.
    private func runBlocking(_ request: JSON, _ body: @escaping @Sendable () async throws -> Reply) throws -> Reply {
        let requestID = request["request"] as? String
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        let task = Task.detached {
            do { result.value = .success(try await body()) } catch { result.value = .failure(error) }
            done.signal()
        }
        if let requestID { lock.withLock { tasks[requestID] = task } }
        done.wait()
        if let requestID {
            lock.withLock {
                tasks[requestID] = nil
                progress[requestID] = nil
            }
        }
        switch result.value! {
        case .success(let reply): return reply
        case .failure(let error):
            if error is CancellationError { return Reply(["error": "Cancelled", "cancelled": true]) }
            throw error
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<Reply, Error>?
}

// MARK: C entry point

@_cdecl("adbbridge_call")
public func adbbridge_call(_ request: UnsafePointer<CChar>, _ input: UnsafePointer<UInt8>?, _ inputLength: Int,
                           _ outLength: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UInt8> {
    let text = String(cString: request)
    let input = input.map { Data(bytes: $0, count: inputLength) } ?? Data()
    let reply: Reply
    if let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSON {
        reply = Bridge.shared.call(json, input: input)
    } else {
        reply = Reply(["error": "bad request"])
    }
    let body = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data("{}".utf8)
    let total = 4 + body.count + reply.data.count
    let out = malloc(max(total, 1))!.assumingMemoryBound(to: UInt8.self)
    let length = UInt32(body.count)
    out[0] = UInt8(length >> 24)
    out[1] = UInt8(length >> 16 & 0xff)
    out[2] = UInt8(length >> 8 & 0xff)
    out[3] = UInt8(length & 0xff)
    body.copyBytes(to: out + 4, count: body.count)
    reply.data.copyBytes(to: out + 4 + body.count, count: reply.data.count)
    outLength.pointee = total
    return out
}
