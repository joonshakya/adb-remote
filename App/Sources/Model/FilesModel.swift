import AdbKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// File browser state for one connected device.
@MainActor @Observable
final class FilesModel {
    struct Location: Identifiable, Hashable {
        let name: String
        let path: String
        let symbol: String
        var id: String { path }
    }

    private(set) var locations: [Location] = []
    var error: String?
    private(set) var activity: String?
    var message: String?

    private let adb: AdbConnection

    init(connection: AdbConnection) {
        adb = connection
    }

    static let home = "/sdcard"

    func title(for path: String) -> String {
        if path == Self.home { return "Internal Storage" }
        if path == "/" { return "Whole System" }
        if let location = locations.first(where: { $0.path == path }) { return location.name }
        return (path as NSString).lastPathComponent
    }

    // MARK: Listing

    /// Folders first, then files, in Finder-like name order.
    func list(_ path: String) async throws -> [RemoteFile] {
        if locations.isEmpty { await loadLocations() }
        // Trailing slash makes LIST follow symlinks such as /sdcard.
        let listing = try await adb.sync { try await $0.list(path.hasSuffix("/") ? path : path + "/") }
        return listing.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Shortcuts: common folders plus any USB drives / SD cards under /storage.
    private func loadLocations() async {
        var list = [
            Location(name: "Internal Storage", path: Self.home, symbol: "internaldrive"),
            Location(name: "Downloads", path: "/sdcard/Download", symbol: "arrow.down.circle"),
            Location(name: "Movies", path: "/sdcard/Movies", symbol: "film"),
            Location(name: "Pictures", path: "/sdcard/Pictures", symbol: "photo"),
        ]
        if let storage = try? await adb.sync({ try await $0.list("/storage/") }) {
            for entry in storage where !["emulated", "self", "sdcard0", "sdcard1"].contains(entry.name) && entry.isDirectory {
                list.append(Location(name: "USB / SD (\(entry.name))", path: "/storage/\(entry.name)", symbol: "externaldrive"))
            }
        }
        list.append(Location(name: "Whole System", path: "/", symbol: "folder.badge.gearshape"))
        locations = list
    }

    func fullPath(_ entry: RemoteFile, in folder: String) -> String {
        Self.join(folder, entry.name)
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
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

    func createFolder(_ name: String, in folder: String) async {
        await perform("Creating folder") {
            try await adb.run("mkdir -p \(shellQuote(Self.join(folder, name)))")
            return nil
        }
    }

    func rename(_ entry: RemoteFile, in folder: String, to name: String) async {
        await perform("Renaming") {
            try await adb.run("mv \(shellQuote(fullPath(entry, in: folder))) \(shellQuote(Self.join(folder, name)))")
            return nil
        }
    }

    func delete(_ entry: RemoteFile, in folder: String) async {
        await perform("Deleting \(entry.name)") {
            try await adb.run("rm -rf \(shellQuote(fullPath(entry, in: folder)))")
            return nil
        }
    }

    /// Copies a file from the TV to a temporary file on the phone for sharing/saving.
    func download(_ entry: RemoteFile, in folder: String) async -> URL? {
        var result: URL?
        let source = fullPath(entry, in: folder)
        await perform("Copying \(entry.name)") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(entry.name)
            let total = entry.size
            try await adb.sync { sync in
                try await sync.pull(source, to: url) { [weak self] bytes in
                    let text = Self.progressText("Copying \(entry.name)", bytes, total)
                    Task { @MainActor in self?.activity = text }
                }
            }
            result = url
            return nil
        }
        return result
    }

    /// Uploads files picked in the Files app into the current folder.
    func upload(_ urls: [URL], to folder: String) async {
        await perform("Uploading") {
            for (index, url) in urls.enumerated() {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let total = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let label = urls.count > 1 ? "Uploading \(index + 1) of \(urls.count)" : "Uploading \(url.lastPathComponent)"
                try await adb.sync { sync in
                    try await sync.push(url, to: folder + "/" + url.lastPathComponent) { [weak self] bytes in
                        let text = Self.progressText(label, bytes, total)
                        Task { @MainActor in self?.activity = text }
                    }
                }
            }
            return urls.count == 1 ? "\(urls[0].lastPathComponent) was uploaded." : "\(urls.count) files were uploaded."
        }
    }

    /// Asks the TV to open a media file in its default app.
    func openOnTV(_ entry: RemoteFile, in folder: String) async {
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)
        let mime = type?.preferredMIMEType ?? "*/*"
        await perform("Opening \(entry.name)") {
            let output = try await adb.shell(
                "am start -a android.intent.action.VIEW -d \(shellQuote("file://" + fullPath(entry, in: folder))) -t \(shellQuote(mime))"
            ).output
            if output.contains("Error") { throw AdbError.command("No app on the TV can open this file.") }
            return nil
        }
    }

    nonisolated static func progressText(_ label: String, _ bytes: UInt64, _ total: UInt64) -> String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        guard total > 0 else { return "\(label): \(done)" }
        return "\(label): \(done) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
    }
}
