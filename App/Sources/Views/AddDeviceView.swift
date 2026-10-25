import SwiftUI

/// Add or edit a saved device.
struct AddDeviceView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var editing: SavedDevice?

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                    TextField("IP address", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port (blank = auto)", text: $port)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Leave the port blank to try 5555 and offer a port scan if it is closed. You can also type host:port in the address field.")
                }
            }
            .navigationTitle(editing == nil ? "Add Device" : "Edit Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Connect" : "Save") { save() }
                        .disabled(parsed == nil)
                }
            }
            .onAppear {
                if let editing {
                    name = editing.name
                    host = editing.host
                    port = editing.port.map(String.init) ?? ""
                }
            }
        }
    }

    /// Accepts "host", "host:port" or separate port field.
    private var parsed: (host: String, port: UInt16?)? {
        var h = host.trimmingCharacters(in: .whitespaces)
        var p: UInt16?
        if let colon = h.lastIndex(of: ":"), let value = UInt16(h[h.index(after: colon)...]) {
            p = value
            h = String(h[..<colon])
        }
        let typed = port.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            guard let value = UInt16(typed), value > 0 else { return nil }
            p = value
        }
        return h.isEmpty ? nil : (h, p)
    }

    private func save() {
        guard let parsed else { return }
        if var device = editing {
            device.name = name.isEmpty ? parsed.host : name
            if device.host != parsed.host { device.lastPort = nil }
            device.host = parsed.host
            device.port = parsed.port
            store.update(device)
        } else {
            let device = store.add(name: name, host: parsed.host, port: parsed.port)
            let session = store.session(for: device)
            Task { await session.connect() }
        }
        dismiss()
    }
}

/// Android 11+ wireless debugging: pair with the six-digit code.
struct PairDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    let session: DeviceSession

    @State private var port = ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Device", value: session.device?.host ?? "")
                    TextField("Pairing port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Six-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .font(.title3.monospacedDigit())
                } footer: {
                    Text("On the device: Developer options › Wireless debugging › Pair device with pairing code. Enter the port after the colon in \"IP address & Port\" and the code shown there.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Pair") { pair() }
                            .disabled(UInt16(port) == nil || code.count < 6)
                    }
                }
            }
        }
    }

    private func pair() {
        guard let port = UInt16(port) else { return }
        working = true
        error = nil
        Task {
            do {
                try await session.pair(port: port, code: code)
                dismiss()
                // The connect port differs from the pairing port; auto-connect finds it.
                await session.connect()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
