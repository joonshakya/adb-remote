import SwiftUI

@main
struct AdbRemoteApp: App {
    @State private var store = DeviceStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS drops sockets in the background; reconnect when we come back.
            if phase == .active { store.reconnectDropped() }
            if phase == .background { store.lastBackgrounded = Date() }
        }
    }
}

struct RootView: View {
    @Environment(DeviceStore.self) private var store
    /// Text handed over via adbremote://send?text=... (e.g. from the Share extension).
    @State private var incoming: String?

    var body: some View {
        TabView {
            DeviceTab()
                .tabItem { Label("Devices", systemImage: "tv") }
            ControlTab()
                .tabItem { Label("Control", systemImage: "av.remote") }
            PlayTab()
                .tabItem { Label("Play", systemImage: "photo.on.rectangle") }
            AppsTab()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            FilesTab()
                .tabItem { Label("Files", systemImage: "folder") }
        }
        .onOpenURL { url in
            guard url.scheme == SharedStorage.urlScheme, url.host == "send",
                  let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "text" })?.value else { return }
            incoming = text
        }
        .sheet(item: Binding(get: { incoming.map(SendText.init) }, set: { incoming = $0?.text })) { item in
            SendSheet(text: item.text)
        }
        .alert("Turn On Wi-Fi", isPresented: Bindable(store).wifiPrompt) {
            Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your TV is reached over Wi-Fi. Turn on Wi-Fi (swipe down for Control Center) and join the same network as the TV. I'll reconnect as soon as it's back.")
        }
    }
}
