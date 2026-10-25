import AdbKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsTab: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if let session = store.selectedSession, session.isConnected, let model = session.appsModel() {
                    AppsGrid(model: model)
                } else {
                    NotConnectedView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DevicePicker() }
        }
    }
}

private struct AppsGrid: View {
    @Bindable var model: AppsModel

    @State private var showBuiltIn = false
    @State private var picking = false
    @State private var selected: InstalledApp?
    @State private var confirmUninstall: InstalledApp?
    @State private var shareURL: URL?

    /// Apps with a launcher icon, plus everything else when "built-in" is on.
    private var visible: [InstalledApp] {
        model.apps.filter { showBuiltIn || $0.isLaunchable || !$0.isSystem }
    }

    var body: some View {
        withDialogs(grid)
    }

    private var grid: some View {
        ScrollView {
            if model.apps.isEmpty && model.isLoading {
                ProgressView("Loading apps…").padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 18) {
                ForEach(visible) { app in
                    AppCell(app: app, icon: model.icons[app.packageName])
                        // Tap opens the app on the TV; apps without a launcher entry show their details.
                        .onTapGesture {
                            if app.isLaunchable { Task { await model.open(app) } } else { selected = app }
                        }
                        .contextMenu { menu(for: app) }
                }
            }
            .padding()
            if !model.apps.isEmpty {
                Toggle("Show built-in system apps", isOn: $showBuiltIn)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }
        }
        .refreshable { await model.refresh() }
        .task { if model.apps.isEmpty { await model.refresh() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Install App", systemImage: "plus") { picking = true }
            }
        }
        .documentPicker(isPresented: $picking, types: Self.appFileTypes) { urls in
            Task {
                await model.install(from: urls[0])
                try? FileManager.default.removeItem(at: urls[0])
            }
        }
        .overlay { if let activity = model.activity { ActivityBanner(text: activity) } }
    }

    private func withDialogs(_ content: some View) -> some View {
        withAlerts(content
        .sheet(item: $selected) { app in
            AppDetail(app: app, icon: model.icons[app.packageName], model: model,
                      onUninstall: { confirmUninstall = app }, onShare: { shareURL = $0 })
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(confirmUninstall.map { "Uninstall \($0.label)?" } ?? "", isPresented: Binding(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }
        ), titleVisibility: .visible) {
            if let app = confirmUninstall {
                Button("Uninstall", role: .destructive) {
                    selected = nil
                    Task { await model.uninstall(app) }
                }
            }
        } message: {
            if confirmUninstall?.isSystem == true {
                Text("This is a built-in app. It will be removed for you; a factory reset brings it back.")
            }
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
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

    @ViewBuilder
    private func menu(for app: InstalledApp) -> some View {
        if app.isLaunchable {
            Button("Open on TV", systemImage: "play") { Task { await model.open(app) } }
        }
        Button("Stop App", systemImage: "stop.circle") { Task { await model.stop(app) } }
        Button("Details", systemImage: "info.circle") { selected = app }
        Button("Save App File", systemImage: "square.and.arrow.down") {
            Task { if let url = await model.saveAppFile(app) { shareURL = url } }
        }
        Button("Uninstall", systemImage: "trash", role: .destructive) { confirmUninstall = app }
    }

    /// App files the picker accepts; bundles are recognised by extension.
    static let appFileTypes: [UTType] = {
        var types: [UTType] = []
        for ext in ["apk", "apks", "xapk", "apkm"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        types.append(.data)
        return types
    }()
}

private struct AppCell: View {
    let app: InstalledApp
    let icon: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon {
                    // Tile behind the icon so white or transparent icons stay visible.
                    Image(uiImage: icon).resizable().interpolation(.high)
                        .padding(4)
                        .background(Color(.secondarySystemBackground))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .overlay(Text(String(app.label.prefix(1))).font(.title2.weight(.semibold)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
            Text(app.label)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct AppDetail: View {
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    let icon: UIImage?
    let model: AppsModel
    let onUninstall: () -> Void
    let onShare: (URL) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        if let icon {
                            Image(uiImage: icon).resizable().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.label).font(.title3.weight(.semibold))
                            Text("Version \(app.versionName)").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if app.isLaunchable {
                        Button("Open on TV", systemImage: "play.fill") {
                            dismiss()
                            Task { await model.open(app) }
                        }
                    }
                    Button("Stop App", systemImage: "stop.circle") {
                        Task { await model.stop(app) }
                    }
                    Button("Save App File", systemImage: "square.and.arrow.down") {
                        Task {
                            if let url = await model.saveAppFile(app) {
                                dismiss()
                                onShare(url)
                            }
                        }
                    }
                    Button(role: .destructive) { onUninstall() } label: {
                        Label {
                            Text("Uninstall").foregroundStyle(.red)
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                } footer: {
                    Text("Save App File copies the app to your phone so you can keep it or install it on another TV.")
                }
                Section("Details") {
                    LabeledContent("Package", value: app.packageName)
                        .textSelection(.enabled)
                    LabeledContent("Type", value: app.isSystem ? "Built-in" : "Installed by you")
                    if !app.isEnabled { LabeledContent("Status", value: "Turned off") }
                }
            }
            .navigationTitle(app.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay { if let activity = model.activity { ActivityBanner(text: activity) } }
        }
    }
}

/// Floating "working…" pill.
struct ActivityBanner: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                ProgressView()
                Text(text).font(.subheadline).lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 24)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
