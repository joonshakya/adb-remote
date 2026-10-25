import AdbKit
import SwiftUI
import UIKit

/// Phone-as-trackpad: one finger moves the TV's pointer, tap clicks, two-finger tap goes
/// back (right click), two fingers scroll, and touch-and-hold then move drags.
struct TrackpadView: View {
    let session: DeviceSession

    var body: some View {
        TrackpadSurfaceView(sender: session.trackpad())
            .onDisappear { session.trackpad()?.hide() }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22).strokeBorder(Color.secondary.opacity(0.25))
            }
            .overlay(alignment: .bottom) {
                Text("Tap to click · Two fingers to scroll · Two-finger tap = Back · Hold, then move to drag")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Trackpad")
    }
}

private struct TrackpadSurfaceView: UIViewRepresentable {
    let sender: PointerSender?

    func makeUIView(context: Context) -> TrackpadSurface { TrackpadSurface() }

    func updateUIView(_ view: TrackpadSurface, context: Context) {
        view.sender = sender
    }
}

final class TrackpadSurface: UIView {
    var sender: PointerSender?

    private var maxTouches = 0
    private var moved = false
    private var dragging = false
    private var startTime = Date()
    private var startPoint = CGPoint.zero
    private var lastTime = Date()
    private var holdTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let count = event?.allTouches?.count ?? touches.count
        if maxTouches == 0 {
            moved = false
            startPoint = touches.first?.location(in: self) ?? .zero
            startTime = Date()
            lastTime = startTime
            haptic.prepare()
        }
        maxTouches = max(maxTouches, count)
        holdTimer?.invalidate()
        if count == 1 {
            // Touch and hold without moving: press the button down for dragging.
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                guard let self, !self.moved, self.maxTouches == 1 else { return }
                self.dragging = true
                self.haptic.impactOccurred()
                self.sender?.setButtons(1)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
        guard !active.isEmpty else { return }
        var dx: CGFloat = 0, dy: CGFloat = 0
        for touch in active {
            let now = touch.location(in: self), before = touch.previousLocation(in: self)
            dx += now.x - before.x
            dy += now.y - before.y
        }
        dx /= CGFloat(active.count)
        dy /= CGFloat(active.count)
        // A few points of wobble still count as a tap.
        if !moved, let point = active.first?.location(in: self),
           hypot(point.x - startPoint.x, point.y - startPoint.y) > 8 {
            moved = true
            if !dragging { holdTimer?.invalidate() }
        }

        let now = Date()
        let interval = max(now.timeIntervalSince(lastTime), 0.004)
        lastTime = now
        if active.count >= 2 {
            sender?.scroll(dx: dx, dy: dy)
        } else {
            // Faster swipes travel further, like a laptop trackpad.
            let speed = hypot(dx, dy) / interval
            let gain = 1.6 + min(speed / 500, 3)
            sender?.move(dx: dx * gain, dy: dy * gain)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        guard remaining.isEmpty else { return }
        holdTimer?.invalidate()
        let quick = Date().timeIntervalSince(startTime) < 0.3
        if dragging {
            sender?.setButtons(0)
        } else if quick && !moved {
            if maxTouches >= 2 {
                sender?.click(button: 2) // right click = Back on Android
            } else {
                sender?.click(button: 1)
            }
            haptic.impactOccurred(intensity: 0.5)
        }
        dragging = false
        maxTouches = 0
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdTimer?.invalidate()
        if dragging { sender?.setButtons(0) }
        dragging = false
        maxTouches = 0
    }
}
