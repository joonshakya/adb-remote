import AdbKit
import SwiftUI

/// Screen mirroring: starts the AirPlay receiver in the TV app, then the iPhone's own
/// Screen Mirroring (Control Center) does the rest, sound included.
struct MirrorPane: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        if let session = store.selectedSession, session.isConnected, let adb = session.connection, let info = session.info {
            MirrorSetup(adb: adb, sdk: info.sdk, tvName: session.device?.name ?? "TV")
                .id(session.deviceID)
        } else {
            NotConnectedView()
        }
    }
}

private struct MirrorSetup: View {
    let adb: AdbConnection
    let sdk: Int
    let tvName: String

    private enum Status: Equatable {
        case checking, off, starting(String), ready, failed(String)
    }

    @State private var status = Status.checking

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .padding(.top, 30)
                Text("Show your iPhone's screen on \(tvName)")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                content
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .task { await check() }
        .animation(.snappy, value: status)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .checking:
            ProgressView()
        case .off, .failed:
            if case .failed(let message) = status {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Text("Sound plays on the TV too. Apps that protect their videos, like Netflix, show black.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await start() }
            } label: {
                Text("Get \(tvName) Ready").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .starting(let text):
            HStack(spacing: 10) {
                ProgressView()
                Text(text)
            }
            .foregroundStyle(.secondary)
        case .ready:
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Open Control Center: swipe down from the top-right corner.")
                step(2, "Tap Screen Mirroring.")
                step(3, "Choose “\(tvName)”.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            Text("To stop, tap Stop Mirroring in Control Center, or press Back on the TV remote. \(tvName) stops listening by itself after 10 minutes without mirroring.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Turn Off on \(tvName)", role: .destructive) {
                Task { await stop() }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.tint.opacity(0.2)))
            Text(text)
        }
    }

    // MARK: TV side

    private static let service = "\(CastModel.package)/.airplay.AirPlayService"

    private func check() async {
        let out = (try? await adb.shell("dumpsys activity services \(Self.service)").output) ?? ""
        status = out.contains("ServiceRecord") ? .ready : .off
    }

    private func start() async {
        status = .starting("Preparing \(tvName)…")
        do {
            try await CastModel.installViewer(adb: adb, sdk: sdk) {
                Task { @MainActor in status = .starting("Installing the TV app…") }
            }
            // Lets the receiver open its screen when mirroring starts (Android 10+ blocks that otherwise).
            if sdk >= 23 { _ = try? await adb.shell("appops set \(CastModel.package) SYSTEM_ALERT_WINDOW allow") }
            let verb = sdk >= 26 ? "start-foreground-service" : "startservice"
            let output = try await adb.shell("am \(verb) -n \(Self.service) --es name \(shellQuote(tvName))").output
            if output.contains("Error") { throw AdbError.command(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await check()
            if status != .ready { status = .failed("\(tvName) didn't start the receiver. Try again.") }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() async {
        let verb = sdk >= 26 ? "start-foreground-service" : "startservice"
        _ = try? await adb.shell("am \(verb) -n \(Self.service) --es action stop")
        try? await Task.sleep(nanoseconds: 500_000_000)
        await check()
    }
}
