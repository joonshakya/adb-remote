import AdbKit
import SwiftUI

struct DeviceTab: View {
    @Environment(DeviceStore.self) private var store
    @State private var showingAdd = false
    @State private var autoConnected = false

    var body: some View {
        NavigationStack {
            Group {
                if store.devices.isEmpty {
                    ContentUnavailableView {
                        Label("No Devices", systemImage: "tv")
                    } description: {
                        Text("Add an Android device with network debugging turned on.")
                    } actions: {
                        Button("Add Device") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.devices) { device in
                                DeviceRow(device: device, session: store.session(for: device))
                            }
                        } footer: {
                            Text("The checked device is used by Control, Play, Apps and Files.")
                        }
                    }
                    .navigationDestination(for: UUID.self) { id in
                        if let device = store.device(id) {
                            DeviceDetail(device: device, session: store.session(for: device))
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Device", systemImage: "plus") { showingAdd = true }
                }
            }
            .sheet(isPresented: $showingAdd) { AddDeviceView() }
            .task {
                // Connect the checked device once at launch.
                if !autoConnected, let session = store.selectedSession, session.state == .disconnected {
                    autoConnected = true
                    await session.connect()
                }
            }
            .task {
                // Refresh online/offline badges while the list is visible.
                while !Task.isCancelled {
                    await withTaskGroup(of: Void.self) { group in
                        for device in store.devices {
                            let session = store.session(for: device)
                            group.addTask { await session.checkReachability() }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    @Environment(DeviceStore.self) private var store
    let device: SavedDevice
    let session: DeviceSession

    private var isSelected: Bool { store.selectedID == device.id }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.selectedID = device.id
                if session.state == .disconnected || isFailed {
                    Task { await session.connect() }
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isSelected ? "Selected" : "Select \(device.name)")

            NavigationLink(value: device.id) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.headline)
                        Text(device.address)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(session: session)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if session.isConnected {
                Button("Disconnect") { session.disconnect() }
                    .tint(.orange)
            } else {
                Button("Connect") { Task { await session.connect() } }
                    .tint(.green)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }
}

private struct StatusBadge: View {
    let session: DeviceSession

    var body: some View {
        // Connected: the delay chip alone says it (and keeps the row on one line).
        if session.isConnected {
            LatencyLabel(session: session)
        } else {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(text)
            }
            .lineLimit(1)
            .fixedSize()
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    private var text: String {
        switch session.state {
        case .connected: return "Connected"
        case .connecting: return session.scan != nil ? "Scanning" : "Connecting"
        case .waitingForApproval: return "Approve on TV"
        case .failed, .disconnected:
            switch session.reachable {
            case true: return "Online"
            case false: return "Offline"
            default: return "—"
            }
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting, .waitingForApproval: return .orange
        case .failed, .disconnected: return session.reachable == true ? .blue : .gray
        }
    }
}

private struct DeviceDetail: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    @Bindable var session: DeviceSession

    @State private var editing = false
    @State private var pairing = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            ConnectionSection(device: device, session: session, pairing: $pairing)
            if session.isConnected {
                if let info = session.info {
                    Section("About This TV") {
                        ForEach(info.rows, id: \.0) { row in
                            LabeledContent(row.0, value: row.1)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Section { ProgressView("Reading device info…") }
                }
                if let extras = session.extras {
                    FeaturesSection(extras: extras)
                    RootSection(root: extras.root)
                    PlaySection(play: extras.play)
                    SpeedSection(session: session)
                }
                if let info = session.info {
                    AdvancedSection(info: info, extras: session.extras)
                }
            }
            Section {
                Button("Edit Device", systemImage: "pencil") { editing = true }
                Button("Pair with Code (Android 11+)", systemImage: "number") { pairing = true }
                ShareLink(item: EventLog.url(for: device.name)) {
                    Label("Share Connection Log", systemImage: "doc.text.magnifyingglass")
                }
                // Explicit colors: in a List the icon otherwise takes the blue accent color.
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label {
                        Text("Remove Device").foregroundStyle(.red)
                    } icon: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                }
            }
        }
        .refreshable { await session.refreshInfo() }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { AddDeviceView(editing: device) }
        .sheet(isPresented: $pairing) { PairDeviceView(session: session) }
        .confirmationDialog("Remove \(device.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.remove(device.id)
                dismiss()
            }
        }
        .alert("Port 5555 is closed", isPresented: $session.offerPortScan) {
            Button("Scan Ports") { session.startPortScan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scan \(device.host) for other open ports and look for ADB? Only likely ports are checked first; if a full scan is needed, other services on the device receive a short ADB probe.")
        }
        .confirmationDialog("Several ADB ports found", isPresented: Binding(
            get: { !session.portChoices.isEmpty },
            set: { if !$0 { session.portChoices = [] } }
        ), titleVisibility: .visible) {
            ForEach(session.portChoices, id: \.port) { choice in
                Button("Port \(choice.port)\(choice.kind == .adbTLS ? " (wireless debugging)" : "")") {
                    Task { await session.connect(port: choice.port) }
                }
            }
        }
    }
}

private struct ConnectionSection: View {
    let device: SavedDevice
    let session: DeviceSession
    @Binding var pairing: Bool

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "tv")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.info?.displayName ?? device.name)
                        .font(.headline)
                    Text(device.address)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(session: session)
            }

            switch session.state {
            case .connected:
                Button("Disconnect", role: .destructive) { session.disconnect() }
            case .connecting(let message):
                if let scan = session.scan {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(scan.scanned), total: Double(max(scan.total, 1)))
                        Text(scan.probing ? "Checking open ports for ADB…" : "Scanned \(scan.scanned) of \(scan.total) ports")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !scan.openPorts.isEmpty {
                            Text("Open: \(scan.openPorts.map(String.init).joined(separator: ", "))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Stop Scan", role: .cancel) { session.cancelScan() }
                } else {
                    HStack {
                        ProgressView()
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            case .waitingForApproval:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView()
                        Text("Waiting for approval").font(.headline)
                    }
                    Text("On the TV, choose \"Always allow from this computer\" and tap Allow in the USB debugging prompt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .font(.subheadline)
                if session.needsPairing {
                    Button("Pair with Code", systemImage: "number") { pairing = true }
                }
                Button("Retry", systemImage: "arrow.clockwise") { Task { await session.connect() } }
                if device.port == nil && !session.offerPortScan {
                    Button("Scan Ports", systemImage: "magnifyingglass") { session.startPortScan() }
                }
            case .disconnected:
                Button("Connect", systemImage: "bolt.horizontal") { Task { await session.connect() } }
            }
        }
    }
}

private struct RootSection: View {
    let root: RootStatus

