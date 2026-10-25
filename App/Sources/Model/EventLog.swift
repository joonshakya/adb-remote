import Foundation

/// Per-device timeline of pings, key presses and connection events, so lag can be
/// traced afterwards. Files live in Documents/Logs (visible in the Files app) as
/// "<device>.log"; each grows to 2 MB and then the older half moves to "<device>.old.log".
final class EventLog: @unchecked Sendable {
    static let shared = EventLog()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
    }

    private let queue = DispatchQueue(label: "EventLog")
    private let maxSize = 2 * 1024 * 1024
    private let time: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func url(for device: String) -> URL {
        let safe = device.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".log")
    }

    func log(_ device: String, _ message: String) {
        let line = "\(time.string(from: Date())) \(message)\n"
        queue.async { [self] in
            let url = Self.url(for: device)
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxSize {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
