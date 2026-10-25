import Foundation

public struct RootStatus: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case none = 0
        /// userdebug/eng build: `adb root` can restart adbd as root.
        case adbRootAvailable
        /// A `su` binary works for the ADB shell (AOSP su: shell only, apps can't use it).
        case shellSu
        /// The ADB shell itself already runs as uid 0.
        case rootShell
        /// Magisk/SuperSU style root that apps can request.
        case fullRoot

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var level: Level
    public var shellIsRoot: Bool
    public var suPath: String?
    public var suWorks: Bool
    public var rootManager: String?
    public var debuggable: Bool
    public var buildType: String
    public var selinux: String?

    /// Short answer for "is this device rooted?".
    public var answer: String {
        switch level {
        case .none: "No"
        case .adbRootAvailable: "No, but it can be turned on"
        case .shellSu, .rootShell: "Yes, for this app"
        case .fullRoot: "Yes, full"
        }
    }

    /// One plain sentence explaining what the answer means.
    public var explanation: String {
        switch level {
        case .none:
            "Normal access. Everything in this app works without root."
        case .adbRootAvailable:
            "This TV runs developer firmware, so root access could be switched on. You don't need it for this app."
        case .shellSu, .rootShell:
            "This app can make system-level changes, but apps installed on the TV can't get root."
        case .fullRoot:
            "Root is installed (\(rootManager ?? "su")). Apps on the TV can ask for full control."
        }
    }

    public var summary: String { "\(answer). \(explanation)" }

    public var details: [(String, String)] {
        var rows: [(String, String)] = [
            ("ADB shell user", shellIsRoot ? "root (uid 0)" : "shell (uid 2000)"),
            ("adb root", debuggable && buildType != "user" ? "Supported" : "Not supported"),
            ("su binary", suPath.map { "\($0)\(suWorks ? " (works)" : " (denied)")" } ?? "None"),
        ]
        if let rootManager { rows.append(("Root manager", rootManager)) }
        if let selinux { rows.append(("SELinux", selinux)) }
        return rows
    }
}

public struct GooglePlayStatus: Sendable {
    public var playStoreVersion: String?
    public var playServicesVersion: String?
    public var googlePackages: [String]

    public var hasPlayStore: Bool { playStoreVersion != nil }
    public var hasPlayServices: Bool { playServicesVersion != nil }

    public var summary: String {
        switch (hasPlayStore, hasPlayServices) {
        case (true, true): "Play Store and Play Services installed"
        case (true, false): "Play Store installed, Play Services missing"
        case (false, true): "Play Services installed, no Play Store"
        case (false, false): "No Google Play"
        }
    }
}

public struct Capability: Sendable, Identifiable {
    public let name: String
    public let supported: Bool
    public let note: String
    public var id: String { name }
}

/// Slower checks for the device info screen: root, Google Play, what this app can do.
public struct DeviceExtras: Sendable {
    public var root: RootStatus
    public var play: GooglePlayStatus
    public var adbFeatures: [String]
    public var capabilities: [Capability]

