import Foundation

/// Parses scrcpy's video socket (protocol v5): codec id, then session packets
/// (frame size) and media packets (12-byte header + H.264 Annex-B payload).
public final class ScrcpyVideoReader: @unchecked Sendable {
    public enum Event: Sendable {
        /// New capture session: frames from now on have this size.
        case size(width: Int, height: Int)
        /// SPS/PPS (Annex-B).
        case config(Data)
        case frame(Data, pts: UInt64, keyFrame: Bool)
    }

    public static let h264: UInt32 = 0x6832_3634

    private let stream: AdbStream

    public init(stream: AdbStream) {
        self.stream = stream
    }

    /// Reads the codec id; must be called once before `next()`.
    public func readCodec() async throws -> UInt32 {
        try await stream.readExactly(4).be32(at: 0)
    }

    /// Next event, or nil when the stream ends.
    public func next() async throws -> Event? {
        let header: Data
        do {
            header = try await stream.readExactly(12)
        } catch {
            if stream.isClosed { return nil }
            throw error
        }
        let first = header.be64(at: 0)
        if first & (1 << 63) != 0 {
            return .size(width: Int(header.be32(at: 4)), height: Int(header.be32(at: 8)))
        }
        let size = Int(header.be32(at: 8))
        guard size > 0, size < 32 * 1024 * 1024 else { throw AdbError.protocolError("bad video packet size \(size)") }
        let payload = try await stream.readExactly(size)
        if first & (1 << 62) != 0 { return .config(payload) }
        return .frame(payload, pts: first & ((1 << 61) - 1), keyFrame: first & (1 << 61) != 0)
    }
}

extension AdbConnection {
    /// Grabs one PNG screenshot (works on every Android version).
    public func screenshotPNG() async throws -> Data {
        let path = "/data/local/tmp/adbremote-screen.png"
        try await run("screencap -p \(path)")
        return try await sync { try await $0.pullData(path) }
    }
}
