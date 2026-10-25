import AdbKit
import SwiftUI
import WebKit

extension DeviceStore {
    /// Send flow inside the app: reuses live connections, connects others on demand.
    func makeSendModel(_ text: String) -> SendModel {
        SendModel(input: text, devices: devices) { [weak self] device in
            guard let self else { throw AdbError.closed }
            let session = self.session(for: device)
            if let connection = session.connection { return connection }
            await session.connect()
            if let connection = session.connection { return connection }
            throw AdbError.command(session.stateDescription)
        }
    }

    var connectedIDs: Set<UUID> {
        Set(sessions.values.filter(\.isConnected).map(\.deviceID))
    }
}

extension DeviceSession {
    var stateDescription: String {
        if case .failed(let message) = state { return message }
        return "Couldn't connect"
    }
}

/// Presents the send flow for a piece of text (from a link, the share extension or paste).
struct SendSheet: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var model: SendModel?

    var body: some View {
        Group {
            if let model {
                SendView(model: model, onClose: { dismiss() })
            } else {
                ProgressView()
            }
        }
        .task {
            let model = store.makeSendModel(text)
            self.model = model
            await model.start(alreadyConnected: store.connectedIDs)
        }
    }
}

/// Paste a link and send it (Play tab → Link).
struct LinkForm: View {
    @State private var link = ""
    @State private var sending: String?

    var body: some View {
        Form {
            Section {
                TextField("Paste a YouTube or web link", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if let pasted = UIPasteboard.general.hasURLs ? UIPasteboard.general.url?.absoluteString : nil, link.isEmpty {
                    Button("Use copied link", systemImage: "doc.on.clipboard") { link = pasted }
                }
                Button("Send to TV", systemImage: "paperplane.fill") { sending = link }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("YouTube links open in the TV's YouTube app. Other links open in its browser. You can also share from the YouTube app or Safari and pick \"Send to TV\".")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: Binding(get: { sending.map(SendText.init) }, set: { sending = $0?.text })) { item in
            SendSheet(text: item.text)
        }
    }
}

struct SendText: Identifiable {
    let text: String
    var id: String { text }
}

/// m.youtube.com in a web view with a "Play on TV" button for the current video
/// (Play tab → YouTube). Back/Forward live in the Play tab's toolbar.
struct YouTubePage: View {
    let page: WebPageState
    @State private var sending: String?

    var body: some View {
        WebView(state: page)
            // The web view moves its own content for the keyboard; letting SwiftUI resize
            // it too left YouTube's search box in the wrong place and ate the first tap.
            .ignoresSafeArea(.keyboard)
            .overlay(alignment: .bottom) {
                if let url = page.url, LinkSender.youtubeWatchURL(url) != nil {
                    Button {
                        page.pauseVideo()
                        sending = url.absoluteString
                    } label: {
                        Label("Play on TV", systemImage: "tv")
                            .font(.headline)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 20)
                }
            }
            .sheet(item: Binding(get: { sending.map(SendText.init) }, set: { sending = $0?.text })) { item in
                SendSheet(text: item.text)
                    .presentationDetents([.medium])
            }
    }
}

@Observable
final class WebPageState {
    var url: URL?
    var canGoBack = false
    var canGoForward = false
    /// Kept here (not in the view) so switching away and back keeps your place.
    var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    /// Pause playback on the phone once the video moves to the TV.
    func pauseVideo() {
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
    }
}

private struct WebView: UIViewRepresentable {
    let state: WebPageState

    func makeUIView(context: Context) -> WKWebView {
        if let existing = state.webView {
            context.coordinator.observe(existing)
            return existing
        }
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        state.webView = view
        context.coordinator.observe(view)
        view.load(URLRequest(url: URL(string: "https://m.youtube.com")!))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    final class Coordinator {
        let state: WebPageState
        private var observations: [NSKeyValueObservation] = []

        init(state: WebPageState) { self.state = state }

        /// YouTube is a single-page app, so watch the URL rather than navigation events.
        func observe(_ view: WKWebView) {
            observations = [
                view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                    DispatchQueue.main.async { self?.state.url = view.url }
                },
                view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                    DispatchQueue.main.async { self?.state.canGoBack = view.canGoBack }
                },
                view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                    DispatchQueue.main.async { self?.state.canGoForward = view.canGoForward }
                },
            ]
        }
    }
}