    public static func load(from adb: AdbConnection, sdk: Int) async throws -> DeviceExtras {
        let marker = "@@ADBKIT@@"
        // `timeout` (toybox) exists from Android 7; on older devices skip running su
        // since a root-manager prompt could block the shell forever.
        let suTest = sdk >= 24
            ? "S=$(which su 2>/dev/null); [ -n \"$S\" ] && echo $S && timeout 3 su 0 id 2>/dev/null; timeout 3 su -c id 2>/dev/null"
            : "which su 2>/dev/null"
        let script = [
            "id",
            "getprop ro.debuggable; getprop ro.build.type",
            "getenforce 2>/dev/null",
            suTest,
            "ls /sbin/magisk /debug_ramdisk/magisk /system/bin/magisk /data/adb/magisk 2>/dev/null; pm list packages 2>/dev/null | grep -E 'magisk|supersu|kingroot|kernelsu|apatch'",
            "dumpsys package com.android.vending 2>/dev/null | grep -m1 versionName",
            "dumpsys package com.google.android.gms 2>/dev/null | grep -m1 versionName",
            "pm list packages 2>/dev/null | grep -E 'com\\.google\\.|com\\.android\\.vending'",
        ].joined(separator: "; echo \(marker); ")
        let sections = try await adb.shell(script).output.components(separatedBy: marker + "\n")
        func section(_ i: Int) -> String { i < sections.count ? sections[i].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
        func lines(_ i: Int) -> [String] { section(i).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } }

        let shellIsRoot = section(0).hasPrefix("uid=0")
        let buildInfo = lines(1)
        let debuggable = buildInfo.first == "1"
        let buildType = buildInfo.count > 1 ? buildInfo[1] : "user"
        let suLines = lines(3)
        let suPath = suLines.first { $0.hasPrefix("/") }
        let suWorks = suLines.contains { $0.hasPrefix("uid=0") }
        let managerHits = lines(4)
        let rootManager: String? = managerHits.isEmpty ? nil : {
            let all = managerHits.joined(separator: " ").lowercased()
            if all.contains("magisk") { return "Magisk" }
            if all.contains("kernelsu") { return "KernelSU" }
            if all.contains("apatch") { return "APatch" }
            if all.contains("supersu") { return "SuperSU" }
            if all.contains("kingroot") { return "KingRoot" }
            return "Unknown"
        }()

        let level: RootStatus.Level
        if rootManager != nil && (suWorks || suPath != nil) {
            level = .fullRoot
        } else if shellIsRoot {
            level = .rootShell
        } else if suWorks {
            level = .shellSu
        } else if debuggable && buildType != "user" {
            level = .adbRootAvailable
        } else {
            level = .none
        }
        let root = RootStatus(
            level: level, shellIsRoot: shellIsRoot, suPath: suPath, suWorks: suWorks || (shellIsRoot && suPath != nil),
            rootManager: rootManager, debuggable: debuggable, buildType: buildType,
            selinux: section(2).isEmpty ? nil : section(2))

        func version(_ text: String) -> String? {
            guard let r = text.range(of: "versionName=") else { return nil }
            return String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let googlePackages = lines(7).map { $0.replacingOccurrences(of: "package:", with: "") }.filter { !$0.isEmpty }.sorted()
        let play = GooglePlayStatus(playStoreVersion: version(section(5)), playServicesVersion: version(section(6)),
                                    googlePackages: googlePackages)

        let f = adb.features
        // Plain-language list for the device screen; protocol details stay in `adbFeatures`.
        let modern = sdk >= 21
        let capabilities = [
            Capability(name: "Remote control", supported: true,
                       note: modern ? "Fast: buttons respond instantly." : "Works, but each press takes about a second on this older TV."),
            Capability(name: "Keyboard shortcuts", supported: modern || sdk >= 33,
                       note: modern ? "Ctrl, Alt, Shift and F1–F12 work." : "Plain keys only; Ctrl/Alt combinations need Android 5 or newer."),
            Capability(name: "Typing in any language", supported: modern,
                       note: modern ? "Emoji and non-English letters work." : "English letters, numbers and symbols only."),
            Capability(name: "Live screen with touch", supported: modern,
                       note: modern ? "Watch the TV screen on your phone and tap to control it." : "Screenshots only; live video needs Android 5 or newer."),
            Capability(name: "Install apps", supported: true,
                       note: modern ? "Any app file: .apk, .apks, .xapk or .apkm." : "Single .apk files. App bundles (.apks, .xapk) need Android 5 or newer."),
            Capability(name: "Photo and video casting", supported: sdk >= 16,
                       note: "Show photos and videos from your phone on the TV."),
            Capability(name: "Encrypted connection", supported: adb.usesTLS,
                       note: adb.usesTLS ? "Connected through Wireless debugging." : "Normal network debugging. Fine on your home Wi-Fi."),
        ]

        return DeviceExtras(root: root, play: play, adbFeatures: f.sorted(), capabilities: capabilities)
    }
}

public struct SpeedTestResult: Sendable {
    public let bytes: Int
    public let uploadBytesPerSecond: Double
    public let downloadBytesPerSecond: Double
    public let latency: TimeInterval

    public static func format(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

extension AdbConnection {
    /// Measures shell round-trip latency and push/pull throughput with a temp file.
    public func speedTest(bytes: Int = 4 * 1024 * 1024,
                          progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SpeedTestResult {
        progress("Measuring latency")
        var pings: [TimeInterval] = []
        for _ in 0..<3 {
            let t = Date()
            _ = try await shell("echo")
            pings.append(Date().timeIntervalSince(t))
        }
        var payload = Data(count: bytes)
        payload.withUnsafeMutableBytes { raw in
            var generator = SystemRandomNumberGenerator()
            for offset in stride(from: 0, to: bytes, by: 8) {
                let value: UInt64 = generator.next()
                withUnsafeBytes(of: value) { raw.baseAddress!.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: min(8, bytes - offset)) }
            }
        }
        let path = "/data/local/tmp/adbkit-speedtest.bin"

        progress("Uploading \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
        let up = Date()
        try await sync { try await $0.push(payload, to: path) }
        let upTime = Date().timeIntervalSince(up)

        progress("Downloading")
        let down = Date()
        let back = try await sync { try await $0.pullData(path) }
        let downTime = Date().timeIntervalSince(down)
        _ = try? await shell("rm -f \(path)")
        guard back == payload else { throw AdbError.sync("speed test data mismatch") }

        return SpeedTestResult(bytes: bytes,
                               uploadBytesPerSecond: Double(bytes) / upTime,
                               downloadBytesPerSecond: Double(bytes) / downTime,
                               latency: pings.min() ?? 0)
    }
}
