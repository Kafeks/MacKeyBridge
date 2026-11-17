import Cocoa
import SwiftUI
import SystemConfiguration

// MARK: - Window model
//
// The SwiftUI window reads everything from `AppModel`. The model mirrors the engine (Link, Forwarder, ClipboardSync)
// and writes settings back to `prefs` + the engine. It only uses APIs available on macOS 12.

struct LogLine: Identifiable, Equatable {
    let id: Int
    let time: Date
    let text: String
}

final class AppModel: ObservableObject {
    // Connection
    @Published var host = prefs.host
    @Published var port = String(prefs.port)
    @Published var secret = prefs.secret
    @Published var inputError: String?
    @Published private(set) var link: LinkState = .idle
    @Published private(set) var linkWanted = false
    @Published private(set) var peerProtocol: UInt8 = 0
    @Published var autoConnect = prefs.autoConnect {
        didSet { prefs.autoConnect = autoConnect }
    }

    // Forwarding + hotkey
    @Published private(set) var forwarding = false
    @Published private(set) var ready = false
    @Published private(set) var hotkey = prefs.hotkey
    @Published var recordingHotkey = false

    // Trackpad
    @Published var forwardMouse = prefs.forwardMouse {
        didSet { prefs.forwardMouse = forwardMouse; applyOptions() }
    }
    @Published var pointerSpeed = prefs.pointerSpeed {
        didSet { prefs.pointerSpeed = pointerSpeed; applyOptions() }
    }
    @Published var scrollSpeed = prefs.scrollSpeed {
        didSet { prefs.scrollSpeed = scrollSpeed; applyOptions() }
    }
    @Published var invertV = prefs.invertV {
        didSet { prefs.invertV = invertV; applyOptions() }
    }
    @Published var invertH = prefs.invertH {
        didSet { prefs.invertH = invertH; applyOptions() }
    }
    @Published var swipeNav = prefs.swipeNav {
        didSet { prefs.swipeNav = swipeNav; applyOptions() }
    }
    @Published var swipeThreshold = prefs.swipeThreshold {
        didSet { prefs.swipeThreshold = swipeThreshold; applyOptions() }
    }
    @Published var swipeKeys = min(max(prefs.swipeKeys, 0), 2) {
        didSet { prefs.swipeKeys = swipeKeys; applyOptions() }
    }
    @Published var swipeReverse = prefs.swipeReverse {
        didSet { prefs.swipeReverse = swipeReverse; applyOptions() }
    }

    // Clipboard
    @Published var clipboardSync = prefs.clipboardSync {
        didSet { prefs.clipboardSync = clipboardSync; applyOptions(); gApp?.refreshUI() }
    }
    @Published var clipboardImages = prefs.clipboardImages {
        didSet { prefs.clipboardImages = clipboardImages; applyOptions() }
    }
    @Published private(set) var remoteClipboard: Bool?
    @Published private(set) var lastTransfer: ClipTransfer?

    // Permissions
    @Published private(set) var axGranted = false
    @Published private(set) var imGranted = false

    // Activity lights
    @Published private(set) var keyActive = false
    @Published private(set) var pointerActive = false
    @Published private(set) var clipActive = false

    // Log
    @Published private(set) var log: [LogLine] = []
    private var nextLogID = 0
    private var activityTimer: Timer?

    // MARK: engine <-> model

    func reloadConnectionFields() {
        host = prefs.host
        port = String(prefs.port)
        secret = prefs.secret
    }

    func applyOptions() {
        guard gFwd != nil, gClip != nil else { return }
        gFwd.mouse = MouseOptions(enabled: forwardMouse, pointerSpeed: pointerSpeed, scrollSpeed: scrollSpeed,
                                  invertV: invertV, invertH: invertH)
        gFwd.nav = NavOptions(enabled: swipeNav, threshold: swipeThreshold, output: swipeKeys, reverse: swipeReverse)
        gFwd.updateMouseCapture()
        gClip.enabled = clipboardSync
        gClip.includeImages = clipboardImages
    }

    private func update<T: Equatable>(_ kp: ReferenceWritableKeyPath<AppModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    /// Main thread: copy the engine state into the published properties (only what changed, to keep SwiftUI calm).
    func refresh() {
        update(\.link, gLink.currentState)
        update(\.linkWanted, gLink.isWanted)
        update(\.peerProtocol, gLink.peerProtocol)
        update(\.forwarding, gFwd.forwarding)
        update(\.ready, gFwd.ready)
        update(\.hotkey, gFwd.hotkey)
        update(\.remoteClipboard, gClip.peerSupportsClipboard ? gClip.remoteEnabled : nil)
        update(\.axGranted, AXIsProcessTrusted())
        update(\.imGranted, CGPreflightListenEventAccess())
        if link == .connected || link == .connecting { update(\.inputError, nil) }
    }

    func startActivityTimer() {
        guard activityTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tickActivity() }
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
    }

