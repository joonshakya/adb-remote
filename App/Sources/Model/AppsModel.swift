import AdbKit
import Foundation
import Observation
import UIKit

/// App list, icons and app actions for one connected device.
@MainActor @Observable
final class AppsModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var icons: [String: UIImage] = [:]
    private(set) var isLoading = false
    var error: String?
    /// Shown while installing or saving ("Uploading", "Installing", ...).
    private(set) var activity: String?
    /// Set after a successful action, e.g. "TV Bro was uninstalled."
    var message: String?

    private let manager: AppManager

    static let helperJar: Data? = Bundle.main.url(forResource: "adbremote-helper", withExtension: "jar")
        .flatMap { try? Data(contentsOf: $0) }

    init?(connection: AdbConnection, sdk: Int) {
        guard let jar = Self.helperJar else { return nil }
        manager = AppManager(adb: connection, sdk: sdk, helperJar: jar)
    }

    private static var iconDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("icons")
    }

    private static func iconURL(_ app: InstalledApp) -> URL {
        iconDirectory.appendingPathComponent("\(app.packageName)-\(app.versionCode).png")
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            apps = try await manager.listApps().sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            error = nil
            await loadIcons()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Cached icons load instantly; missing ones are fetched from the TV in one go.
    private func loadIcons() async {
        var missing: [InstalledApp] = []
        for app in apps where icons[app.packageName] == nil {
            if let data = try? Data(contentsOf: Self.iconURL(app)), let image = UIImage(data: data) {
                icons[app.packageName] = image
            } else {
                missing.append(app)
            }
        }
        // Launchable apps first so the grid fills in quickly.
        missing.sort { $0.isLaunchable && !$1.isLaunchable }
        guard !missing.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.iconDirectory, withIntermediateDirectories: true)
        for start in stride(from: 0, to: missing.count, by: 40) {
            let batch = Array(missing[start..<min(start + 40, missing.count)])
            guard let fetched = try? await manager.icons(for: batch.map(\.packageName)) else { return }
            for app in batch {
                guard let data = fetched[app.packageName], let image = UIImage(data: data) else { continue }
                icons[app.packageName] = image
                try? data.write(to: Self.iconURL(app))
            }
        }
    }

    // MARK: Actions

    private func perform(_ status: String, _ body: () async throws -> String?) async {
        activity = status
        defer { activity = nil }
        do {
            message = try await body()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ app: InstalledApp) async {
        await perform("Opening \(app.label)") {
            try await manager.launch(app)
            return nil
        }
    }

    func stop(_ app: InstalledApp) async {
        await perform("Stopping \(app.label)") {
            try await manager.forceStop(app.packageName)
            return "\(app.label) was stopped."
        }
    }

    func uninstall(_ app: InstalledApp) async {
        await perform("Uninstalling \(app.label)") {
            try await manager.uninstall(app)
            apps.removeAll { $0.packageName == app.packageName }
            return app.isSystem
                ? "\(app.label) was removed. It's a built-in app, so a factory reset brings it back."
                : "\(app.label) was uninstalled."
        }
    }

    /// Copies the app's file(s) to the phone. Returns one shareable file:
    /// "<Name> <version>.apk", or ".apks" when the app is split into parts.
    func saveAppFile(_ app: InstalledApp) async -> URL? {
        var result: URL?
        await perform("Copying \(app.label) from the TV") {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
            let parts = try await manager.extract(app, to: base.appendingPathComponent("parts")) { [weak self] bytes in
                let text = "Copying \(app.label): \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                Task { @MainActor in self?.activity = text }
            }
            let name = "\(app.label) \(app.versionName)".replacingOccurrences(of: "/", with: "-")
            if parts.count == 1 {
                let url = base.appendingPathComponent(name + ".apk")
                try FileManager.default.moveItem(at: parts[0], to: url)
                result = url
            } else {
                let url = base.appendingPathComponent(name + ".apks")
                try Zip.create(at: url, files: parts.map { ($0.lastPathComponent, $0) })
                result = url
            }
            return nil
        }
        return result
    }

    /// Installs an app file picked in the Files app (.apk, .apks, .xapk, .apkm).
    func install(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        await perform("Preparing \(url.lastPathComponent)") {
            // Copy out of the Files provider first; it may be in iCloud.
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.copyItem(at: url, to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            try await manager.installPackage(
                at: local,
                workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("install-parts")
            ) { [weak self] status in
                Task { @MainActor in self?.activity = status }
            }
            return "\(url.deletingPathExtension().lastPathComponent) was installed."
        }
        await refresh()
    }
}
