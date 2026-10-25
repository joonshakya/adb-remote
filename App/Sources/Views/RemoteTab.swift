import AdbKit
import SwiftUI

/// Shown on tabs that need a live connection.
struct NotConnectedView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            if NetworkStatus.shared.onLocalNetwork {
                Label("Not Connected", systemImage: "tv.slash")
            } else {
                Label("Wi-Fi Is Off", systemImage: "wifi.slash")
            }
        } description: {
            if !NetworkStatus.shared.onLocalNetwork {
                Text("Turn on Wi-Fi and join the same network as your TV.")
            } else {
                Text(store.selectedDevice == nil ? "Add a device on the Devices tab." : "Connect to \(store.selectedDevice!.name) first.")
            }
        } actions: {
            if let session = store.selectedSession, !session.isBusy {
                Button("Connect") { Task { await session.connect() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Remote buttons, or the trackpad (picked in the Control tab).
struct RemoteControl: View {
    let session: DeviceSession
    let trackpad: Bool

    @State private var keyboardActive = false
    @State private var modifiers: MetaState = []
    @State private var text = ""

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Group {
            if !trackpad {
                buttonsLayout
            } else {
                trackpadLayout
            }
        }
        .onAppear { _ = session.remoteInput() }
    }

    /// Trackpad fills the screen (no scrolling, so every finger movement goes to the TV).
    private var trackpadLayout: some View {
        VStack(spacing: 16) {
            statusLine
            TrackpadView(session: session)
                .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                KeyButton("arrow.uturn.backward", label: "Back") { press(.back) }
                KeyButton("house", label: "Home") { press(.home) }
                KeyButton("square.stack", label: "Recents") { press(.appSwitch) }
                KeyButton("speaker.minus", label: "Vol −") { press(.volumeDown) }
                KeyButton("speaker.plus", label: "Vol +") { press(.volumeUp) }
            }
            keyboardSection
        }
        .padding()
    }

    private var buttonsLayout: some View {
        ScrollView {
            VStack(spacing: 22) {
                statusLine

                HStack(spacing: 14) {
                    KeyButton("power", label: "Power", tint: .red) { press(.power) }
                    KeyButton("rectangle.on.rectangle", label: "Input") { press(.tvInput) }
                    KeyButton("gearshape", label: "Settings") { press(.settings) }
                    KeyButton("speaker.slash", label: "Mute") { press(.mute) }
                }

                DPad(
                    onDirection: { press($0) },
                    onSelect: { press(.dpadCenter) },
                    onLongSelect: { press(.dpadCenter, longPress: true) }
                )

                HStack(spacing: 14) {
                    KeyButton("arrow.uturn.backward", label: "Back") { press(.back) }
                    KeyButton("house", label: "Home") { press(.home) }
                    KeyButton("line.3.horizontal", label: "Menu") { press(.menu) }
                    KeyButton("square.stack", label: "Recents") { press(.appSwitch) }
                }

                HStack(spacing: 14) {
                    RepeatKeyButton("speaker.minus", label: "Vol −") { press(.volumeDown) }
                    RepeatKeyButton("speaker.plus", label: "Vol +") { press(.volumeUp) }
                    RepeatKeyButton("chevron.down.square", label: "Ch −") { press(.channelDown) }
                    RepeatKeyButton("chevron.up.square", label: "Ch +") { press(.channelUp) }
                }

                HStack(spacing: 14) {
                    KeyButton("backward.end", label: "Prev") { press(.mediaPrevious) }
                    KeyButton("backward", label: "Rewind") { press(.mediaRewind) }
                    KeyButton("playpause", label: "Play") { press(.mediaPlayPause) }
                    KeyButton("forward", label: "Forward") { press(.mediaFastForward) }
                    KeyButton("forward.end", label: "Next") { press(.mediaNext) }
                }

                keyboardSection
                functionKeys
                sendTextSection
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Sections

    /// Only shown when there's something to say: starting up, or a problem.
    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if let error = session.remoteError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(2)
            } else if !session.remoteReady {
                ProgressView().controlSize(.small)
                Text("Starting remote…")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private var keyboardSection: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    keyboardActive.toggle()
                } label: {
                    Label(keyboardActive ? "Hide Keyboard" : "Type on TV", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .background(
                    KeyCapture(isActive: $keyboardActive,
                               onText: { typed($0) },
                               onDelete: { press(.del) },
                               onSpecial: { press($0) })
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                )
            }
            HStack(spacing: 8) {
                ModifierToggle(title: "Ctrl", modifier: .ctrl, modifiers: $modifiers)
                ModifierToggle(title: "Alt", modifier: .alt, modifiers: $modifiers)
                ModifierToggle(title: "Shift", modifier: .shift, modifiers: $modifiers)
                SmallKey("Esc") { press(.escape) }
                SmallKey("Tab") { press(.tab) }
            }
            HStack(spacing: 8) {
                SmallKey("⌫ Del") { press(.del) }
                SmallKey("Del ⌦") { press(.forwardDel) }
                SmallKey("Enter") { press(.enter) }
                SmallKey("Search") { press(.search) }
            }
        }
    }

    private var functionKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Function keys").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(1...12, id: \.self) { n in
                    SmallKey("F\(n)") { pressCode(Keycode.function(n)) }
                }
            }
        }
    }

    private var sendTextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send text").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Text or link to type on the TV", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Send") {
                    let value = text
                    session.sendInput { try await $0.type(value) }
                    text = ""
                }
                .buttonStyle(.bordered)
                .disabled(text.isEmpty)
            }
        }
    }

    // MARK: Actions

    /// Modifiers are one-shot: applied to the next key, then released.
    private func takeModifiers() -> MetaState {
        let current = modifiers
        modifiers = []
        return current
    }

    private func press(_ key: Keycode, longPress: Bool = false) {
        pressCode(key.rawValue, longPress: longPress)
    }

    private func pressCode(_ code: Int32, longPress: Bool = false) {
        haptic.impactOccurred()
        let meta = takeModifiers()
        session.sendInput { try await $0.press(code, meta: meta, longPress: longPress) }
    }

    private func typed(_ string: String) {
        if !modifiers.isEmpty, string.count == 1, let code = Keycode.forCharacter(string.first!) {
            pressCode(code)
            return
        }
        if string == "\n" {
            press(.enter)
            return
        }
        session.sendInput { try await $0.type(string) }
    }
}

