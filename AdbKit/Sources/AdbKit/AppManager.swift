import CAdbCrypto
import Foundation

public struct InstalledApp: Sendable, Identifiable, Hashable {
    public let packageName: String
    public let label: String
    public let versionName: String
    public let versionCode: Int64
    public let isSystem: Bool
    public let isEnabled: Bool
    /// "pkg/.Activity" to launch, empty when the app has no launcher entry.
    public let launchComponent: String

    public var id: String { packageName }
    public var isLaunchable: Bool { !launchComponent.isEmpty }
}

extension AdbConnection {
    /// Pushes adbremote-helper.jar (unless the same build is already there) and returns its path.
    public func installHelper(_ jar: Data) async throws -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        jar.withUnsafeBytes { adb_sha256($0.bindMemory(to: UInt8.self).baseAddress, jar.count, &digest) }
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let path = "/data/local/tmp/adbremote-helper-\(hash).jar"
        let existing = try await sync { try await $0.stat(path) }
        if existing?.size != UInt64(jar.count) {
            _ = try? await shell("rm -f /data/local/tmp/adbremote-helper-*.jar")
            try await sync { try await $0.push(jar, to: path) }
        }
        return path
    }
}

/// Lists, launches, uninstalls, extracts and installs apps. App labels and icons
/// come from adbremote-helper.jar run via app_process (shell can't read them).
public final class AppManager: @unchecked Sendable {
    private let adb: AdbConnection
    private let sdk: Int
    private let helperJar: Data
    private var helperPath: String?

    public init(adb: AdbConnection, sdk: Int, helperJar: Data) {
        self.adb = adb
        self.sdk = sdk
        self.helperJar = helperJar
    }

    private func helper(_ args: String) async throws -> [Substring] {
        if helperPath == nil { helperPath = try await adb.installHelper(helperJar) }
        let output = try await adb.shell("CLASSPATH=\(helperPath!) app_process / local.adbremote.helper.Main \(args)").output
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        if let error = lines.first(where: { $0.hasPrefix("ERR\t") }) {
            throw AdbError.command("Helper: \(error.dropFirst(4))")
        }
        guard lines.contains("END") else {
            throw AdbError.command("Helper failed: \(output.suffix(300))")
        }
        return lines
    }