    private func tickActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        let fwd = gFwd.forwarding
        update(\.keyActive, fwd && now - gFwd.lastKeyActivity < 0.25)
        update(\.pointerActive, fwd && now - gFwd.lastPointerActivity < 0.25)
        update(\.clipActive, now - gClip.lastActivity < 1.2)
    }

    func appendLog(_ text: String) {
        nextLogID += 1
        log.append(LogLine(id: nextLogID, time: Date(), text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func clearLog() { log.removeAll() }

    func copyLog() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let text = log.map { f.string(from: $0.time) + "  " + $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardTransferred(_ t: ClipTransfer) {
        lastTransfer = t
    }

    // MARK: actions

    func toggleConnection() {
        if gLink.isWanted {
            gLink.disconnect()
            gFwd.stop(reason: "disconnect")
            refresh()
        } else {
            connect()
        }
    }

    func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        let s = secret.trimmingCharacters(in: .whitespaces)
        let p = port.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { inputError = "Enter the IP address of the Windows PC"; return }
        guard let portNumber = UInt16(p), portNumber > 0 else { inputError = "The port must be a number from 1 to 65535"; return }
        guard !s.isEmpty else { inputError = "Enter the secret from the Windows app"; return }
        inputError = nil
        host = h
        secret = s
        port = String(portNumber)
        prefs.host = h
        prefs.port = Int(portNumber)
        prefs.secret = s
        gLink.connect(host: h, port: portNumber, secret: Data(s.utf8))
        refresh()
    }

    func toggleForwarding() { gFwd.toggle() }
    func changeHotkey() { gApp.changeHotkey() }
    func resetHotkey() { gApp.resetHotkey() }
    func openAccessibility() { gApp.openPane("Privacy_Accessibility") }
    func openInputMonitoring() { gApp.openPane("Privacy_ListenEvent") }
    func openLocalNetwork() { gApp.openPane("Privacy_LocalNetwork") }

    // MARK: derived state for the views

    var connected: Bool { link == .connected }
    var canForward: Bool { forwarding || (connected && ready) }

    var statusText: String {
        switch link {
        case .idle: return inputError ?? "Not connected"
        case .connecting: return "Connecting to \(host)…"
        case .connected: return forwarding ? "Forwarding to Windows" : "Connected to \(host)"
        case .failed(let msg): return msg
        }
    }

    var statusColor: Color {
        if forwarding { return .accentColor }
        switch link {
        case .idle: return inputError == nil ? .secondary : .red
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    var forwardHint: String {
        let hk = hotkey.display
        if forwarding {
            return "The keyboard\(forwardMouse ? " and trackpad" : "") control Windows. Press \(hk) to take them back."
        }
        if !connected { return "Connect to the Windows PC to start forwarding." }
        if !ready { return "Grant Accessibility and Input Monitoring below - forwarding unlocks automatically." }
        return "Or press \(hk) from any app."
    }

    enum ClipStatus { case off, notConnected, outdated, waiting, remoteOff, ready }

    var clipStatus: ClipStatus {
        if !clipboardSync { return .off }
        if !connected { return .notConnected }
        if peerProtocol < 3 { return .outdated }
        guard let r = remoteClipboard else { return .waiting }
        return r ? .ready : .remoteOff
    }
}

// MARK: - Hosting

func makeMainContentView(model: AppModel) -> NSView {
    return NSHostingView(rootView: MainView(model: model))
}

// MARK: - Design tokens

enum Theme {
    /// Card fill: white on the light window background, a soft lift in dark mode.
    static let card = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.055) : NSColor.white
    })
    static let cardStroke = Color.primary.opacity(0.08)
    static let well = Color.primary.opacity(0.045)
    static let radius: CGFloat = 12
}

extension LinkState {
    var symbol: String {
        switch self {
        case .idle: return "minus"
        case .connecting: return "ellipsis"
        case .connected: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }
}

// MARK: - Root

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BridgeHeader(model: model)
                ConnectionCard(model: model)
                KeyboardCard(model: model)
                TrackpadCard(model: model)
                ClipboardCard(model: model)
                PermissionsCard(model: model)
                LogCard(model: model)
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Building blocks

struct Card<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let accessory: Accessory
    let content: Content

    init(_ title: String, symbol: String, tint: Color,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(symbol: symbol, tint: tint)
                Text(title).font(.headline)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.init(title, symbol: symbol, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.cardStroke))
            .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
}

/// The coloured rounded square in front of a section title, like in System Settings.
struct IconBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.softGradient())
            .frame(width: 24, height: 24)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(.white))
    }
}

