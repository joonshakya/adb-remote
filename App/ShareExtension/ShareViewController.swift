import AdbKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Send to TV" in the iOS share sheet.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await setUp() }
    }

    private func setUp() async {
        let input = await sharedText() ?? ""
        let root: AnyView
        if SharedStorage.groupDirectory == nil {
            // No shared container in this signing setup: hand the link to the app.
            root = AnyView(HandOffView(text: input, onOpen: { [weak self] in self?.openInApp(input) },
                                       onClose: { [weak self] in self?.close() }))
        } else {
            let devices = SharedStorage.loadDevices()
            let key = try? SharedStorage.loadKey(deviceName: UIDevice.current.name)
            let model = SendModel(input: input, devices: devices) { device in
                guard let key else { throw AdbError.command("Open ADB Remote once to set it up.") }
                return try await LinkSender.connect(device, key: key)
            }
            root = AnyView(SendView(model: model, onClose: { [weak self] in self?.close() })
                .task { await model.start() })
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// First URL (preferred) or text among the shared items.
    private func sharedText() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url.absoluteString
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return text
            }
        }
        return nil
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Extensions can't call UIApplication.open directly; find the app object in the
    /// responder chain and invoke open(_:options:completionHandler:) on it.
    private func openInApp(_ text: String) {
        var components = URLComponents()
        components.scheme = SharedStorage.urlScheme
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let url = components.url else { return }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), current.isKind(of: NSClassFromString("UIApplication")!) {
                typealias OpenFunction = @convention(c) (AnyObject, Selector, URL, [String: Any], ((Bool) -> Void)?) -> Void
                let implementation = current.method(for: selector)
                unsafeBitCast(implementation, to: OpenFunction.self)(current, selector, url, [:], nil)
                break
            }
            responder = current.next
        }
        close()
    }
}

private struct HandOffView: View {
    let text: String
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(.tint)
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.center)
                Button("Open ADB Remote to Send", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Send to TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        }
    }
}
