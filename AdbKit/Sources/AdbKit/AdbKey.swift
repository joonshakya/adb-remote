import CAdbCrypto
import Foundation

/// The RSA-2048 key that identifies this app to devices (same role as ~/.android/adbkey).
/// Stored as a PEM file rather than in the keychain so it survives LiveContainer.
public final class AdbKey: @unchecked Sendable {
    let raw: OpaquePointer
    public let name: String

    private init(raw: OpaquePointer, name: String) {
        self.raw = raw
        self.name = name
    }

    deinit {
        adb_key_free(raw)
    }

    public static func generate(name: String) throws -> AdbKey {
        guard let raw = adb_key_generate() else { throw AdbError.protocolError("RSA key generation failed") }
        return AdbKey(raw: raw, name: name)
    }

    /// Accepts PEM (PKCS#1 or PKCS#8), e.g. the contents of ~/.android/adbkey.
    public convenience init(pem: String, name: String) throws {
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            throw AdbError.protocolError("invalid key PEM")
        }
        let raw = der.withUnsafeBytes { adb_key_from_der($0.bindMemory(to: UInt8.self).baseAddress, der.count) }
        guard let raw else { throw AdbError.protocolError("unsupported private key") }
        self.init(raw: raw, name: name)
    }

    public var pem: String {
        let length = adb_key_to_der(raw, nil, 0)
        var der = [UInt8](repeating: 0, count: length)
        _ = adb_key_to_der(raw, &der, length)
        let b64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(b64)\n-----END PRIVATE KEY-----\n"
    }

    /// Loads the key at `url`, creating and saving a new one if missing.
    public static func loadOrCreate(at url: URL, name: String) throws -> AdbKey {
        if let pem = try? String(contentsOf: url, encoding: .utf8) {
            return try AdbKey(pem: pem, name: name)
        }
        let key = try generate(name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.pem.write(to: url, atomically: true, encoding: .utf8)
        return key
    }

    func signToken(_ token: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: Int(ADB_RSA_SIGNATURE_SIZE))
        var outLen = 0
        let ok = token.withUnsafeBytes {
            adb_key_sign_token(raw, $0.bindMemory(to: UInt8.self).baseAddress, token.count, &out, &outLen)
        }
        guard ok == 1 else { throw AdbError.protocolError("token signing failed") }
        return Data(out[0..<outLen])
    }

    /// "<base64 mincrypt key> <name>", the format adbd stores in adb_keys.
    public var androidPublicKey: String {
        var out = [UInt8](repeating: 0, count: Int(ADB_ANDROID_PUBKEY_SIZE))
        _ = adb_key_android_pubkey(raw, &out)
        return Data(out).base64EncodedString() + " " + name
    }
}