extension Color {
    /// A subtle top-to-bottom gradient (Color.gradient needs macOS 13).
    func softGradient() -> LinearGradient {
        return LinearGradient(colors: [self.opacity(0.85), self], startPoint: .top, endPoint: .bottom)
    }
}

/// A label on the left, a control on the right, an optional explanation underneath the label.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let d = detail {
                    Text(d)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 3)
    }
}

struct SwitchRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title, detail: detail) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 118, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// Coloured capsule with a dot - used for small status texts.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// A dot that breathes while `pulsing` (connecting).
struct PulsingDot: View {
    let color: Color
    let pulsing: Bool
    var size: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !pulsing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let k = pulsing ? 0.45 + 0.55 * abs(sin(t * 3.0)) : 1.0
            ZStack {
                Circle().fill(color.opacity(0.25 * k)).frame(width: size * 2, height: size * 2)
                Circle().fill(color.opacity(k)).frame(width: size, height: size)
            }
        }
        .frame(width: size * 2, height: size * 2)
    }
}

/// Full-width filled button; looks the same on macOS 12-15 (the stock bordered style does not stretch on 12).
struct ProminentButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        ProminentButton(configuration: configuration, tint: tint)
    }

    private struct ProminentButton: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(isEnabled ? 1 : 0.85))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isEnabled ? tint : Color.gray.opacity(0.45))
                        .brightness(configuration.isPressed ? -0.08 : 0)
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Header: Mac ⇄ Windows

struct BridgeHeader: View {
    @ObservedObject var model: AppModel

    /// The Mac's name from System Settings -> Sharing (Host.current() can block on DNS, this does not).
    private static let macName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac"

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 0) {
                DeviceTile(symbol: "laptopcomputer", title: "This Mac", subtitle: BridgeHeader.macName, lit: true)
                LinkTrack(state: model.link, forwarding: model.forwarding, clipboard: model.clipActive)
                    .frame(height: 30)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 34)  // line up with the device icons, not with their captions
                DeviceTile(symbol: "desktopcomputer", title: "Windows PC",
                           subtitle: model.host.isEmpty ? "No address yet" : model.host, lit: model.connected)
            }

            HStack(spacing: 8) {
                PulsingDot(color: model.statusColor, pulsing: model.link == .connecting)
                Text(model.statusText)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(model.statusColor.opacity(0.12)))
            .animation(.easeInOut(duration: 0.25), value: model.statusText)

            HStack(spacing: 10) {
                ActivityLight(symbol: "keyboard", title: "Keyboard",
                              detail: keyboardDetail, active: model.keyActive, available: model.forwarding)
                ActivityLight(symbol: "cursorarrow.motionlines", title: "Trackpad",
                              detail: pointerDetail, active: model.pointerActive,
                              available: model.forwarding && model.forwardMouse)
                ActivityLight(symbol: "doc.on.clipboard", title: "Clipboard",
                              detail: clipDetail, active: model.clipActive, available: model.clipStatus == .ready)
            }

            VStack(spacing: 6) {
                Button(action: model.toggleForwarding) {
                    Label(model.forwarding ? "Stop Forwarding" : "Start Forwarding",
                          systemImage: model.forwarding ? "stop.fill" : "play.fill")
                }
                .buttonStyle(ProminentButtonStyle(tint: model.forwarding ? .red : .accentColor))
                .disabled(!model.canForward)
                .help("Same as the emergency hotkey \(model.hotkey.display)")

                Text(model.forwardHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                CardBackground()
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(LinearGradient(colors: [model.statusColor.opacity(0.10), Color.clear],
                                         startPoint: .top, endPoint: .bottom))
            }
        )
        .animation(.easeInOut(duration: 0.3), value: model.forwarding)
        .animation(.easeInOut(duration: 0.3), value: model.link)
    }

    private var keyboardDetail: String {
        if !model.forwarding { return "On this Mac" }
        return model.keyActive ? "Sending" : "→ Windows"
    }

    private var pointerDetail: String {
        if !model.forwardMouse { return "Stays on Mac" }
        if !model.forwarding { return "On this Mac" }
        return model.pointerActive ? "Sending" : "→ Windows"
    }

    private var clipDetail: String {
        switch model.clipStatus {
        case .off: return "Off"
        case .notConnected: return "Not connected"
        case .outdated: return "Needs update"
        case .waiting: return "Waiting…"
        case .remoteOff: return "Off on Windows"
        case .ready: return model.clipActive ? "Transferring" : "Synced"
        }
    }
}