    public func listApps() async throws -> [InstalledApp] {
        try await helper("list").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, f[0] == "APP" else { return nil }
            return InstalledApp(packageName: f[1], label: f[2].isEmpty ? f[1] : f[2], versionName: f[3],
                                versionCode: Int64(f[4]) ?? 0, isSystem: f[5] == "1", isEnabled: f[6] == "1",
                                launchComponent: f[7])
        }
    }

    /// PNG icons keyed by package name (missing icons are omitted).
    public func icons(for packages: [String], size: Int = 96) async throws -> [String: Data] {
        var result: [String: Data] = [:]
        // Keep the command line well under the shell's length limit.
        for start in stride(from: 0, to: packages.count, by: 40) {
            let batch = packages[start..<min(start + 40, packages.count)]
            for line in try await helper("icons \(size) " + batch.map(shellQuote).joined(separator: " ")) {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard f.count == 3, f[0] == "ICON", let png = Data(base64Encoded: String(f[2])), !png.isEmpty else { continue }
                result[String(f[1])] = png
            }
        }
        return result
    }

    public func launch(_ app: InstalledApp) async throws {
        if app.isLaunchable {
            let output = try await adb.shell("am start -n \(shellQuote(app.launchComponent))").output
            if output.contains("Error") { throw AdbError.command(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            try await adb.run("monkey -p \(shellQuote(app.packageName)) -c android.intent.category.LAUNCHER 1")
        }
    }

    public func forceStop(_ packageName: String) async throws {
        try await adb.run("am force-stop \(shellQuote(packageName))")
    }

    /// Uninstalls a user app; for system apps removes it for user 0 only (restorable).
    public func uninstall(_ app: InstalledApp) async throws {
        let command = app.isSystem && sdk >= 21
            ? "pm uninstall --user 0 \(shellQuote(app.packageName))"
            : "pm uninstall \(shellQuote(app.packageName))"
        let output = try await adb.shell(command).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.contains("Success") else { throw AdbError.command(output.isEmpty ? "Uninstall failed" : output) }
    }

    public func apkPaths(_ packageName: String) async throws -> [String] {
        try await adb.shell("pm path \(shellQuote(packageName))").output
            .split(separator: "\n")
            .compactMap { $0.hasPrefix("package:") ? String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil }
    }

    /// Downloads the app's APK(s) into `directory`; returns local file URLs.
    public func extract(_ app: InstalledApp, to directory: URL, progress: @escaping (UInt64) -> Void = { _ in }) async throws -> [URL] {
        let paths = try await apkPaths(app.packageName)
        guard !paths.isEmpty else { throw AdbError.command("No APK found for \(app.packageName)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        var done: UInt64 = 0
        try await adb.sync { sync in
            for path in paths {
                let url = directory.appendingPathComponent((path as NSString).lastPathComponent)
                var fileDone: UInt64 = 0
                try await sync.pull(path, to: url) { bytes in
                    fileDone = bytes
                    progress(done + bytes)
                }
                done += fileDone
                urls.append(url)
            }
        }
        return urls
    }

    /// Installs one APK, or several APK splits of the same app as one session.
    public func install(_ apks: [URL], progress: @escaping (String) -> Void = { _ in }) async throws {
        guard !apks.isEmpty else { return }
        let flags = "-r" + (sdk >= 17 ? " -d" : "")
        if apks.count == 1 {
            let remote = "/data/local/tmp/adbremote-install.apk"
            progress("Uploading")
            try await adb.sync { try await $0.push(apks[0], to: remote) { _ in } }
            progress("Installing")
            let output = try await adb.shell("pm install \(flags) \(remote); rm -f \(remote)").output
            guard output.contains("Success") else { throw AdbError.command(Self.installError(output)) }
            return
        }
        guard sdk >= 21 else { throw AdbError.command("Split APKs need Android 5.0 or newer") }
        let sizes = try apks.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
        let create = try await adb.shell("pm install-create \(flags) -S \(sizes.reduce(0, +))").output
        guard let open = create.firstIndex(of: "["), let close = create.firstIndex(of: "]"),
              let session = Int(create[create.index(after: open)..<close]) else {
            throw AdbError.command(Self.installError(create))
        }
        do {
            for (index, apk) in apks.enumerated() {
                progress("Uploading \(index + 1) of \(apks.count)")
                let remote = "/data/local/tmp/adbremote-split-\(index).apk"
                try await adb.sync { try await $0.push(apk, to: remote) { _ in } }
                let output = try await adb.shell("pm install-write -S \(sizes[index]) \(session) split\(index).apk \(remote); rm -f \(remote)").output
                guard output.contains("Success") else { throw AdbError.command(Self.installError(output)) }
            }
            progress("Installing")
            let output = try await adb.shell("pm install-commit \(session)").output
            guard output.contains("Success") else { throw AdbError.command(Self.installError(output)) }
        } catch {
            _ = try? await adb.shell("pm install-abandon \(session)")
            throw error
        }
    }

    /// Android's install failure codes, in plain words.
    static let installFailures: [(String, String)] = [
        ("INSTALL_FAILED_UPDATE_INCOMPATIBLE", "A different copy of this app is already installed (from another source). Uninstall it first, then try again."),
        ("INSTALL_FAILED_VERSION_DOWNGRADE", "A newer version of this app is already installed."),
        ("INSTALL_FAILED_OLDER_SDK", "This app needs a newer version of Android than this TV has."),
        ("INSTALL_FAILED_NO_MATCHING_ABIS", "This app isn't made for this TV's processor. Look for a version marked armeabi-v7a (32-bit ARM) or \"universal\"."),
        ("INSTALL_FAILED_INSUFFICIENT_STORAGE", "There isn't enough free storage on the TV."),
        ("INSTALL_FAILED_MISSING_SPLIT", "This app comes in several parts. Install the bundle file (.apks or .xapk) instead of a single .apk."),
        ("INSTALL_FAILED_INVALID_APK", "The app file is damaged or incomplete. Download it again."),
        ("INSTALL_PARSE_FAILED_NOT_APK", "This file isn't an Android app."),
        ("INSTALL_PARSE_FAILED", "The app file is damaged or not an Android app. Download it again."),
        ("INSTALL_FAILED_DUPLICATE_PERMISSION", "Another installed app conflicts with this one."),
        ("INSTALL_FAILED_USER_RESTRICTED", "The TV blocked the install. Allow installs from unknown sources in its settings."),
        ("INSTALL_FAILED_VERIFICATION_FAILURE", "The TV's app verification blocked this install."),
    ]

    private static func installError(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = installFailures.first(where: { text.contains($0.0) }) {
            return match.1
        }
        if let range = text.range(of: "Failure [") ?? text.range(of: "Failure") {
            return String(text[range.lowerBound...])
        }
        return text.isEmpty ? "Install failed" : text
    }
}
