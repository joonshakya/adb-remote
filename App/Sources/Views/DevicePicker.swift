import SwiftUI

/// Toolbar dropdown for switching between saved devices.
struct DevicePicker: ToolbarContent {
    @Environment(DeviceStore.self) private var store
    @State private var showingAdd = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(store.devices) { device in
                    Button {
                        store.selectedID = device.id
                    } label: {
                        let session = store.sessions[device.id]
                        Label(device.name, systemImage: device.id == store.selectedID ? "checkmark" :
                              (session?.isConnected == true ? "circle.fill" : "circle"))
                    }
                }
                Divider()
                Button("Add Device…", systemImage: "plus") { showingAdd = true }
            } label: {
                HStack(spacing: 6) {
                    StatusDot(session: store.selectedSession)
                    Text(store.selectedDevice?.name ?? "No Device")
                        .font(.headline)
                        .lineLimit(1)
                    if let session = store.selectedSession, session.isConnected {
                        LatencyLabel(session: session)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .sheet(isPresented: $showingAdd) { AddDeviceView() }
        }
    }
}

struct StatusDot: View {
    let session: DeviceSession?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        guard let session else { return .gray }
        switch session.state {
        case .connected: return .green
        case .connecting, .waitingForApproval: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }
}

/// How long the TV takes to answer: signal bars plus milliseconds, e.g. "▂▄▆ 6 ms".
/// Turns orange when slow and red ("No reply") when the TV stops answering.
struct LatencyLabel: View {
    let session: DeviceSession

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: timedOut ? "exclamationmark.circle.fill" : "cellularbars", variableValue: bars)
                .symbolRenderingMode(.hierarchical)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        // "No reply" <-> "6 ms" is a different chip, not a changing number: crossfade it.
        .id(timedOut)
        .transition(.opacity)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .animation(.snappy, value: text)
        .animation(.easeInOut(duration: 0.2), value: timedOut)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var timedOut: Bool { session.latencyTimedOut }

    private var text: String {
        if timedOut { return "No reply" }
        guard let latency = session.latency else { return "…" }
        let ms = Int((latency * 1000).rounded())
        return ms >= 1000 ? String(format: "%.1f s", latency) : "\(ms) ms"
    }

    /// Filled bars: 3 fast, 2 okay, 1 slow.
    private var bars: Double {
        guard let latency = session.latency, !timedOut else { return 0 }
        switch latency {
        case ..<0.1: return 1
        case ..<0.3: return 0.66
        default: return 0.33
        }
    }

    private var color: Color {
        if timedOut { return .red }
        guard let latency = session.latency else { return .secondary }
        switch latency {
        case ..<0.1: return .green
        case ..<0.3: return .orange
        default: return .red
        }
    }

    private var accessibility: String {
        if timedOut { return "TV is not replying" }
        guard let latency = session.latency else { return "Measuring delay" }
        return "Delay \(Int(latency * 1000)) milliseconds"
    }
}
