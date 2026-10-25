import AdbKit
import SwiftUI
import UIKit

struct LiveScreen: View {
    let session: DeviceSession
    @Bindable var model: ScreenModel
    @Binding var fullScreen: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = false

    var body: some View {
        // One layout for both modes so the video view (and stream) survives the switch.
        VStack(spacing: 0) {
            surface
            if !fullScreen { bottomControls }
        }
        .ignoresSafeArea(edges: fullScreen ? .all : [])
        .overlay(alignment: .topTrailing) {
            if fullScreen { fullScreenControls }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
        }
    }

    private var surface: some View {
        ZStack {
            Color.black
            ScreenSurface(model: model)
                .aspectRatio(model.frameSize.width / max(model.frameSize.height, 1), contentMode: .fit)
            if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Try Again") { model.stop(); model.start() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if model.status == "Starting…" {
                ProgressView("Starting…").tint(.white).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A small corner button; tapping it shows the buttons and the exit control.
    private var fullScreenControls: some View {
        HStack(spacing: 18) {
            if showControls {
                barButton("arrow.uturn.backward", "Back") { session.sendInput { try await $0.press(.back) } }
                barButton("house", "Home") { session.sendInput { try await $0.press(.home) } }
                barButton("circle.circle", "OK") { session.sendInput { try await $0.press(.dpadCenter) } }
                barButton("speaker.minus", "Volume down") { session.sendInput { try await $0.press(.volumeDown) } }
                barButton("speaker.plus", "Volume up") { session.sendInput { try await $0.press(.volumeUp) } }
                barButton("arrow.down.right.and.arrow.up.left", "Exit Full Screen") {
                    showControls = false
                    fullScreen = false
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
                    }
                }
            }
            barButton(showControls ? "xmark" : "ellipsis", showControls ? "Hide buttons" : "Show buttons") {
                withAnimation(.snappy) { showControls.toggle() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(showControls ? 1 : 0.6), in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(10)
    }

    @ViewBuilder
    private var bottomControls: some View {
            if let status = model.status, status != "Starting…" {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.horizontal)
            }

            HStack(spacing: 28) {
                barButton("arrow.uturn.backward", "Back") { session.sendInput { try await $0.press(.back) } }
                barButton("house", "Home") { session.sendInput { try await $0.press(.home) } }
                barButton("circle.circle", "OK") { session.sendInput { try await $0.press(.dpadCenter) } }
                barButton("square.stack", "Recents") { session.sendInput { try await $0.press(.appSwitch) } }
                barButton("speaker.minus", "Volume down") { session.sendInput { try await $0.press(.volumeDown) } }
                barButton("speaker.plus", "Volume up") { session.sendInput { try await $0.press(.volumeUp) } }
            }
            .padding(.vertical, 12)
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(width: 40, height: 36)
        }
        .accessibilityLabel(label)
    }
}

/// Hosts the video layer (or the latest screenshot) and turns touches into device taps.
private struct ScreenSurface: UIViewRepresentable {
    let model: ScreenModel

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.model = model
        view.layer.addSublayer(model.renderer.layer)
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.model = model
        view.imageView.image = model.mode == .screenshots ? model.still : nil
        view.setNeedsLayout()
    }
}

final class SurfaceView: UIView {
    weak var model: ScreenModel?
    let imageView = UIImageView()
    private var pointerIds: [ObjectIdentifier: Int] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        model?.renderer.layer.frame = bounds
        CATransaction.commit()
        imageView.frame = bounds
    }

    /// View point → device pixel, using the aspect-fit rect of the frame.
    private func devicePoint(_ point: CGPoint) -> CGPoint? {
        guard let size = model?.frameSize, size.width > 0, size.height > 0, bounds.width > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (bounds.width - drawn.width) / 2, y: (bounds.height - drawn.height) / 2)
        let x = (point.x - origin.x) / scale
        let y = (point.y - origin.y) / scale
        return CGPoint(x: min(max(x, 0), size.width - 1), y: min(max(y, 0), size.height - 1))
    }

    private func send(_ touches: Set<UITouch>, _ action: TouchAction) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if action == .down {
                // Lowest free pointer id, like Android expects.
                var id = 0
                while pointerIds.values.contains(id) { id += 1 }
                pointerIds[key] = id
            }
            guard let id = pointerIds[key], let point = devicePoint(touch.location(in: self)) else { continue }
            model?.touch(action, id: id, at: point)
            if action == .up { pointerIds[key] = nil }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, .down) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, .move) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, .up) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, .up) }
}
