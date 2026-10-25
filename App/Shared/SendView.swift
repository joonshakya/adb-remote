import AdbKit
import SwiftUI

/// "Send to TV" flow, shared by the Share extension and the app:
/// one reachable TV → send right away; several → ask; none → ask which to try.
@MainActor @Observable
final class SendModel {
    enum Phase: Equatable {
        case looking
        case choose(reachable: [SavedDevice], others: [SavedDevice])
        case sending(String)
        case sent(device: String, detail: String)
        case failed(String)
        case noDevices
    }

    let payload: LinkSender.Payload
    private let devices: [SavedDevice]
    private let connect: (SavedDevice) async throws -> AdbConnection
    private(set) var phase: Phase = .looking

    init(input: String, devices: [SavedDevice], connect: @escaping (SavedDevice) async throws -> AdbConnection) {
        payload = LinkSender.payload(for: input)
        self.devices = devices
        self.connect = connect
    }

    var summary: String {
        switch payload {
        case .youtube(let url): "YouTube video\n\(url.absoluteString)"
        case .web(let url): url.absoluteString
        case .text(let text): text
        }
    }

    func start(alreadyConnected: Set<UUID> = []) async {
        guard !devices.isEmpty else {
            phase = .noDevices
            return
        }
        guard await NetworkStatus.shared.check() else {
            phase = .failed(NetworkStatus.wifiOffMessage)
            return
        }
        phase = .looking
        var reachable: [SavedDevice] = []
        await withTaskGroup(of: (SavedDevice, Bool).self) { group in
            for device in devices {
                group.addTask {
                    (device, alreadyConnected.contains(device.id) ? true : await LinkSender.isReachable(device))
                }
            }
            for await (device, ok) in group where ok { reachable.append(device) }
        }
        let ordered = devices.filter { d in reachable.contains { $0.id == d.id } }
        if ordered.count == 1 {
            await send(to: ordered[0])
        } else {
            phase = .choose(reachable: ordered, others: devices.filter { d in !ordered.contains { $0.id == d.id } })
        }
    }

    func send(to device: SavedDevice) async {
        phase = .sending("Connecting to \(device.name)…")
        do {
            let adb = try await connect(device)
            phase = .sending("Sending to \(device.name)…")
            let detail = try await LinkSender.send(payload, via: adb) { [weak self] status in
                Task { @MainActor in self?.phase = .sending(status) }
            }
            phase = .sent(device: device.name, detail: detail)
        } catch {
            phase = .failed("\(device.name): \(error.localizedDescription)")
        }
    }
}

struct SendView: View {
    @Bindable var model: SendModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(model.summary).font(.footnote).lineLimit(3)
                    } icon: {
                        Image(systemName: icon)
                    }
                }
                content
            }
            .navigationTitle("Send to TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) }
            }
        }
    }

    private var icon: String {
        switch model.payload {
        case .youtube: "play.rectangle.fill"
        case .web: "link"
        case .text: "text.cursor"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .looking:
            Section { HStack { ProgressView(); Text("Looking for your TVs…").foregroundStyle(.secondary) } }
        case .noDevices:
            Section {
                Text("No TVs yet. Open ADB Remote and add your TV first.")
            }
        case .choose(let reachable, let others):
            if !reachable.isEmpty {
                Section("Which TV?") {
                    ForEach(reachable) { device in deviceButton(device, online: true) }
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { device in deviceButton(device, online: false) }
                } header: {
                    Text(reachable.isEmpty ? "No TV answered. Which one should I try?" : "Not answering")
                } footer: {
                    if reachable.isEmpty { Text("Make sure the TV is on and connected to the same Wi-Fi.") }
                }
            }
        case .sending(let status):
            Section { HStack { ProgressView(); Text(status) } }
        case .sent(let device, let detail):
            Section {
                Label {
                    VStack(alignment: .leading) {
                        Text("Sent to \(device)").font(.headline)
                        Text(detail).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onClose()
            }
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(.red)
                Button("Try Again") { Task { await model.start() } }
            }
        }
    }

    private func deviceButton(_ device: SavedDevice, online: Bool) -> some View {
        Button {
            Task { await model.send(to: device) }
        } label: {
            HStack {
                Image(systemName: "tv")
                VStack(alignment: .leading) {
                    Text(device.name)
                    Text(device.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(online ? Color.green : Color.gray).frame(width: 8, height: 8)
            }
        }
        .foregroundStyle(.primary)
    }
}
