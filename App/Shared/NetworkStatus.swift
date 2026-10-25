import Foundation
import Network
import Observation

/// Whether the phone is on Wi-Fi (or wired), i.e. can reach TVs on the local network.
@MainActor @Observable
final class NetworkStatus {
    static let shared = NetworkStatus()

    static let wifiOffMessage = "Wi-Fi is off. Turn on Wi-Fi and join the same network as your TV."

    private(set) var onLocalNetwork = true
    /// Called when Wi-Fi comes back after being off.
    var onReconnect: (() -> Void)?

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let local = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in NetworkStatus.shared.update(local) }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkStatus"))
    }

    private func update(_ local: Bool) {
        let cameBack = local && !onLocalNetwork
        onLocalNetwork = local
        if cameBack { onReconnect?() }
    }

    /// Waits briefly for the first path update so a cold start doesn't report a stale value.
    func check() async -> Bool {
        let path = monitor.currentPath
        if path.status != .requiresConnection {
            onLocalNetwork = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
        }
        return onLocalNetwork
    }
}