struct DeviceTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let lit: Bool

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(lit ? Color.accentColor.opacity(0.14) : Theme.well)
                .frame(width: 68, height: 68)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(lit ? .accentColor : .secondary)
                )
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 130)
        .animation(.easeInOut(duration: 0.3), value: lit)
    }
}

struct LinkLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

/// The line between the two computers: grey dashes = idle, moving orange dots = connecting, solid green = connected,
/// a stream flowing towards Windows = forwarding.
struct LinkTrack: View {
    let state: LinkState
    let forwarding: Bool
    let clipboard: Bool

    private var color: Color {
        if forwarding { return .accentColor }
        switch state {
        case .idle: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var dash: [CGFloat] {
        if forwarding { return [7, 7] }
        return state == .connected ? [] : [2, 7]
    }

    private var speed: Double {
        if forwarding { return 42 }
        return state == .connecting ? 18 : 0
    }

    private var badgeSymbol: String {
        if forwarding { return "arrow.right" }
        if clipboard && state == .connected { return "doc.on.clipboard" }
        return state.symbol
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: speed == 0)) { ctx in
            let period = Double(dash.reduce(0, +))
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = period > 0 && speed > 0 ? -(t * speed).truncatingRemainder(dividingBy: period) : 0
            ZStack {
                LinkLine().stroke(color.opacity(0.16), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                LinkLine().stroke(color.opacity(state == .idle ? 0.5 : 1),
                                  style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: dash, dashPhase: CGFloat(phase)))
                Circle()
                    .fill(Theme.card)
                    .overlay(Circle().fill(color.opacity(0.14)))
                    .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: badgeSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(color))
            }
        }
        .frame(minWidth: 80, maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.3), value: badgeSymbol)
    }
}

struct ActivityLight: View {
    let symbol: String
    let title: String
    let detail: String
    let active: Bool
    let available: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(active ? Color.accentColor : Theme.well)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? .white : (available ? .accentColor : .secondary)))
                .shadow(color: active ? Color.accentColor.opacity(0.45) : .clear, radius: active ? 5 : 0)
                .scaleEffect(active ? 1.08 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
        .opacity(available || active ? 1 : 0.7)
        .animation(.easeOut(duration: 0.18), value: active)
        .animation(.easeInOut(duration: 0.25), value: available)
    }
}

// MARK: - Connection

struct ConnectionCard: View {
    @ObservedObject var model: AppModel
    @State private var showSecret = false