// MARK: Controls

private struct DPad: View {
    let onDirection: (Keycode) -> Void
    let onSelect: () -> Void
    let onLongSelect: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary)
                .frame(width: 250, height: 250)
            VStack(spacing: 0) {
                arrow("chevron.up", .dpadUp)
                HStack(spacing: 0) {
                    arrow("chevron.left", .dpadLeft)
                    Button(action: onSelect) {
                        Text("OK")
                            .font(.title2.weight(.semibold))
                            .frame(width: 96, height: 96)
                            .background(Circle().fill(.background))
                            .overlay(Circle().stroke(.quaternary))
                    }
                    .buttonStyle(PressScale())
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in onLongSelect() })
                    arrow("chevron.right", .dpadRight)
                }
                arrow("chevron.down", .dpadDown)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func arrow(_ symbol: String, _ key: Keycode) -> some View {
        RepeatPress(action: { onDirection(key) }) {
            Image(systemName: symbol)
                .font(.title.weight(.semibold))
                .frame(width: 76, height: 76)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("\(key)"))
    }
}

/// Fires once on touch down, then repeats while held (like a real remote).
private struct RepeatPress<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var pressed = false
    @State private var timer: Task<Void, Never>?

    var body: some View {
        label()
            .scaleEffect(pressed ? 0.88 : 1)
            .opacity(pressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        timer = Task {
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(nanoseconds: 120_000_000)
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        timer?.cancel()
                        timer = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

private struct KeyButton: View {
    let symbol: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void

    init(_ symbol: String, label: String, tint: Color = .primary, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            KeyFace(symbol: symbol, label: label, tint: tint)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

private struct RepeatKeyButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        RepeatPress(action: action) {
            KeyFace(symbol: symbol, label: label, tint: .primary)
        }
        .accessibilityLabel(label)
    }
}

private struct KeyFace: View {
    let symbol: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 56, height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
    }
}

private struct SmallKey: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary))
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.primary)
    }
}

private struct ModifierToggle: View {
    let title: String
    let modifier: MetaState
    @Binding var modifiers: MetaState

    var body: some View {
        let on = modifiers.contains(modifier)
        Button {
            if on { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