    var body: some View {
        Section {
            LabeledContent("Rooted", value: root.answer)
        } header: {
            Text("Root Access")
        } footer: {
            Text(root.explanation)
        }
    }
}

private struct PlaySection: View {
    let play: GooglePlayStatus

    var body: some View {
        Section {
            LabeledContent("Play Store", value: play.playStoreVersion.map { "Installed (\($0))" } ?? "Not installed")
            LabeledContent("Google services", value: play.hasPlayServices ? "Installed" : "Not installed")
        } header: {
            Text("Google Play")
        } footer: {
            if !play.hasPlayStore {
                Text("Without the Play Store, install apps from files using the Apps tab.")
            }
        }
    }
}

private struct SpeedSection: View {
    let session: DeviceSession

    var body: some View {
        Section {
            if let result = session.speedTest {
                LabeledContent("Phone → TV", value: SpeedTestResult.format(result.uploadBytesPerSecond))
                LabeledContent("TV → Phone", value: SpeedTestResult.format(result.downloadBytesPerSecond))
                LabeledContent("Response time", value: "\(Int(result.latency * 1000)) ms")
            }
            if let status = session.speedTestStatus {
                HStack {
                    if !status.hasPrefix("Failed") { ProgressView() }
                    Text(status).foregroundStyle(.secondary)
                }
            } else {
                Button(session.speedTest == nil ? "Test Speed" : "Test Again", systemImage: "speedometer") {
                    Task { await session.runSpeedTest() }
                }
            }
        } header: {
            Text("Transfer Speed")
        } footer: {
            Text("How fast files, apps and photos move between your phone and this TV.")
        }
    }
}

private struct FeaturesSection: View {
    let extras: DeviceExtras

    var body: some View {
        Section("What Works on This TV") {
            ForEach(extras.capabilities) { capability in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: capability.supported ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(capability.supported ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capability.name)
                        Text(capability.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AdvancedSection: View {
    let info: DeviceInfo
    let extras: DeviceExtras?

    var body: some View {
        Section {
            DisclosureGroup("More details") {
                ForEach(info.advancedRows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                        .textSelection(.enabled)
                }
                if let extras {
                    ForEach(extras.root.details, id: \.0) { row in
                        LabeledContent(row.0, value: row.1)
                    }
                    if !extras.play.googlePackages.isEmpty {
                        LabeledContent("Google packages", value: extras.play.googlePackages.joined(separator: "\n"))
                    }
                    LabeledContent("ADB features", value: extras.adbFeatures.isEmpty ? "None (older Android)" : extras.adbFeatures.joined(separator: ", "))
                }
            }
        } footer: {
            Text("Technical information, useful when troubleshooting.")
        }
    }
}