    var body: some View {
        Card("Connection", symbol: "network", tint: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                FieldRow(title: "Windows IP") {
                    TextField("192.168.1.20", text: $model.host)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connectIfIdle)
                }
                FieldRow(title: "Port") {
                    HStack {
                        TextField("47800", text: $model.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(connectIfIdle)
                        Spacer()
                    }
                }
                FieldRow(title: "Secret") {
                    HStack(spacing: 6) {
                        Group {
                            if showSecret {
                                TextField("Secret from the Windows app", text: $model.secret)
                            } else {
                                SecureField("Secret from the Windows app", text: $model.secret)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connectIfIdle)
                        Button(action: { showSecret.toggle() }) {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showSecret ? "Hide the secret" : "Show the secret")
                    }
                }
            }
            .disabled(model.linkWanted)

            Divider()

            HStack(spacing: 10) {
                PulsingDot(color: model.statusColor, pulsing: model.link == .connecting, size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.statusText)
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.connected {
                        Text(model.peerProtocol >= 3 ? "Protocol \(model.peerProtocol)"
                             : "Protocol \(model.peerProtocol) · update the Windows app for clipboard sync")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if model.linkWanted {
                    Button("Disconnect", action: model.toggleConnection)
                        .controlSize(.large)
                } else {
                    Button("Connect", action: model.toggleConnection)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.linkWanted)

            SwitchRow(title: "Connect automatically when MacKeyBridge opens", isOn: $model.autoConnect)

            Label("Port and secret are shown in MacKeyBridge on Windows → Settings → Connection. Use the PC's home network address (192.168.x.x / 10.x.x.x), not a VPN address.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectIfIdle() {
        if !model.linkWanted { model.connect() }
    }
}

struct FieldRow<Field: View>: View {
    let title: String
    let field: Field

    init(title: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 86, alignment: .leading)
            field
        }
    }
}

// MARK: - Keyboard

struct KeyboardCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card("Keyboard", symbol: "keyboard", tint: .indigo) {
            SettingRow("Emergency hotkey",
                       detail: "Starts and stops forwarding from any app. It always gives the Mac back.") {
                HStack(spacing: 8) {
                    if model.recordingHotkey {
                        Text("Press keys…  Esc cancels")
                            .font(.callout.weight(.medium))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .transition(.opacity)
                    } else {
                        KeyCaps(hotkey: model.hotkey).transition(.opacity)
                    }
                    Button(model.recordingHotkey ? "Cancel" : "Change…", action: model.changeHotkey)
                    Button("Reset", action: model.resetHotkey)
                        .disabled(model.recordingHotkey || model.hotkey == Hotkey())
                }
                .disabled(model.forwarding)
                .animation(.easeInOut(duration: 0.2), value: model.recordingHotkey)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HintLine(symbol: "globe", text: "Tap Fn to switch the Windows keyboard layout.")
                HintLine(symbol: "command", text: "Left ⌘ works as Ctrl, right ⌘ as the Windows key - change the key map in the Windows app.")
                HintLine(symbol: "speaker.wave.2", text: "Volume and media keys are forwarded too; brightness stays on the Mac.")
            }
        }
    }
}

struct HintLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct KeyCaps: View {
    let hotkey: Hotkey

    private var caps: [String] {
        var c: [String] = []
        if hotkey.flags & ctrlFlag != 0 { c.append("⌃") }
        if hotkey.flags & optFlag != 0 { c.append("⌥") }
        if hotkey.flags & shiftFlag != 0 { c.append("⇧") }
        if hotkey.flags & cmdFlag != 0 { c.append("⌘") }
        c.append(hotkey.name)
        return c
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, cap.count > 1 ? 5 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.card)
                            .shadow(color: Color.black.opacity(0.18), radius: 0, x: 0, y: 1)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.cardStroke))
            }
        }
    }
}

// MARK: - Trackpad

struct TrackpadCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card("Trackpad", symbol: "hand.point.up.left", tint: .purple, accessory: {
            Toggle("", isOn: $model.forwardMouse).toggleStyle(.switch).labelsHidden()
                .help("Forward the trackpad / mouse too")
        }) {
            Text(model.forwardMouse
                 ? "While forwarding, pointer, clicks, drag and scrolling go to Windows and the Mac cursor stays frozen."
                 : "Only the keyboard is forwarded - the trackpad keeps controlling this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                SliderRow(title: "Pointer speed", value: $model.pointerSpeed, range: 0.3...3.0) { String(format: "%.1f×", $0) }
                SliderRow(title: "Scroll speed", value: $model.scrollSpeed, range: 0.3...3.0) { String(format: "%.1f×", $0) }
                SwitchRow(title: "Invert vertical scrolling", isOn: $model.invertV)
                SwitchRow(title: "Invert horizontal scrolling", isOn: $model.invertH)

                Divider().padding(.vertical, 4)

                SwitchRow(title: "Swipe to change slides and pages",
                          detail: "Two fingers left → right = previous, right → left = next. Vertical scrolling is not affected.",
                          isOn: $model.swipeNav)
                VStack(alignment: .leading, spacing: 6) {
                    SliderRow(title: "Swipe distance", value: $model.swipeThreshold, range: 30...300) { String(format: "%.0f", $0) }
                    SettingRow("Swipe sends") {
                        Picker("", selection: $model.swipeKeys) {
                            Text("← / → arrow keys").tag(0)
                            Text("Page Up / Page Down").tag(1)
                            Text("Mouse Back / Forward").tag(2)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 210)
                    }
                    SwitchRow(title: "Reverse swipe direction", isOn: $model.swipeReverse)
                }
                .disabled(!model.swipeNav)
                .opacity(model.swipeNav ? 1 : 0.5)
            }
            .disabled(!model.forwardMouse)
            .opacity(model.forwardMouse ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.2), value: model.forwardMouse)
            .animation(.easeInOut(duration: 0.2), value: model.swipeNav)
        }
    }
}

// MARK: - Clipboard

