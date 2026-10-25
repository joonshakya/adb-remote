import AdbKit
import Foundation
import Observation
import UIKit

/// Saved devices, live sessions and which one is selected.
@MainActor @Observable
final class DeviceStore {
    private(set) var devices: [SavedDevice] = []
    private(set) var sessions: [UUID: DeviceSession] = [:]
    var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedDevice") }
    }
    let key: AdbKey
    var keyError: String?
    /// A connect attempt found Wi-Fi off: UI asks the user to turn it on.
    var wifiPrompt = false
    /// When the app last went to the background (its connections pause there).
    @ObservationIgnored var lastBackgrounded = Date.distantPast

    init() {
        // Key lives in a file (not the keychain) so it is stable inside LiveContainer.
        SharedStorage.migrateIntoGroupIfNeeded()
        do {
            key = try SharedStorage.loadKey(deviceName: UIDevice.current.name)
        } catch {
            keyError = error.localizedDescription
            key = try! AdbKey.generate(name: "AdbRemote@iPhone")
        }
        devices = SharedStorage.loadDevices()
        if let id = UserDefaults.standard.string(forKey: "selectedDevice").flatMap(UUID.init),
           devices.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = devices.first?.id
        }
        NetworkStatus.shared.onReconnect = { [weak self] in
            self?.wifiPrompt = false
            self?.reconnectDropped()
        }
    }

    var selectedDevice: SavedDevice? { devices.first { $0.id == selectedID } }
    var selectedSession: DeviceSession? { selectedDevice.map(session(for:)) }

    func session(for device: SavedDevice) -> DeviceSession {
        if let existing = sessions[device.id] { return existing }
        let session = DeviceSession(deviceID: device.id, store: self)
        sessions[device.id] = session
        return session
    }

    func device(_ id: UUID) -> SavedDevice? { devices.first { $0.id == id } }

    @discardableResult
    func add(name: String, host: String, port: UInt16?) -> SavedDevice {
        let device = SavedDevice(name: name.isEmpty ? host : name, host: host, port: port)
        devices.append(device)
        selectedID = device.id
        save()
        return device
    }

    func update(_ device: SavedDevice) {
        guard let i = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[i] = device
        save()
    }

    func remove(_ id: UUID) {
        sessions[id]?.disconnect()
        sessions[id] = nil
        devices.removeAll { $0.id == id }
        if selectedID == id { selectedID = devices.first?.id }
        save()
    }

    /// Reconnects sessions that dropped while the app was in the background.
    func reconnectDropped() {
        guard NetworkStatus.shared.onLocalNetwork else { return }
        for session in sessions.values where session.shouldAutoReconnect {
            Task { await session.connect() }
        }
    }

    private func save() {
        do {
            try SharedStorage.saveDevices(devices)
        } catch {
            print("save devices failed: \(error)")
        }
    }
}
