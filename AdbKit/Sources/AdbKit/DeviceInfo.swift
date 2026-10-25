import Foundation

public struct DeviceInfo: Sendable {
    public var properties: [String: String]
    public var screenSize: String?
    public var density: String?
    public var memoryTotalKB: UInt64?
    public var memoryAvailableKB: UInt64?
    public var storage: String?
    public var battery: String?
    public var ipAddresses: [String]
    public var uptime: String?

    public func prop(_ key: String) -> String? {
        guard let value = properties[key], !value.isEmpty else { return nil }
        return value
    }

    public var displayName: String {
        let manufacturer = prop("ro.product.manufacturer") ?? ""
        let model = prop("ro.product.model") ?? "Android device"
        return model.lowercased().hasPrefix(manufacturer.lowercased()) || manufacturer.isEmpty
            ? model : "\(manufacturer) \(model)"
    }

    public var sdk: Int { Int(prop("ro.build.version.sdk") ?? "") ?? 0 }
    public var isTV: Bool {
        (prop("ro.build.characteristics") ?? "").contains("tv")
            || prop("ro.product.device")?.lowercased().contains("tv") == true
    }

    /// Processor type in plain words, e.g. "ARM 32-bit".
    public var processor: String? {
        guard let abi = prop("ro.product.cpu.abi") else { return nil }
        let kind: String = switch abi {
        case let a where a.hasPrefix("arm64"): "ARM 64-bit"
        case let a where a.hasPrefix("armeabi"): "ARM 32-bit"
        case "x86_64": "Intel/AMD 64-bit"
        case "x86": "Intel/AMD 32-bit"
        default: abi
        }
        let chip = [prop("ro.soc.manufacturer"), prop("ro.soc.model")].compactMap { $0 }.joined(separator: " ")
        return chip.isEmpty ? kind : "\(kind), \(chip)"
    }

    /// Everyday information, shown up front.
    public var rows: [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append((label, value)) }
        }
        add("Model", prop("ro.product.model"))
        add("Made by", prop("ro.product.manufacturer"))
        add("Android version", prop("ro.build.version.release"))
        add("Processor", processor)
        if let total = memoryTotalKB {
            let available = memoryAvailableKB.map { ", \(Self.format(kb: $0)) free" } ?? ""
            add("Memory (RAM)", Self.format(kb: total) + available)
        }
        add("Storage", storage)
        add("Screen", screenSize)
        add("Battery", battery)
        add("Network", ipAddresses.isEmpty ? nil : ipAddresses.joined(separator: ", "))
        add("Turned on for", uptime)
        return rows
    }

    /// Technical details, shown under "More details".
    public var advancedRows: [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append((label, value)) }
        }
        add("Brand", prop("ro.product.brand"))
        add("Device code name", prop("ro.product.device"))
        add("Android API level", sdk > 0 ? String(sdk) : nil)
        add("Security patch", prop("ro.build.version.security_patch"))
        add("Build", prop("ro.build.display.id"))
        add("Build type", prop("ro.build.type"))
        add("CPU ABI", prop("ro.product.cpu.abi"))
        add("Supported ABIs", prop("ro.product.cpu.abilist"))
        add("Hardware", prop("ro.hardware") ?? prop("ro.boot.hardware"))
        add("Board", prop("ro.product.board") ?? prop("ro.board.platform"))
        add("Screen density", density.map { "\($0) dpi" })
        add("Serial number", prop("ro.serialno"))
        add("Kernel", prop("kernel"))
        return rows
    }

    static func format(kb: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)
    }

    /// Collects everything in one shell round trip.
    public static func load(from adb: AdbConnection) async throws -> DeviceInfo {
        let marker = "@@ADBKIT@@"
        let script = [
            "getprop",
            "wm size",
            "wm density",
            "cat /proc/meminfo",
            "df -h /data 2>/dev/null | tail -n 1",
            "dumpsys battery 2>/dev/null | grep -E 'level|present|voltage'",
            "ip -o -4 addr show 2>/dev/null",
            "cat /proc/uptime",
            "uname -r",
        ].joined(separator: "; echo \(marker); ")
        let sections = try await adb.shell(script).output.components(separatedBy: marker + "\n")
        func section(_ i: Int) -> String { i < sections.count ? sections[i] : "" }

        var props: [String: String] = [:]
        // getprop lines: [key]: [value]
        for line in section(0).split(separator: "\n") {
            guard line.hasPrefix("["), let mid = line.range(of: "]: [") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<mid.lowerBound])
            var value = String(line[mid.upperBound...])
            if value.hasSuffix("]") { value.removeLast() }
            props[key] = value
        }
        props["kernel"] = section(8).trimmingCharacters(in: .whitespacesAndNewlines)

        var info = DeviceInfo(properties: props, ipAddresses: [])
        info.screenSize = lastValue(section(1))
        info.density = lastValue(section(2))
        for line in section(3).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let kb = UInt64(parts[1]) else { continue }
            if parts[0] == "MemTotal:" { info.memoryTotalKB = kb }
            if parts[0] == "MemAvailable:" { info.memoryAvailableKB = kb }
        }
        let df = section(4).split(separator: " ", omittingEmptySubsequences: true)
        // df -h prints sizes like "8.1G"; spell the unit out.
        func unit(_ v: Substring) -> String {
            guard let last = v.last, "KMGT".contains(last) else { return String(v) }
            return "\(v.dropLast()) \(last)B"
        }
        if df.count >= 4 { info.storage = "\(unit(df[3])) free of \(unit(df[1]))" }
        var battery: [String: String] = [:]
        for line in section(5).split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { battery[kv[0]] = kv[1] }
        }
        // TVs report a fake battery: "present: false" or "voltage: 0".
        if let level = battery["level"], battery["present"] != "false", battery["voltage"] != "0" {
            info.battery = "\(level)%"
        }
        for line in section(6).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if let i = parts.firstIndex(of: "inet"), i + 1 < parts.count, !parts[1].hasPrefix("lo") {
                info.ipAddresses.append("\(parts[i + 1].split(separator: "/")[0]) (\(parts[1]))")
            }
        }
        if let seconds = Double(section(7).split(separator: " ").first ?? "") {
            // "3d 4h 12m", leaving out zero days and hours.
            let minutes = Int(seconds) / 60
            let parts = [(minutes / 1440, "d"), (minutes / 60 % 24, "h"), (minutes % 60, "m")]
            info.uptime = parts.filter { $0.0 != 0 || $0.1 == "m" }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
        }
        return info
    }

    private static func lastValue(_ text: String) -> String? {
        // "Physical size: 1920x1080\nOverride size: ..." -> prefer override.
        let values = text.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: ": ") else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return values.last
    }
}
