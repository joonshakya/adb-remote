import AdbKit
import Foundation

/// Compiled into both the app and the Share extension.
struct SavedDevice: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    /// Port the user typed; nil means "auto" (5555, then offer a scan).
    var port: UInt16?
    /// Last port that worked, tried first when `port` is nil.
    var lastPort: UInt16?

    var address: String {
        if let port = port ?? lastPort { return "\(host):\(port)" }
        return host
    }

    /// Ports to try without scanning.
    var candidatePorts: [UInt16] {
        var ports: [UInt16] = []
        for p in [port, lastPort, 5555].compactMap({ $0 }) where !ports.contains(p) { ports.append(p) }
        return ports
    }
}

/// Where the device list and ADB key live. Uses the App Group container when the
/// signing setup provides one (so the Share extension can read them), else the
/// app's own Application Support folder.
enum SharedStorage {
    static let appGroup = "group.local.adbremote"
    static let urlScheme = "adbremote"

    static var groupDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var directory: URL {
        groupDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var devicesURL: URL { directory.appendingPathComponent("devices.json") }
    static var keyURL: URL { directory.appendingPathComponent("adbkey") }

    static func loadDevices() -> [SavedDevice] {
        guard let data = try? Data(contentsOf: devicesURL) else { return [] }
        return (try? JSONDecoder().decode([SavedDevice].self, from: data)) ?? []
    }

    static func saveDevices(_ devices: [SavedDevice]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(devices).write(to: devicesURL, options: .atomic)
    }

    /// One-time move from the app-only folder into the App Group, once it exists.
    static func migrateIntoGroupIfNeeded() {
        guard let group = groupDirectory else { return }
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        for name in ["devices.json", "adbkey"] {
            let from = old.appendingPathComponent(name), to = group.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                try? FileManager.default.copyItem(at: from, to: to)
            }
        }
    }

    static func loadKey(deviceName: String) throws -> AdbKey {
        try AdbKey.loadOrCreate(at: keyURL, name: "AdbRemote@\(deviceName.replacingOccurrences(of: " ", with: "_"))")
    }
}
