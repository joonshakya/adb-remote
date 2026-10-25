import Foundation

public struct RemoteFile: Sendable, Hashable, Identifiable {
    public let name: String
    public let mode: UInt32
    public let size: UInt64
    public let modified: Date

    public var id: String { name }
    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }
    public var isRegularFile: Bool { mode & 0o170000 == 0o100000 }
}

/// ADB file sync protocol ("sync:" service): list, stat, pull, push.
public final class SyncSession: @unchecked Sendable {
    private let stream: AdbStream
    private let v2: Bool

    static let list1 = fourCC("LIST"), list2 = fourCC("LIS2")
    static let dent1 = fourCC("DENT"), dent2 = fourCC("DNT2")
    static let stat1 = fourCC("STAT"), stat2 = fourCC("STA2")
    static let send1 = fourCC("SEND"), recv1 = fourCC("RECV")
    static let data = fourCC("DATA"), done = fourCC("DONE")
    static let okay = fourCC("OKAY"), fail = fourCC("FAIL"), quit = fourCC("QUIT")
    static let maxChunk = 64 * 1024

    init(stream: AdbStream, v2: Bool) {
        self.stream = stream
        self.v2 = v2
    }

    private func request(_ id: UInt32, _ path: String) async throws {
        let bytes = Data(path.utf8)
        guard bytes.count <= 1024 else { throw AdbError.sync("path too long") }
        var d = Data()
        d.appendLE(id)
        d.appendLE(UInt32(bytes.count))
        d.append(bytes)
        try await stream.write(d)
    }

    private func readFail(_ length: UInt32) async throws -> Never {
        let message = try await stream.readExactly(Int(length))
        throw AdbError.sync(String(decoding: message, as: UTF8.self))
    }

    public func list(_ path: String) async throws -> [RemoteFile] {
        try await request(v2 ? Self.list2 : Self.list1, path)
        var entries: [RemoteFile] = []
        while true {
            let id = try await stream.readExactly(4).le32(at: 0)
            if id == Self.done {
                // DONE carries a dummy entry body.
                _ = try await stream.readExactly(v2 ? 72 : 16)
                break
            }
            if id == Self.fail { try await readFail(try await stream.readExactly(4).le32(at: 0)) }
            if id == Self.dent2 {
                let h = try await stream.readExactly(72)
                // error u32, dev u64, ino u64, mode u32, nlink, uid, gid, size u64, atime, mtime, ctime, namelen
                let name = String(decoding: try await stream.readExactly(Int(h.le32(at: 68))), as: UTF8.self)
                if h.le32(at: 0) != 0 { continue }
                entries.append(RemoteFile(name: name, mode: h.le32(at: 20), size: h.le64(at: 36),
                                          modified: Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: h.le64(at: 52))))))
            } else if id == Self.dent1 {
                let h = try await stream.readExactly(16)
                let name = String(decoding: try await stream.readExactly(Int(h.le32(at: 12))), as: UTF8.self)
                entries.append(RemoteFile(name: name, mode: h.le32(at: 0), size: UInt64(h.le32(at: 4)),
                                          modified: Date(timeIntervalSince1970: TimeInterval(h.le32(at: 8)))))
            } else {
                throw AdbError.protocolError("unexpected sync id \(fourCCString(id))")
            }
        }
        return entries.filter { $0.name != "." && $0.name != ".." }
    }

    /// Follows symlinks. Returns nil if the path does not exist.
    public func stat(_ path: String) async throws -> RemoteFile? {
        let name = (path as NSString).lastPathComponent
        if v2 {
            try await request(Self.stat2, path)
            let r = try await stream.readExactly(72)
            guard r.le32(at: 0) == Self.stat2 else { throw AdbError.protocolError("bad STA2 reply") }
            if r.le32(at: 4) != 0 { return nil }
            return RemoteFile(name: name, mode: r.le32(at: 24), size: r.le64(at: 40),
                              modified: Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: r.le64(at: 56)))))
        }
        try await request(Self.stat1, path)
        let r = try await stream.readExactly(16)
        guard r.le32(at: 0) == Self.stat1 else { throw AdbError.protocolError("bad STAT reply") }
        if r.le32(at: 4) == 0 { return nil }
        return RemoteFile(name: name, mode: r.le32(at: 4), size: UInt64(r.le32(at: 8)),
                          modified: Date(timeIntervalSince1970: TimeInterval(r.le32(at: 12))))
    }

    /// Streams a remote file to `handler` chunk by chunk.
    public func pull(_ path: String, handler: (Data) throws -> Void) async throws {
        try await request(Self.recv1, path)
        while true {
            let h = try await stream.readExactly(8)
            let id = h.le32(at: 0)
            let length = h.le32(at: 4)
            if id == Self.done { return }
            if id == Self.fail { try await readFail(length) }
            guard id == Self.data else { throw AdbError.protocolError("unexpected sync id \(fourCCString(id))") }
            try handler(try await stream.readExactly(Int(length)))
        }
    }

    public func pull(_ path: String, to url: URL, progress: (UInt64) -> Void) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var total: UInt64 = 0
        try await pull(path) { chunk in
            try handle.write(contentsOf: chunk)
            total += UInt64(chunk.count)
            progress(total)
        }
    }

    public func pullData(_ path: String) async throws -> Data {
        var out = Data()
        try await pull(path) { out.append($0) }
        return out
    }

    /// Uploads bytes produced by `next` (returns nil at end).
    public func push(to path: String, mode: UInt32 = 0o644, modified: Date = Date(),
                     next: () throws -> Data?) async throws {
        try await request(Self.send1, "\(path),\(mode | 0o100000)")
        while let chunk = try next() {
            var offset = 0
            while offset < chunk.count {
                let end = min(offset + Self.maxChunk, chunk.count)
                var d = Data(capacity: 8 + end - offset)
                d.appendLE(Self.data)
                d.appendLE(UInt32(end - offset))
                d.append(chunk.subdata(in: chunk.startIndex + offset..<chunk.startIndex + end))
                try await stream.write(d)
                offset = end
            }
        }
        var done = Data()
        done.appendLE(Self.done)
        done.appendLE(UInt32(modified.timeIntervalSince1970))
        try await stream.write(done)
        let h = try await stream.readExactly(8)
        if h.le32(at: 0) == Self.fail { try await readFail(h.le32(at: 4)) }
        guard h.le32(at: 0) == Self.okay else { throw AdbError.protocolError("bad push reply") }
    }

    public func push(_ url: URL, to path: String, progress: (UInt64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: UInt64 = 0
        try await push(to: path) {
            guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { return nil }
            total += UInt64(chunk.count)
            progress(total)
            return chunk
        }
    }

    public func push(_ data: Data, to path: String) async throws {
        var sent = false
        try await push(to: path) {
            if sent { return nil }
            sent = true
            return data
        }
    }

    func quit() async {
        var d = Data()
        d.appendLE(Self.quit)
        d.appendLE(UInt32(0))
        try? await stream.write(d)
        stream.close()
    }
}

extension AdbConnection {
    /// Opens a sync session for the duration of `body`.
    public func sync<T>(_ body: (SyncSession) async throws -> T) async throws -> T {
        let stream = try await open("sync:")
        let session = SyncSession(stream: stream, v2: features.contains("ls_v2") && features.contains("stat_v2"))
        do {
            let result = try await body(session)
            await session.quit()
            return result
        } catch {
            stream.close()
            throw error
        }
    }
}