struct ClipboardCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card("Clipboard", symbol: "doc.on.clipboard", tint: .orange, accessory: {
            Toggle("", isOn: $model.clipboardSync).toggleStyle(.switch).labelsHidden()
                .help("Sync the clipboard with Windows")
        }) {
            Text("Copy on one computer, paste on the other - in both directions.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                SwitchRow(title: "Include images", detail: "Screenshots and copied pictures (PNG, up to \(byteCountText(clipMaxBytes))).",
                          isOn: $model.clipboardImages)
                    .disabled(!model.clipboardSync)
                SettingRow("Windows") {
                    StatusBadge(text: statusText, color: statusColor)
                        .animation(.easeInOut(duration: 0.2), value: statusText)
                }
                LastTransferRow(transfer: model.lastTransfer, active: model.clipActive)
            }

            Label("Content that password managers mark as private is never sent. Like keystrokes, the clipboard is not encrypted on the network - use a trusted network.",
                  systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch model.clipStatus {
        case .off: return "Sync is off"
        case .notConnected: return "Not connected"
        case .outdated: return "Update MacKeyBridge.exe"
        case .waiting: return "Waiting…"
        case .remoteOff: return "Off in the Windows settings"
        case .ready: return "Ready"
        }
    }

    private var statusColor: Color {
        switch model.clipStatus {
        case .off, .notConnected, .waiting: return .secondary
        case .outdated, .remoteOff: return .orange
        case .ready: return .green
        }
    }
}

struct LastTransferRow: View {
    let transfer: ClipTransfer?
    let active: Bool

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            if let t = transfer {
                Image(systemName: t.direction == .toWindows ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(active ? .accentColor : .secondary)
                    .scaleEffect(active ? 1.12 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.summary).font(.callout)
                    Text((t.direction == .toWindows ? "Sent to Windows" : "Received from Windows") + " at "
                         + LastTransferRow.timeFormat.string(from: t.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
                .id(t.date)
            } else {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Nothing transferred yet").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
        .animation(.easeInOut(duration: 0.25), value: transfer)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)
    }
}

// MARK: - Permissions

struct PermissionsCard: View {
    @ObservedObject var model: AppModel

    private var allGranted: Bool { model.axGranted && model.imGranted }

    var body: some View {
        Card("Permissions", symbol: "lock.shield", tint: allGranted ? .green : .red, accessory: {
            StatusBadge(text: allGranted ? "All granted" : "Action needed", color: allGranted ? .green : .red)
        }) {
            VStack(spacing: 0) {
                PermissionRow(name: "Accessibility", detail: "Capture keys, clicks and scrolling and keep them off the Mac",
                              granted: model.axGranted, action: model.openAccessibility)
                Divider().padding(.leading, 34)
                PermissionRow(name: "Input Monitoring", detail: "Receive keystrokes, including the emergency hotkey",
                              granted: model.imGranted, action: model.openInputMonitoring)
                Divider().padding(.leading, 34)
                PermissionRow(name: "Local Network", detail: "Reach the PC on your network (macOS asks on first connect)",
                              granted: nil, action: model.openLocalNetwork)
            }
            if !allGranted {
                Text("Turn MacKeyBridge on in System Settings → Privacy & Security. The status here updates by itself; after a rebuild, remove and re-add the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: allGranted)
    }
}

struct PermissionRow: View {
    let name: String
    let detail: String
    let granted: Bool?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted == nil ? "info.circle.fill" : (granted! ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 18))
                .foregroundColor(granted == nil ? .secondary : (granted! ? .green : .red))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted == false {
                Button("Open Settings…", action: action).buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("Open Settings…", action: action).controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Log

struct LogCard: View {
    @ObservedObject var model: AppModel
    @AppStorage("logExpanded") private var expanded = false

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Card("Activity Log", symbol: "text.alignleft", tint: .gray, accessory: {
            HStack(spacing: 4) {
                if expanded {
                    Button(action: model.copyLog) { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy the log")
                    Button(action: model.clearLog) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Clear the log")
                }
                Button(action: { withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() } }) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Hide the log" : "Show the log")
            }
        }) {
            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(model.log) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(LogCard.timeFormat.string(from: line.time)).foregroundStyle(.tertiary)
                                    Text(line.text).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                    }
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
                    .onAppear { if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
<<<<<<< HEAD
                    .onChange(of: model.log.last?.id) { _, newID in
                        if let id = newID {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
=======
                    .onChange(of: model.log.last?.id) { id in
                        if let id = id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
>>>>>>> feature/gui
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let last = model.log.last {
                Text(last.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
