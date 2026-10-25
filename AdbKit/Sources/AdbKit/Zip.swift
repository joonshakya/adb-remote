import CAdbZlib
import Foundation

/// Minimal ZIP support for APK bundles: write stored (uncompressed) archives,
/// read stored or deflated entries. Streams file data; no ZIP64.
public enum Zip {
    public struct Entry: Sendable {
        public let name: String
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    // MARK: Writing

    /// Writes `files` (name, local URL) into a stored ZIP at `url`.
    public static func create(at url: URL, files: [(name: String, url: URL)]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var central = Data()
        var offset: UInt64 = 0
        for file in files {
            let name = Data(file.name.utf8)
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            // CRC needs a first pass; files are read twice rather than held in memory.
            var crc: UInt32 = 0
            var size: UInt64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                crc = crc32(crc, chunk)
                size += UInt64(chunk.count)
            }
            guard size < 0xffff_ffff, offset < 0xffff_ffff else { throw AdbError.command("File too large for ZIP") }
            var local = Data()
            local.appendLE(UInt32(0x0403_4b50))
            local.appendLE16(20); local.appendLE16(0x0800); local.appendLE16(0) // version, UTF-8 flag, stored
            local.appendLE16(0); local.appendLE16(0x21) // time, date (1980-01-01)
            local.appendLE(crc); local.appendLE(UInt32(size)); local.appendLE(UInt32(size))
            local.appendLE16(UInt16(name.count)); local.appendLE16(0)
            local.append(name)
            try out.write(contentsOf: local)
            try input.seek(toOffset: 0)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }

            central.appendLE(UInt32(0x0201_4b50))
            central.appendLE16(20); central.appendLE16(20); central.appendLE16(0x0800); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0x21)
            central.appendLE(crc); central.appendLE(UInt32(size)); central.appendLE(UInt32(size))
            central.appendLE16(UInt16(name.count)); central.appendLE16(0); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0); central.appendLE(UInt32(0))
            central.appendLE(UInt32(offset))
            central.append(name)
            offset += UInt64(local.count) + size
        }
        var end = Data()
        end.appendLE(UInt32(0x0605_4b50))
        end.appendLE16(0); end.appendLE16(0)
        end.appendLE16(UInt16(files.count)); end.appendLE16(UInt16(files.count))
        end.appendLE(UInt32(central.count)); end.appendLE(UInt32(offset)); end.appendLE16(0)
        try out.write(contentsOf: central)
        try out.write(contentsOf: end)
    }

    // MARK: Reading

    public static func entries(of url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.le32(at: $0) == 0x0605_4b50 }) else {
            throw AdbError.command("Not a ZIP file")
        }
        let count = Int(tail.le16(at: eocd + 10))
        let cdSize = Int(tail.le32(at: eocd + 12))
        let cdOffset = UInt64(tail.le32(at: eocd + 16))
        try handle.seek(toOffset: cdOffset)
        let cd = try handle.read(upToCount: cdSize) ?? Data()
        var entries: [Entry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.le32(at: p) == 0x0201_4b50 else { throw AdbError.command("Bad ZIP directory") }
            let nameLen = Int(cd.le16(at: p + 28)), extraLen = Int(cd.le16(at: p + 30)), commentLen = Int(cd.le16(at: p + 32))
            let name = String(decoding: cd.subdata(in: cd.startIndex + p + 46..<cd.startIndex + p + 46 + nameLen), as: UTF8.self)
            entries.append(Entry(name: name, method: cd.le16(at: p + 10),
                                 compressedSize: UInt64(cd.le32(at: p + 20)), uncompressedSize: UInt64(cd.le32(at: p + 24)),
                                 localHeaderOffset: UInt64(cd.le32(at: p + 42))))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Extracts one entry to `destination`.
    public static func extract(_ entry: Entry, from url: URL, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.le32(at: 0) == 0x0403_4b50 else { throw AdbError.command("Bad ZIP entry") }
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + UInt64(header.le16(at: 26)) + UInt64(header.le16(at: 28)))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var remaining = entry.compressedSize
        switch entry.method {
        case 0:
            while remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        case 8:
            guard let inflater = adb_inflater_new() else { throw AdbError.command("Cannot decompress \(entry.name)") }
            defer { adb_inflater_free(inflater) }
            // The C callback collects output; it is written out after each chunk.
            final class Sink { var data = Data() }
            let sink = Sink()
            var finished = false
            while !finished, remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty {
                let r = chunk.withUnsafeBytes { raw in
                    adb_inflater_write(inflater, raw.bindMemory(to: UInt8.self).baseAddress, chunk.count, { context, bytes, count in
                        Unmanaged<Sink>.fromOpaque(context!).takeUnretainedValue().data.append(bytes!, count: count)
                    }, Unmanaged.passUnretained(sink).toOpaque())
                }
                guard r >= 0 else { throw AdbError.command("Damaged data in \(entry.name)") }
                finished = r == 1
                try out.write(contentsOf: sink.data)
                sink.data.removeAll(keepingCapacity: true)
                remaining -= UInt64(chunk.count)
            }
        default:
            throw AdbError.command("Unsupported ZIP compression (\(entry.method)) in \(entry.name)")
        }
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8)
            }
        }
        return ~c
    }
}

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func le16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
}

extension AppManager {
    /// Installs a .apk, or a bundle (.apks / .xapk / .apkm ZIP of split APKs).
    public func installPackage(at url: URL, workDirectory: URL, progress: @escaping (String) -> Void = { _ in }) async throws {
        if url.pathExtension.lowercased() == "apk" {
            try await install([url], progress: progress)
            return
        }
        progress("Unpacking")
        let entries = try Zip.entries(of: url).filter {
            $0.name.lowercased().hasSuffix(".apk") && !$0.name.contains("/")
        }
        guard !entries.isEmpty else { throw AdbError.command("No APKs inside \(url.lastPathComponent)") }
        try? FileManager.default.removeItem(at: workDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        var apks: [URL] = []
        for entry in entries {
            let destination = workDirectory.appendingPathComponent(entry.name)
            try Zip.extract(entry, from: url, to: destination)
            apks.append(destination)
        }
        try await install(apks, progress: progress)
    }
}
