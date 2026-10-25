import Foundation

struct AdbMessage {
    static let cnxn = fourCC("CNXN")
    static let auth = fourCC("AUTH")
    static let open = fourCC("OPEN")
    static let okay = fourCC("OKAY")
    static let clse = fourCC("CLSE")
    static let wrte = fourCC("WRTE")
    static let stls = fourCC("STLS")

    static let version: UInt32 = 0x0100_0001
    static let stlsVersion: UInt32 = 0x0100_0000
    static let maxPayload: UInt32 = 1024 * 1024

    static let authToken: UInt32 = 1
    static let authSignature: UInt32 = 2
    static let authPublicKey: UInt32 = 3

    let command: UInt32
    let arg0: UInt32
    let arg1: UInt32
    let payload: Data

    init(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    var encoded: Data {
        var d = Data(capacity: 24 + payload.count)
        d.appendLE(command)
        d.appendLE(arg0)
        d.appendLE(arg1)
        d.appendLE(UInt32(payload.count))
        // Checksum is ignored from version 0x01000001 on but older devices need it.
        d.appendLE(payload.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        d.appendLE(command ^ 0xffff_ffff)
        d.append(payload)
        return d
    }

    static func read(from reader: BufferedReader) async throws -> AdbMessage {
        let header = try await reader.read(24)
        let command = header.le32(at: 0)
        guard header.le32(at: 20) == command ^ 0xffff_ffff else {
            throw AdbError.protocolError("bad message magic")
        }
        let length = Int(header.le32(at: 12))
        guard length <= 16 * 1024 * 1024 else { throw AdbError.protocolError("payload too large") }
        let payload = length > 0 ? try await reader.read(length) : Data()
        return AdbMessage(command, header.le32(at: 4), header.le32(at: 8), payload)
    }
}

extension Data {
    /// Service and banner strings are NUL-terminated on the wire.
    init(cString s: String) {
        self.init(s.utf8)
        append(0)
    }
}
