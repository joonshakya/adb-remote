import AdbKit
import SwiftUI
import UIKit

/// Remote buttons, trackpad and live screen in one tab, switched at the top.
struct ControlTab: View {
    enum Mode: String, CaseIterable {
        case buttons = "Buttons", trackpad = "Trackpad", screen = "Screen"
    }

    @Environment(DeviceStore.self) private var store
    @AppStorage("controlMode") private var mode: Mode = .buttons
    @State private var fullScreen = false

    var body: some View {
        NavigationStack {
            Group {
                if let session = store.selectedSession, session.isConnected, session.info != nil {
                    content(session)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if !fullScreen {
                                Picker("Control", selection: $mode) {
                                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .background(.bar)
                            }
                        }
                } else {
                    NotConnectedView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                DevicePicker()
                if mode == .screen && store.selectedSession?.isConnected == true {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { setFullScreen(true) }
                    }
                }
            }
            .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar, .tabBar)
            .statusBarHidden(fullScreen)
            .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
            .onChange(of: store.selectedSession?.isConnected) { _, connected in
                if connected != true { setFullScreen(false) }
            }
            .onChange(of: mode) { _, mode in
                if mode != .screen && fullScreen { setFullScreen(false) }
            }
            .onDisappear { if fullScreen { setFullScreen(false) } }
        }
    }

    @ViewBuilder
    private func content(_ session: DeviceSession) -> some View {
        switch mode {
        case .buttons:
            RemoteControl(session: session, trackpad: false)
        case .trackpad:
            RemoteControl(session: session, trackpad: true)
        case .screen:
            if let model = session.screenModel() {
                LiveScreen(session: session, model: model, fullScreen: $fullScreen)
                    // Another device (or a reconnect) is a new screen: the old one stops.
                    .id(ObjectIdentifier(model))
            }
        }
    }

    /// Full screen also turns the phone to match the device's screen: sideways for TVs,
    /// upright for portrait screens (phones).
    private func setFullScreen(_ on: Bool) {
        fullScreen = on
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let size = store.selectedSession?.screenModel()?.frameSize ?? CGSize(width: 16, height: 9)
        let wide = size.width >= size.height
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on && wide ? .landscapeRight : .portrait)) { _ in }
    }
}
