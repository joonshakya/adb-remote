import AdbKit
import SwiftUI
import UniformTypeIdentifiers

/// TV file browser: each folder opens as its own screen, Back goes up.
struct FilesTab: View {
    @Environment(DeviceStore.self) private var store
    @State private var stack: [String] = []

    var body: some View {
        NavigationStack(path: $stack) {
            Group {
                if let session = store.selectedSession, session.isConnected, let model = session.filesModel() {
                    FolderView(model: model, path: FilesModel.home, stack: $stack)
                        .navigationDestination(for: String.self) { path in
                            FolderView(model: model, path: path, stack: $stack)
                        }
                } else {
                    NotConnectedView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DevicePicker() }
        }
        // A different TV has different folders.
        .onChange(of: store.selectedID) { stack = [] }
    }
}

private struct FolderView: View {
    let model: FilesModel
    let path: String
    @Binding var stack: [String]

    @State private var entries: [RemoteFile] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var uploading = false
    @State private var newFolder = false
    @State private var newName = ""
    @State private var renaming: RemoteFile?
    @State private var deleting: RemoteFile?
    @State private var shareURL: URL?

    private var isRoot: Bool { path == FilesModel.home }

    var body: some View {
        withDialogs(list)
            .navigationTitle(model.title(for: path))
    }

    private var list: some View {
        List {
            Section {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                } else if entries.isEmpty && !loading {
                    Text("This folder is empty.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        }
        .overlay { if loading && entries.isEmpty { ProgressView() } }
        .refreshable { await reload() }
        .task { if entries.isEmpty { await reload() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Upload from iPhone", systemImage: "square.and.arrow.up") { uploading = true }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newName = ""
                        newFolder = true
                    }
                    Divider()
                    // Jump to another place; replaces the folders opened so far.
                    Menu("Go To", systemImage: "folder") {
                        ForEach(model.locations) { location in
                            Button(location.name, systemImage: location.symbol) {
                                stack = location.path == FilesModel.home ? [] : [location.path]
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay { if let activity = model.activity { ActivityBanner(text: activity) } }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await model.list(path)
            loadError = nil
        } catch {
            entries = []
            loadError = "Can't open this folder: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func row(_ entry: RemoteFile) -> some View {
        if entry.isDirectory {
            NavigationLink(value: model.fullPath(entry, in: path)) {
                FileRow(entry: entry)
            }
            .swipeActions { swipe(entry) }
            .contextMenu { menu(entry) }
        } else {
            Menu {
                menu(entry)
            } label: {
                FileRow(entry: entry)
            }
            .foregroundStyle(.primary)
            .swipeActions { swipe(entry) }
        }
    }

    @ViewBuilder
    private func swipe(_ entry: RemoteFile) -> some View {
        Button("Delete", role: .destructive) { deleting = entry }
        Button("Rename") {
            newName = entry.name
            renaming = entry
        }
        .tint(.orange)
    }

    @ViewBuilder
    private func menu(_ entry: RemoteFile) -> some View {
        if !entry.isDirectory {
            Button("Save to iPhone", systemImage: "square.and.arrow.down") {
                Task { if let url = await model.download(entry, in: path) { shareURL = url } }
            }
            if FileRow.isMedia(entry.name) {
                Button("Open on TV", systemImage: "tv") { Task { await model.openOnTV(entry, in: path) } }
            }
        }
        Button("Rename", systemImage: "pencil") {
            newName = entry.name
            renaming = entry
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
    }

    /// Runs a change, then refreshes this folder.
    private func change(_ action: @escaping () async -> Void) {
        Task {
            await action()
            await reload()
        }
    }

    private func withDialogs(_ content: some View) -> some View {
        withAlerts(content
            .documentPicker(isPresented: $uploading, types: [.item], multiple: true) { urls in
                change {
                    await model.upload(urls, to: path)
                    for url in urls { try? FileManager.default.removeItem(at: url) }
                }
            }
            .alert("New Folder", isPresented: $newFolder) {
                TextField("Name", text: $newName)
                Button("Create") { change { await model.createFolder(newName, in: path) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let entry = renaming { change { await model.rename(entry, in: path, to: newName) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let entry = deleting { change { await model.delete(entry, in: path) } }
                }
            } message: {
                Text(deleting?.isDirectory == true ? "The folder and everything in it will be deleted from the TV." : "The file will be deleted from the TV.")
            }
            .sheet(item: Binding(get: { shareURL.map(SharedFile.init) }, set: { shareURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            })
    }

    private func withAlerts(_ content: some View) -> some View {
        content
            .alert("Something went wrong", isPresented: Binding(
                get: { model.error != nil }, set: { if !$0 { model.error = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(model.error ?? "")
            }
            .alert(model.message ?? "", isPresented: Binding(
                get: { model.message != nil }, set: { if !$0 { model.message = nil } }
            )) {
                Button("OK") {}
            }
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct FileRow: View {
    let entry: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                // Files are buttons, which centre wrapped text; keep long names flush left.
                Text(entry.name)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        let date = entry.modified.formatted(date: .abbreviated, time: .shortened)
        if entry.isDirectory { return date }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)) · \(date)"
    }

    private var symbol: String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isSymlink { return "arrow.turn.up.right" }
        guard let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if (entry.name as NSString).pathExtension.lowercased() == "apk" { return "app.badge" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    static func isMedia(_ name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }
}
