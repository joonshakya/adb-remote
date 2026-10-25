import CAdbCrypto
import Foundation

/// Android 11+ "Wireless debugging" pairing with a six-digit code.
/// Mirrors AOSP adb/pairing_connection: TLS 1.3, then SPAKE2 over the
/// code + TLS exported key, then an AES-GCM exchange of public key / device GUID.
public enum AdbPairing {
    static let headerVersion: UInt8 = 1
    static let spake2Message: UInt8 = 0
    static let peerInfo: UInt8 = 1
    static let peerInfoSize = 8192

    /// Returns the device GUID on success.
    @discardableResult
    public static func pair(host: String, port: UInt16, code: String, key: AdbKey) async throws -> String {
        let code = code.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { throw AdbError.pairing("empty pairing code") }

        let tcp = TCPTransport(host: host, port: port)
        try await tcp.start()
        defer { tcp.close() }
        let tls = try TLSTransport(inner: tcp, key: key)
        do {
            try await withTimeout(10, "TLS handshake") { try await tls.handshake() }
        } catch {
            throw AdbError.pairing("TLS handshake failed: \(error.localizedDescription)")
        }
        let reader = BufferedReader(tls)

        // sizeof("adb-label") in C, so the NUL is included.
        let exported = try tls.exportKeyingMaterial(label: Array("adb-label".utf8) + [0], length: 64)
        let password = Data(code.utf8) + exported

        guard let pair = password.withUnsafeBytes({ adb_pair_new($0.bindMemory(to: UInt8.self).baseAddress, password.count) }) else {
            throw AdbError.pairing("cannot create SPAKE2 context")
        }
        defer { adb_pair_free(pair) }

        var msg = [UInt8](repeating: 0, count: Int(ADB_PAIR_MAX_MSG_SIZE))
        var msgLen = 0
        guard adb_pair_msg(pair, &msg, &msgLen) == 1 else { throw AdbError.pairing("SPAKE2 message failed") }
        try await tls.send(packet(spake2Message, Data(msg[0..<msgLen])))

        let theirs = try await withTimeout(15, "pairing reply") { try await readPacket(reader, expecting: spake2Message) }
        let processed = theirs.withUnsafeBytes { adb_pair_process(pair, $0.bindMemory(to: UInt8.self).baseAddress, theirs.count) }
        guard processed == 1 else { throw AdbError.pairing("wrong pairing code") }

        var info = Data([0]) // ADB_RSA_PUB_KEY
        info.append(Data(key.androidPublicKey.utf8))
        info.append(Data(repeating: 0, count: peerInfoSize - info.count))
        var sealed = [UInt8](repeating: 0, count: peerInfoSize + Int(ADB_PAIR_GCM_OVERHEAD))
        var sealedLen = 0
        let encrypted = info.withUnsafeBytes {
            adb_pair_encrypt(pair, $0.bindMemory(to: UInt8.self).baseAddress, info.count, &sealed, sealed.count, &sealedLen)
        }
        guard encrypted == 1 else { throw AdbError.pairing("encryption failed") }
        try await tls.send(packet(peerInfo, Data(sealed[0..<sealedLen])))

        let reply: Data
        do {
            reply = try await withTimeout(15, "device info") { try await readPacket(reader, expecting: peerInfo) }
        } catch {
            // The device hangs up here when the code was wrong.
            throw AdbError.pairing("device rejected the pairing code")
        }
        var opened = [UInt8](repeating: 0, count: reply.count)
        var openedLen = 0
        let decrypted = reply.withUnsafeBytes {
            adb_pair_decrypt(pair, $0.bindMemory(to: UInt8.self).baseAddress, reply.count, &opened, opened.count, &openedLen)
        }
        guard decrypted == 1, openedLen > 1 else { throw AdbError.pairing("wrong pairing code") }
        guard opened[0] == 1 else { throw AdbError.pairing("unexpected peer info type \(opened[0])") }
        return String(decoding: opened[1..<openedLen].prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func packet(_ type: UInt8, _ payload: Data) -> Data {
        var d = Data([headerVersion, type])
        d.appendBE(UInt32(payload.count))
        d.append(payload)
        return d
    }

    private static func readPacket(_ reader: BufferedReader, expecting type: UInt8) async throws -> Data {
        let header = try await reader.read(6)
        guard header[header.startIndex] == headerVersion else { throw AdbError.pairing("unsupported pairing version") }
        guard header[header.startIndex + 1] == type else { throw AdbError.pairing("unexpected packet type") }
        let length = Int(header.be32(at: 2))
        guard length > 0, length <= peerInfoSize * 2 else { throw AdbError.pairing("bad packet size") }
        return try await reader.read(length)
    }
}
