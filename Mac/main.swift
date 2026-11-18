import Carbon  // RegisterEventHotKey: permission-free global hotkey (emergency fallback)
import Cocoa
import CoreGraphics
import CryptoKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Logging (stdout + log box in the window)

var gLogSink: ((String) -> Void)?

func say(_ s: String) {
    print("[mackeybridge] \(s)")
    DispatchQueue.main.async { gLogSink?(s) }
}

// MARK: - Protocol constants (version 3; version 2 = without clipboard, still spoken with an older Windows app)

let protoVersion: UInt8 = 3
let protoVersionLegacy: UInt8 = 2
let pktChallenge: UInt8 = 0x01
let pktAuth: UInt8 = 0x02
let pktAuthOk: UInt8 = 0x03
let pktAuthFail: UInt8 = 0x04
let pktKeyDown: UInt8 = 0x10
let pktKeyUp: UInt8 = 0x11
let pktAllUp: UInt8 = 0x12
let pktPing: UInt8 = 0x13
let pktMouseMove: UInt8 = 0x20
let pktMouseButton: UInt8 = 0x21
let pktMouseWheel: UInt8 = 0x22
// Protocol 3, both directions:
//   0x30 CLIPBOARD  [type][kind][len u32 LE][payload]   kind 1 = UTF-8 text (LF line ends), 2 = PNG image
//   0x31 CLIP_STATE [type][flags]                       bit 0 = clipboard sync on, bit 1 = images accepted
let pktClipboard: UInt8 = 0x30
let pktClipState: UInt8 = 0x31
let clipKindText: UInt8 = 1
let clipKindPNG: UInt8 = 2
let clipFlagOn: UInt8 = 0x01
let clipFlagImages: UInt8 = 0x02
let clipMaxBytes = 20 * 1024 * 1024

/// What the Windows side can send us after the handshake.
enum PeerMessage: Equatable {
    case clipboard(kind: UInt8, data: Data)
    case clipboardState(enabled: Bool, images: Bool)
}

func clipboardPacket(kind: UInt8, payload: Data) -> [UInt8] {
    let n = UInt32(payload.count)
    var b: [UInt8] = [pktClipboard, kind, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
    b.append(contentsOf: payload)
    return b
}

/// Splits the byte stream coming from Windows into messages (pure logic - covered by --selftest).
struct PeerFrameParser {
    enum Failure: Error, Equatable {
        case unknownType(UInt8)
        case tooLarge(Int)
    }

    let maxPayload: Int
    private var buf: [UInt8] = []
    private var pos = 0

    init(maxPayload: Int = clipMaxBytes) { self.maxPayload = maxPayload }

    mutating func feed(_ bytes: [UInt8]) throws -> [PeerMessage] {
        buf.append(contentsOf: bytes)
        var out: [PeerMessage] = []
        while pos < buf.count {
            let avail = buf.count - pos
            let type = buf[pos]
            if type == pktClipState {
                guard avail >= 2 else { break }
                let f = buf[pos + 1]
                out.append(.clipboardState(enabled: f & clipFlagOn != 0, images: f & clipFlagImages != 0))
                pos += 2
            } else if type == pktClipboard {
                guard avail >= 6 else { break }
                let len = Int(buf[pos + 2]) | Int(buf[pos + 3]) << 8 | Int(buf[pos + 4]) << 16 | Int(buf[pos + 5]) << 24
                if len > maxPayload { throw Failure.tooLarge(len) }
                guard avail >= 6 + len else {
                    buf.reserveCapacity(pos + 6 + len)
                    break
                }
                out.append(.clipboard(kind: buf[pos + 1], data: Data(buf[(pos + 6)..<(pos + 6 + len)])))
                pos += 6 + len
            } else if type == pktPing {
                guard avail >= 4 else { break }
                pos += 4
            } else {
                throw Failure.unknownType(type)
            }
        }
        if pos > 0 && (pos == buf.count || pos >= 65536) {  // drop what has been consumed
            buf.removeFirst(pos)
            pos = 0
        }
        return out
    }
}

// MARK: - Saved preferences

final class Prefs {
    private let d = UserDefaults.standard

    var host: String {
        get { d.string(forKey: "host") ?? "" }
        set { d.set(newValue, forKey: "host") }
    }
    var port: Int {
        get { let v = d.integer(forKey: "port"); return v == 0 ? 47800 : v }
        set { d.set(newValue, forKey: "port") }
    }
    var secret: String {
        get { d.string(forKey: "secret") ?? "" }
        set { d.set(newValue, forKey: "secret") }
    }
    var forwardMouse: Bool {
        get { (d.object(forKey: "forwardMouse") as? Bool) ?? true }
        set { d.set(newValue, forKey: "forwardMouse") }
    }
    var pointerSpeed: Double {
        get { let v = d.double(forKey: "pointerSpeed"); return v == 0 ? 1.0 : v }
        set { d.set(newValue, forKey: "pointerSpeed") }
    }
    var scrollSpeed: Double {
        get { let v = d.double(forKey: "scrollSpeed"); return v == 0 ? 1.0 : v }
        set { d.set(newValue, forKey: "scrollSpeed") }
    }
    var invertV: Bool {
        get { d.bool(forKey: "invertV") }
        set { d.set(newValue, forKey: "invertV") }
    }
    var invertH: Bool {
        get { d.bool(forKey: "invertH") }
        set { d.set(newValue, forKey: "invertH") }
    }
    var autoConnect: Bool {
        get { d.bool(forKey: "autoConnect") }
        set { d.set(newValue, forKey: "autoConnect") }
    }
    var swipeNav: Bool {
        get { (d.object(forKey: "swipeNav") as? Bool) ?? true }
        set { d.set(newValue, forKey: "swipeNav") }
    }
    var swipeThreshold: Double {
        get { let v = d.double(forKey: "swipeThreshold"); return v == 0 ? 80.0 : v }
        set { d.set(newValue, forKey: "swipeThreshold") }
    }
    var swipeKeys: Int {  // 0 = Left / Right arrow, 1 = Page Up / Page Down, 2 = mouse side buttons (Back / Forward)
        get { d.integer(forKey: "swipeKeys") }
        set { d.set(newValue, forKey: "swipeKeys") }
    }
    var swipeReverse: Bool {
        get { d.bool(forKey: "swipeReverse") }
        set { d.set(newValue, forKey: "swipeReverse") }
    }
    var clipboardSync: Bool {
        get { (d.object(forKey: "clipboardSync") as? Bool) ?? true }
        set { d.set(newValue, forKey: "clipboardSync") }
    }
    var clipboardImages: Bool {
        get { (d.object(forKey: "clipboardImages") as? Bool) ?? true }
        set { d.set(newValue, forKey: "clipboardImages") }
    }
    var shortcutMapping: Bool {
        get { (d.object(forKey: "shortcutMapping") as? Bool) ?? true }
        set { d.set(newValue, forKey: "shortcutMapping") }
    }
    var cmdToCtrl: Bool {
        get { (d.object(forKey: "cmdToCtrl") as? Bool) ?? true }
        set { d.set(newValue, forKey: "cmdToCtrl") }
    }
    var cmdShiftZToCtrlY: Bool {
        get { (d.object(forKey: "cmdShiftZToCtrlY") as? Bool) ?? true }
        set { d.set(newValue, forKey: "cmdShiftZToCtrlY") }
    }
    var cmdTabToAltTab: Bool {
        get { (d.object(forKey: "cmdTabToAltTab") as? Bool) ?? true }
        set { d.set(newValue, forKey: "cmdTabToAltTab") }
    }
    var themePreset: Int {
        get { d.object(forKey: "themePreset") as? Int ?? ThemePreset.midnight.rawValue }
        set { d.set(newValue, forKey: "themePreset") }
    }
    var appearanceMode: Int {
        get { d.object(forKey: "appearanceMode") as? Int ?? AppearanceMode.system.rawValue }
        set { d.set(newValue, forKey: "appearanceMode") }
    }
    var liquidGlassEnabled: Bool {
        get { (d.object(forKey: "liquidGlassEnabled") as? Bool) ?? true }
        set { d.set(newValue, forKey: "liquidGlassEnabled") }
    }
    var useCustomAccent: Bool {
        get { (d.object(forKey: "useCustomAccent") as? Bool) ?? false }
        set { d.set(newValue, forKey: "useCustomAccent") }
    }
    var customAccent: String {
        get { d.string(forKey: "customAccent") ?? "#5E9BFF" }
        set { d.set(newValue, forKey: "customAccent") }
    }
    var selectedTab: Int {
        get { d.object(forKey: "selectedTab") as? Int ?? 0 }
        set { d.set(newValue, forKey: "selectedTab") }
    }
    /// Emergency hotkey. Falls back to Control+Option+Command+W if the stored value is missing or unsafe.
    var hotkey: Hotkey {
        get {
            var h = Hotkey()
            if let c = d.object(forKey: "hotkeyCode") as? Int { h.code = UInt16(truncatingIfNeeded: c) }
            if let f = d.object(forKey: "hotkeyFlags") as? Int { h.flags = UInt64(truncatingIfNeeded: f) }
            if let n = d.string(forKey: "hotkeyName"), !n.isEmpty { h.name = n }
            return h.isValid ? h : Hotkey()
        }
        set {
            d.set(Int(newValue.code), forKey: "hotkeyCode")
            d.set(Int(truncatingIfNeeded: newValue.flags), forKey: "hotkeyFlags")
            d.set(newValue.name, forKey: "hotkeyName")
        }
    }
}

let prefs = Prefs()

// MARK: - Command line (optional)

struct CLIOptions {
    var host: String?
    var port: Int?
    var secret: String?
}

let usageText = """
Usage: MacKeyBridge [--host <windows-ip>] [--port 47800] [--secret <secret>]

  --host     IP address or host name of the Windows PC (shown in the MacKeyBridge settings there)
  --port     TCP port (default 47800)
  --secret   shared secret from the MacKeyBridge settings (or env MACKEYBRIDGE_SECRET)

Without arguments the window opens and uses the saved settings.
Start/stop forwarding with the emergency hotkey (default Control+Option+Command+W, changeable in the window).

  --selftest   run the built-in logic tests (swipe recognizer, hotkey, stuck-key bookkeeping) and exit
  --diagnose   print the permission state and count the events an event tap really receives (8 s), then exit
"""

func parseArgs() -> CLIOptions {
    var o = CLIOptions()
    let env = ProcessInfo.processInfo.environment
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--host": o.host = it.next()
        case "--port":
            if let v = it.next(), let p = Int(v) { o.port = p }
        case "--secret": o.secret = it.next()
        case "--help", "-h":
            print(usageText)
            exit(0)
        default: break  // ignore anything else (macOS may pass extra arguments to apps)
        }
    }
    if o.host == nil { o.host = env["MACKEYBRIDGE_HOST"] }
    if o.secret == nil { o.secret = env["MACKEYBRIDGE_SECRET"] }
    return o
}

// MARK: - TCP link (connect / disconnect on demand, HMAC challenge-response, 1 s keep-alive)

enum LinkState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
}

enum HandshakeResult {
    case ok, notServer, badSecret, versionMismatch, failed

    var message: String {
        switch self {
        case .ok: return ""
        case .notServer: return "Not a MacKeyBridge server (wrong port?)"
        case .badSecret: return "Wrong secret - copy it from the MacKeyBridge settings on Windows"
        case .versionMismatch: return "Version mismatch - update MacKeyBridge.exe on Windows"
        case .failed: return "Handshake failed"
        }
    }
}

final class Link {
    private let lock = NSLock()
    private var host = ""
    private var port: UInt16 = 47800
    private var secret = Data()
    private var wanted = false
    private var generation = 0
    private var fd: Int32 = -1
    private var state: LinkState = .idle
    private var version = protoVersion   // what we offer; falls back to 2 for an older Windows app
    private var peerVersion: UInt8 = 0   // protocol of the current connection, 0 = not connected
    private let sendQ = DispatchQueue(label: "mackeybridge.send")
    var onState: ((LinkState) -> Void)?
    /// Messages from Windows (clipboard). Called on the link thread.
    var onMessage: ((PeerMessage) -> Void)?

    init() {
        let t = Thread { [self] in self.loop() }
        t.name = "mackeybridge.link"
        t.start()
    }

    var currentState: LinkState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    var connected: Bool { currentState == .connected }

    var isWanted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wanted
    }

    /// Protocol version of the live connection (3 = with clipboard), 0 when not connected.
    var peerProtocol: UInt8 {
        lock.lock()
        defer { lock.unlock() }
        return peerVersion
    }

    func connect(host: String, port: UInt16, secret: Data) {
        lock.lock()
        self.host = host
        self.port = port
        self.secret = secret
        version = protoVersion  // a new attempt offers the newest protocol again
        wanted = true
        generation += 1
        let s = fd
        lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR) }  // drop the old connection, the loop reconnects with new settings
    }

    func disconnect() {
        lock.lock()
        wanted = false
        generation += 1
        let s = fd
        lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR) }
    }

    /// Queue raw bytes (one event). Order is preserved by the serial queue; never blocks the event tap.
    func enqueue(_ bytes: [UInt8]) {
        sendQ.async { [self] in
            lock.lock()
            let s = fd
            let up = (state == .connected)
            lock.unlock()
            guard up, s >= 0 else { return }
            if !writeAll(s, bytes) { shutdown(s, SHUT_RDWR) }  // wakes the loop, which reconnects
        }
    }

    // MARK: connection loop

    private func setState(_ s: LinkState) {
        lock.lock()
        if state == s {
            lock.unlock()
            return
        }
        state = s
        lock.unlock()
        onState?(s)
    }

    private func waitRetry(_ gen: Int, _ seconds: Double) {
        var waited = 0.0
        while waited < seconds {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
            lock.lock()
            let g = generation
            lock.unlock()
            if g != gen { return }
        }
    }

    private func loop() {
        var lastFailure = ""
        while true {
            lock.lock()
            let w = wanted
            let gen = generation
            let h = host
            let p = port
            let sec = secret
            let ver = version
            lock.unlock()

            if !w {
                setState(.idle)
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            setState(.connecting)
            let opened = openSocket(host: h, port: p)
            if opened.fd < 0 {
                if opened.reason != lastFailure {
                    say(opened.reason)
                    lastFailure = opened.reason
                }
                setState(.failed(opened.reason))
                waitRetry(gen, 2.0)
                continue
            }
            let s = opened.fd

            let hs = handshake(s, secret: sec, version: ver)
            if hs != .ok {
                close(s)
                if hs == .versionMismatch && ver > protoVersionLegacy {
                    // An older MacKeyBridge.exe: speak protocol 2 with it (keyboard + trackpad, no clipboard).
                    lock.lock()
                    if generation == gen { version = protoVersionLegacy }
                    lock.unlock()
                    say("The Windows app is an older version: keyboard and trackpad work, clipboard sync needs the new MacKeyBridge.exe")
                    continue
                }
                if hs.message != lastFailure {
                    say(hs.message)
                    lastFailure = hs.message
                }
                setState(.failed(hs.message))
                waitRetry(gen, 3.0)
                continue
            }

            lock.lock()
            if generation != gen {  // user changed settings while we were connecting
                lock.unlock()
                close(s)
                continue
            }
            fd = s
            peerVersion = ver
            lock.unlock()
            lastFailure = ""
            setState(.connected)
            say("Connected to Windows at \(h):\(p)" + (ver >= 3 ? "" : " (protocol \(ver), no clipboard sync)"))

            var parser = PeerFrameParser()
            var buf = [UInt8](repeating: 0, count: 65536)
            var lastPing = 0.0
            var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            while true {
                lock.lock()
                let g = generation
                lock.unlock()
                if g != gen { break }

                let r = poll(&pfd, 1, 250)
                if r < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // Keep-alive once per second, also while data is coming in (the server drops us after 3 s of silence).
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPing >= 1.0 {
                    lastPing = now
                    enqueue([pktPing, 0, 0, 0])
                }
                if r == 0 { continue }
                let n = recv(s, &buf, buf.count, 0)
                if n <= 0 { break }  // closed or error
                do {
                    for m in try parser.feed(Array(buf[0..<n])) { onMessage?(m) }
                } catch {
                    say("Unexpected data from Windows (\(error)) - reconnecting")
                    break
                }
            }

            lock.lock()
            fd = -1
            peerVersion = 0
            lock.unlock()
            close(s)

            lock.lock()
            let stillWanted = wanted
            lock.unlock()
            if stillWanted {
                say("Connection to Windows lost - retrying")
                setState(.failed("Connection lost - retrying"))
                waitRetry(gen, 1.0)
            }
        }
    }

    private func reasonText(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "Connection refused - is MacKeyBridge running on the PC?"
        case ETIMEDOUT: return "Timed out - Windows firewall or Wi-Fi isolation? (see README)"
        case EHOSTUNREACH: return "No route to host - allow Local Network for this app in macOS, or wrong subnet"
        case ENETUNREACH: return "Network unreachable"
        default: return "Cannot connect: " + String(cString: strerror(code))
        }
    }

    private func openSocket(host: String, port: UInt16) -> (fd: Int32, reason: String) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            return (-1, "Cannot resolve '\(host)'")
        }
        defer { freeaddrinfo(first) }

        var reason = "Cannot connect"
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                let flags = fcntl(s, F_GETFL, 0)
                _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
                var ok = false
                if Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {  // Darwin.: Link has its own connect()
                    ok = true
                } else if errno == EINPROGRESS {
                    var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 3000) > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 { ok = true } else { reason = reasonText(err) }
                    } else {
                        reason = reasonText(ETIMEDOUT)
                    }
                } else {
                    reason = reasonText(errno)
                }
                if ok {
                    _ = fcntl(s, F_SETFL, flags)  // back to blocking
                    var one: Int32 = 1
                    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    return (s, "")
                }
                close(s)
            }
            p = ai.pointee.ai_next
        }
        return (-1, reason)
    }

    private func writeAll(_ s: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(s, $0.baseAddress! + off, bytes.count - off, 0) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private func readExact(_ s: Int32, _ n: Int, timeoutMs: Int32) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, timeoutMs) <= 0 { return nil }
            let m = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress! + got, n - got, 0) }
            if m <= 0 { return nil }
            got += m
        }
        return buf
    }

    /// server: [0x01][nonce 16]   client: [0x02][version][HMAC-SHA256(secret, nonce)]   server: [0x03] or [0x04][reason]
    private func handshake(_ s: Int32, secret: Data, version: UInt8) -> HandshakeResult {
        guard let ch = readExact(s, 17, timeoutMs: 3000), ch[0] == pktChallenge else { return .notServer }
        let nonce = Data(ch[1...16])
        let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: secret))
        var msg: [UInt8] = [pktAuth, version]
        msg.append(contentsOf: Array(mac))
        guard writeAll(s, msg) else { return .failed }
        guard let r = readExact(s, 1, timeoutMs: 3000) else { return .failed }
        if r[0] == pktAuthOk { return .ok }
        if r[0] == pktAuthFail {
            let reason = readExact(s, 1, timeoutMs: 1000)?.first ?? 1
            return reason == 2 ? .versionMismatch : .badSecret
        }
        return .failed
    }
}

// MARK: - Emergency hotkey

let ctrlFlag = CGEventFlags.maskControl.rawValue
let optFlag = CGEventFlags.maskAlternate.rawValue
let cmdFlag = CGEventFlags.maskCommand.rawValue
let shiftFlag = CGEventFlags.maskShift.rawValue
let hotkeyModMask: UInt64 = ctrlFlag | optFlag | cmdFlag | shiftFlag

/// Names for keys whose character is not printable (used when the user records a new hotkey).
let specialKeyNames: [UInt16: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
    101: "F9", 109: "F10", 103: "F11", 111: "F12",
    49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
    123: "←", 124: "→", 125: "↓", 126: "↑", 116: "PgUp", 121: "PgDn", 115: "Home", 119: "End",
]

/// The hotkey that stops (or starts) forwarding. Needs at least two of Control / Option / Command so that
/// it cannot swallow an everyday shortcut by accident. Default: Control+Option+Command+W.
struct Hotkey: Equatable {
    var code: UInt16 = 13  // kVK_ANSI_W
    var flags: UInt64 = ctrlFlag | optFlag | cmdFlag
    var name = "W"

    /// Every required modifier must be down; extra ones (e.g. Shift) are tolerated, because in an emergency
    /// the keys are not pressed carefully.
    func matches(code c: UInt16, flags f: UInt64) -> Bool {
        return c == code && (f & flags) == flags
    }

    var isValid: Bool {
        var n = 0
        if flags & ctrlFlag != 0 { n += 1 }
        if flags & optFlag != 0 { n += 1 }
        if flags & cmdFlag != 0 { n += 1 }
        return n >= 2
    }

    var display: String {
        var s = ""
        if flags & ctrlFlag != 0 { s += "⌃" }
        if flags & optFlag != 0 { s += "⌥" }
        if flags & shiftFlag != 0 { s += "⇧" }
        if flags & cmdFlag != 0 { s += "⌘" }
        return s + name
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags & cmdFlag != 0 { m |= UInt32(cmdKey) }
        if flags & optFlag != 0 { m |= UInt32(optionKey) }
        if flags & ctrlFlag != 0 { m |= UInt32(controlKey) }
        if flags & shiftFlag != 0 { m |= UInt32(shiftKey) }
        return m
    }
}

// MARK: - Which of our events are still "open" (stuck-key protection)

let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]  // Cmd, Shift, Option, Control (both sides), Fn

/// Remembers which key / button presses were forwarded to the PC. Only those releases are forwarded and
/// swallowed; the release of something that was pressed before forwarding started goes to the Mac, so
/// neither computer is left with a key or button stuck down.
struct HeldState {
    private(set) var keys = Set<UInt16>()
    private(set) var buttons = Set<UInt8>()

    mutating func keyDown(_ code: UInt16) { keys.insert(code) }
    /// true = this release belongs to a forwarded press.
    mutating func keyUp(_ code: UInt16) -> Bool { return keys.remove(code) != nil }
    mutating func buttonDown(_ b: UInt8) { buttons.insert(b) }
    mutating func buttonUp(_ b: UInt8) -> Bool { return buttons.remove(b) != nil }
    mutating func reset() {
        keys.removeAll()
        buttons.removeAll()
    }
    var modifiersHeld: Bool { return !keys.isDisjoint(with: modifierKeyCodes) }
    var isEmpty: Bool { return keys.isEmpty && buttons.isEmpty }
}

// MARK: - Two-finger swipe recognizer (pure logic, no AppKit - covered by --selftest)

enum ScrollPhaseKind { case none, mayBegin, began, changed, ended, cancelled }

enum ScrollResult: Equatable {
    case none
    case scroll(x: Double, y: Double)  // forward these deltas as an ordinary scroll
    case swipe(forward: Bool)          // one navigation step: true = next, false = previous
}

struct NavOptions {
    var enabled = true
    var threshold = 80.0   // finger travel (scroll points) that triggers a swipe
    var output = 0         // what a swipe sends: 0 = Left / Right arrow, 1 = Page Up / Page Down, 2 = mouse side buttons (Back / Forward)
    var reverse = false    // swap previous / next
}

/// Splits a trackpad scroll gesture into "navigation swipe" (horizontal) or "ordinary scroll" (vertical).
///
///  * The axis is decided once per gesture, after `lockDistance` points of travel. Until then the deltas are held back
///    (about one or two events), so a vertical scroll starts a hair late but never leaks sideways.
///  * A horizontal gesture fires exactly one swipe when the travel reaches `threshold`; the rest of that gesture and
///    its inertia (momentum) events are ignored. A new gesture (phase "began") re-arms it.
///  * Fingers moving left -> right = previous, right -> left = next.
final class SwipeRecognizer {
    private enum Axis { case undecided, horizontal, vertical }

    let lockDistance = 10.0   // points of travel before the axis is decided
    let dominance = 2.0       // |horizontal| must be at least this many times |vertical|
    let cooldown = 0.25       // seconds between two swipes
    let staleAfter = 0.6      // silence after which events are treated as a new gesture

    private var axis = Axis.undecided
    private var inGesture = false
    private var sumX = 0.0, sumY = 0.0   // finger travel (X: + = right)
    private var bufX = 0.0, bufY = 0.0   // raw deltas held back while the axis is undecided
    private var fired = false
    private var lastEvent = 0.0
    private var lastFire = -100.0

    func reset() {
        axis = .undecided
        inGesture = false
        sumX = 0; sumY = 0; bufX = 0; bufY = 0
        fired = false
    }

    /// rawX / rawY: scroll deltas exactly as macOS reports them (forwarded unchanged by the caller).
    /// fingerX: horizontal finger movement (+ = fingers moved right), independent of "natural scrolling".
    func feed(rawX: Double, rawY: Double, fingerX: Double, phase: ScrollPhaseKind, momentum: Bool,
              threshold: Double, now: Double) -> ScrollResult {
        if phase == .mayBegin { return .none }

        if momentum {  // inertia of the gesture that just ended
            if axis == .horizontal { return .none }
            return rawY != 0 ? .scroll(x: 0, y: rawY) : .none
        }

        if phase == .began || !inGesture || now - lastEvent > staleAfter {
            axis = .undecided
            sumX = 0; sumY = 0; bufX = 0; bufY = 0
            fired = false
            inGesture = true
        }
        lastEvent = now
        sumX += fingerX
        sumY += rawY

        var result = ScrollResult.none
        switch axis {
        case .undecided:
            bufX += rawX
            bufY += rawY
            if abs(sumX) + abs(sumY) >= lockDistance {
                if abs(sumX) >= dominance * abs(sumY) {
                    axis = .horizontal
                } else {
                    axis = .vertical
                    if bufY != 0 { result = .scroll(x: 0, y: bufY) }
                }
                bufX = 0; bufY = 0
            }
        case .vertical:
            if rawY != 0 { result = .scroll(x: 0, y: rawY) }
        case .horizontal:
            break
        }

        if axis == .horizontal && !fired && abs(sumX) >= threshold && abs(sumX) >= dominance * abs(sumY) {
            fired = true  // one swipe per gesture, even if it is dropped by the cooldown
            if now - lastFire >= cooldown {
                lastFire = now
                result = .swipe(forward: sumX < 0)
            }
        }

        if phase == .ended || phase == .cancelled {
            if axis == .undecided && phase == .ended && bufY != 0 { result = .scroll(x: 0, y: bufY) }  // tiny vertical flick
            bufX = 0; bufY = 0
            inGesture = false  // `axis` stays, so the inertia that follows is classified like the gesture
        }
        return result
    }
}

func scrollPhaseKind(_ p: NSEvent.Phase) -> ScrollPhaseKind {
    if p.contains(.began) { return .began }
    if p.contains(.ended) { return .ended }
    if p.contains(.cancelled) { return .cancelled }
    if p.contains(.changed) { return .changed }
    if p.contains(.mayBegin) { return .mayBegin }
    return .none
}

// MARK: - Mouse capture (detach the cursor, hide it, give it back)

/// While active, the Mac cursor is detached from the mouse (CGAssociateMouseAndMouseCursorPosition(0)) and hidden, so
/// the trackpad no longer drives macOS; its movement is still reported to the event tap as relative deltas.
/// `release()` is idempotent and safe to call from any thread - it is the one function every emergency path uses.
final class MouseCapture {
    private let lock = NSLock()
    private var active = false
    private var anchor = CGPoint.zero
    private var cursorHidden = false
    private var lastReassert = 0.0
    private var driftLogged = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    @discardableResult
    func engage() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if active { return true }
        anchor = CGEvent(source: nil)?.location ?? .zero
        let err = CGAssociateMouseAndMouseCursorPosition(0)
        if err != .success { say("Could not detach the Mac cursor (CGError \(err.rawValue))") }
        // Hiding is cosmetic (macOS only honours it for the frontmost app); the detach above is what holds the cursor.
        if CGDisplayHideCursor(CGMainDisplayID()) == .success { cursorHidden = true }
        active = true
        driftLogged = false
        return err == .success
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        CGAssociateMouseAndMouseCursorPosition(1)  // first: this is what gives the mouse back
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
        // If the cursor was moved anyway, put it back where it was when capture started.
        if let now = CGEvent(source: nil)?.location, hypot(now.x - anchor.x, now.y - anchor.y) > 2 {
            CGWarpMouseCursorPosition(anchor)
        }
    }

    /// Called for every pointer-move event while captured: if the cursor position changed although it should be
    /// frozen, the detach did not take effect (or was undone), so apply it again.
    func checkDrift(_ loc: CGPoint) {
        lock.lock()
        guard active, hypot(loc.x - anchor.x, loc.y - anchor.y) > 3 else {
            lock.unlock()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let again = now - lastReassert > 0.5
        if again { lastReassert = now }
        let log = !driftLogged
        driftLogged = true
        lock.unlock()
        if again { CGAssociateMouseAndMouseCursorPosition(0) }
        if log { say("Cursor position changed while captured - re-applying the detach") }
    }
}

// MARK: - Event taps

let gestureEventTypes: [UInt32] = [18, 19, 20, 29, 30, 31, 32, 34]  // rotate, begin/end gesture, gesture, magnify, swipe, smart magnify, pressure

// NX_KEYTYPE_* values we forward as media keys (code = 0x100 + value on the wire).
let forwardedMediaKeys: Set<Int> = [0, 1, 7, 16, 17, 18, 19, 20]  // vol up/down, mute, play, next, prev, ff, rew

// Device-dependent modifier bits inside CGEventFlags (NX_DEVICE*KEYMASK): they tell left from right.
let deviceMask: [UInt16: UInt64] = [
    55: 0x08,    // left command
    54: 0x10,    // right command
    56: 0x02,    // left shift
    60: 0x04,    // right shift
    58: 0x20,    // left option
    61: 0x40,    // right option
    59: 0x01,    // left control
    62: 0x2000,  // right control
]

struct MouseOptions {
    var enabled = true
    var pointerSpeed = 1.0
    var scrollSpeed = 1.0
    var invertV = false
    var invertH = false
}

var gLink: Link!
var gFwd: Forwarder!
var gClip: ClipboardSync!
var gApp: AppController!

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    return gFwd.handle(type: type, event: event)
}

let panicCallback: CGEventTapCallBack = { _, type, event, _ in
    return gFwd.panicHandle(type: type, event: event)
}

/// A second, tiny event tap that does nothing but watch for the hotkey. It runs on its own thread, so a stalled or busy
/// main thread cannot delay it, and it is created after the main tap so it sits in front of it.
final class PanicTap {
    private let lock = NSLock()
    private var starting = false
    private var tap: CFMachPort?
    private var warned = false

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil || starting
    }

    func ensureRunning() {
        lock.lock()
        if tap != nil || starting {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()
        let t = Thread { [self] in self.run() }
        t.name = "mackeybridge.panic"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func run() {
        let mask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: panicCallback,
            userInfo: nil
        ) else {
            lock.lock()
            starting = false
            let first = !warned
            warned = true
            lock.unlock()
            if first { say("Emergency hotkey tap could not be created yet (the Carbon hotkey and the main tap still work)") }
            return
        }
        lock.lock()
        tap = port
        starting = false
        lock.unlock()
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    func reenable() {
        lock.lock()
        let t = tap
        lock.unlock()
        if let t = t { CGEvent.tapEnable(tap: t, enable: true) }
    }

    var enabled: Bool {
        lock.lock()
        let t = tap
        lock.unlock()
        guard let tt = t else { return false }
        return CGEvent.tapIsEnabled(tap: tt)
    }
}

/// Permission-free global hotkey (Carbon RegisterEventHotKey). It keeps working when the event taps do not see
/// keystrokes (permission revoked, tap disabled, Secure Event Input), so it is the last line of defence.
final class CarbonHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ hk: Hotkey) {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let st = InstallEventHandler(GetEventDispatcherTarget(), { (_, _, _) -> OSStatus in
                gFwd.hotkeyFired("Carbon hotkey")
                return noErr
            }, 1, &spec, nil, &handler)
            if st != noErr { say("Carbon hotkey handler not installed (status \(st))") }
        }
        let id = EventHotKeyID(signature: OSType(0x4D4B4252), id: 1)  // 'MKBR'
        let st = RegisterEventHotKey(UInt32(hk.code), hk.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
        if st != noErr { say("Carbon hotkey \(hk.display) not registered (status \(st)); the event taps still handle it") }
    }

    func unregister() {
        if let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
        }
    }
}

func permissionStatus() -> (ax: Bool, im: Bool) {
    return (AXIsProcessTrusted(), CGPreflightListenEventAccess())
}

final class Forwarder {
    let link: Link
    var tap: CFMachPort?
    var onChange: (() -> Void)?
    var mouse = MouseOptions()   // main thread only (the main tap runs on the main thread)
    var nav = NavOptions()       // main thread only
    var shortcuts = ShortcutMappingOptions()  // main thread only
    private let mapper = KeyboardMapper()
    let capture = MouseCapture()
    let panic = PanicTap()

    // State shared with the emergency paths (any thread) - always accessed under stateLock.
    private let stateLock = NSLock()
    private var _forwarding = false
    private var _hotkey = Hotkey()
    private var _recording = false
    private var _needsReset = false
    private var lastHotkeyFire = -100.0

    // Main-thread-only bookkeeping (reset lazily through _needsReset).
    private var held = HeldState()
    private var accX = 0.0, accY = 0.0       // pointer remainders (sub-pixel movement is not lost)
    private var accSX = 0.0, accSY = 0.0     // scroll remainders
    private let swipe = SwipeRecognizer()
    private var swallowHotkeyUp = false
    private var warnedSecureInput = false

    /// When input was last sent to the PC (systemUptime, main thread) - drives the activity lights in the window.
    private(set) var lastKeyActivity = 0.0
    private(set) var lastPointerActivity = 0.0

    init(link: Link) { self.link = link }

    var forwarding: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _forwarding
    }

    var hotkey: Hotkey {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _hotkey
        }
        set {
            stateLock.lock()
            _hotkey = newValue
            stateLock.unlock()
        }
    }

    /// While the user is recording a new hotkey, no hotkey fires.
    var recordingHotkey: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _recording
        }
        set {
            stateLock.lock()
            _recording = newValue
            stateLock.unlock()
        }
    }

    var tapInstalled: Bool { tap != nil }

    /// Forwarding can start only with the tap installed AND both privacy permissions granted. With Accessibility alone
    /// macOS creates the tap but does not deliver keystrokes, which would leave the hotkey dead.
    var ready: Bool {
        let p = permissionStatus()
        return tap != nil && p.ax && p.im
    }

    func installTap() -> Bool {
        if tap != nil {
            panic.ensureRunning()
            return true
        }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel,
        ]
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        mask |= CGEventMask(1) << CGEventMask(14)  // NSEventType.systemDefined: media keys
        for g in gestureEventTypes { mask |= CGEventMask(1) << CGEventMask(g) }  // pinch / rotate / swipe: keep them off the Mac while forwarding

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // active tap: allowed to swallow events
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: nil
        ) else { return false }

        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        panic.ensureRunning()  // created after the main tap -> sits in front of it
        return true
    }

    // MARK: start / stop

    func toggle() {
        if forwarding { stop(reason: "button or menu") } else { start() }
    }

    /// Main thread.
    func start() {
        if forwarding { return }
        guard link.connected else {
            say("Not connected to Windows yet - forwarding not enabled")
            return
        }
        guard tap != nil else {
            say("Keyboard capture is not active - grant Accessibility + Input Monitoring first")
            return
        }
        let p = permissionStatus()
        guard p.ax && p.im else {
            var missing: [String] = []
            if !p.ax { missing.append("Accessibility") }
            if !p.im { missing.append("Input Monitoring") }
            say("Forwarding not started: \(missing.joined(separator: " and ")) permission missing. Grant it in System Settings -> Privacy & Security.")
            notifyChanged()
            return
        }
        stateLock.lock()
        _forwarding = true
        _needsReset = true
        stateLock.unlock()
        updateMouseCapture()
        say("Forwarding ON: keyboard and trackpad now control Windows (\(hotkey.display) to stop)")
        notifyChanged()
    }

    /// Any thread. Idempotent. The mouse is released first, before anything that could fail or block.
    func stop(reason: String) {
        stateLock.lock()
        let was = _forwarding
        _forwarding = false
        _needsReset = true
        stateLock.unlock()
        capture.release()
        if was {
            link.enqueue([pktAllUp, 0, 0, 0])  // release every key and mouse button still held on the PC
            say("Forwarding OFF (\(reason)): keyboard and trackpad are back on this Mac")
        }
        notifyChanged()
    }

    /// Detach / re-attach the cursor so that it matches "forwarding && trackpad forwarding enabled". Main thread.
    func updateMouseCapture() {
        if forwarding && mouse.enabled {
            capture.engage()
            if !forwarding { capture.release() }  // an emergency stop raced with us: it wins
        } else {
            capture.release()
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [self] in self.onChange?() }
    }

    /// Called from the main tap, the emergency tap and the Carbon hotkey - one key press may arrive through
    /// several of them, so duplicates within 0.4 s are dropped.
    func hotkeyFired(_ source: String) {
        stateLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        if _recording || now - lastHotkeyFire < 0.4 {
            stateLock.unlock()
            return
        }
        lastHotkeyFire = now
        let on = _forwarding
        stateLock.unlock()
        if on {
            stop(reason: "hotkey via \(source)")  // immediately, on whatever thread we are on
        } else {
            DispatchQueue.main.async { [self] in self.start() }
        }
    }

    private func hotkeyMatches(_ code: UInt16, _ flags: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !_recording && _hotkey.matches(code: code, flags: flags)
    }

    private func takeReset() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let r = _needsReset
        _needsReset = false
        return r
    }

    /// Once per second on the main thread: nothing may be left captured.
    func watchdog() {
        if let t = tap, !CGEvent.tapIsEnabled(tap: t) {
            if forwarding { stop(reason: "event tap was switched off") }
            CGEvent.tapEnable(tap: t, enable: true)
        }
        if tap != nil {
            if !panic.running { panic.ensureRunning() } else if !panic.enabled { panic.reenable() }
        }
        if forwarding {
            let p = permissionStatus()
            if !(p.ax && p.im) { stop(reason: "a privacy permission was revoked") }
            if IsSecureEventInputEnabled() && !warnedSecureInput {
                warnedSecureInput = true
                say("Secure Event Input is on (a password field or Secure Keyboard Entry): keystrokes may not reach MacKeyBridge. The hotkey still works.")
            }
        } else {
            warnedSecureInput = false
            if capture.isActive { capture.release() }  // invariant: never captured while not forwarding
        }
    }

    // MARK: sending

    private func sendKey(_ type: UInt8, _ code: UInt16, repeatFlag: Bool = false) {
        lastKeyActivity = ProcessInfo.processInfo.systemUptime
        link.enqueue([type, repeatFlag ? 1 : 0, UInt8(code & 0xFF), UInt8(code >> 8)])
    }

    private func sendPair(_ type: UInt8, _ a: Int, _ b: Int) {
        lastPointerActivity = ProcessInfo.processInfo.systemUptime
        let x = UInt16(bitPattern: Int16(clamping: a))
        let y = UInt16(bitPattern: Int16(clamping: b))
        link.enqueue([type, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)])
    }

    private func sendScroll(_ px: Double, _ py: Double) {
        let k = 3.0 * mouse.scrollSpeed  // 120 wheel units (one notch) ~ 40 pixels
        accSY += py * k * (mouse.invertV ? -1.0 : 1.0)
        accSX += -px * k * (mouse.invertH ? -1.0 : 1.0)  // Mac + = scroll left, Windows + = scroll right
        let iy = Int(accSY)
        let ix = Int(accSX)
        accSY -= Double(iy)
        accSX -= Double(ix)
        if ix != 0 || iy != 0 { sendPair(pktMouseWheel, ix, iy) }
    }

    /// One slide / page step, sent with the ordinary key or mouse-button packets (the wire protocol is unchanged).
    private func sendSwipe(next: Bool) {
        if nav.output == 2 {
            // Mouse side buttons: button 3 = Back (previous), button 4 = Forward (next).
            let button: UInt8 = next ? 4 : 3
            link.enqueue([pktMouseButton, button, 1])
            link.enqueue([pktMouseButton, button, 0])
        } else {
            let code: UInt16
            if nav.output == 1 {
                code = next ? 121 : 116  // Page Down / Page Up
            } else {
                code = next ? 124 : 123  // Right / Left arrow
            }
            sendKey(pktKeyDown, code)
            sendKey(pktKeyUp, code)
        }
        say(next ? "Swipe: next slide / page" : "Swipe: previous slide / page")
    }

    // MARK: event handling

    /// The emergency tap (own thread): only looks for the hotkey, never blocks, never touches UI.
    private var panicSwallowUp: UInt16 = 0xFFFF  // only touched by the emergency tap's thread

    func panicHandle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            panic.reenable()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            if hotkeyMatches(code, event.flags.rawValue) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { hotkeyFired("emergency tap") }
                panicSwallowUp = code
                return nil
            }
        } else if code == panicSwallowUp {
            panicSwallowUp = 0xFFFF
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switched the tap off (too slow / user input): until it is back nothing is intercepted and the hotkey
        // might be missed, so never stay captured.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop(reason: "event tap was disabled by macOS")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if takeReset() {
            // A start/stop happened since the last event. If something is still marked held, an event of ours raced with
            // an emergency stop on another thread and was sent after its ALL_UP: release it on the PC again.
            if !held.isEmpty { link.enqueue([pktAllUp, 0, 0, 0]) }
            held.reset()
            mapper.reset()
            accX = 0; accY = 0; accSX = 0; accSY = 0
            swipe.reset()
        }

        // The hotkey (fallback path: the emergency tap normally sees it first). Never forwarded.
        if type == .keyDown || type == .keyUp {
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown, hotkeyMatches(code, event.flags.rawValue) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { hotkeyFired("main tap") }
                swallowHotkeyUp = true
                return nil
            }
            if type == .keyUp, swallowHotkeyUp, code == hotkey.code {
                swallowHotkeyUp = false
                return nil
            }
        }

        // Safety: only swallow input while forwarding and while the link is up, otherwise the Mac keeps working normally.
        guard forwarding else { return Unmanaged.passUnretained(event) }
        guard link.connected else {
            stop(reason: "connection to Windows lost")
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let rep = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if mapper.isModifier(code) {
                emit(mapper.modifierDown(code))
                return nil
            }
            switch mapper.keyDown(code, isRepeat: rep) {
            case .events(let events):
                emit(events)
                return nil
            case .leaveOnMac:
                return Unmanaged.passUnretained(event)  // Cmd+Space / Cmd+Q / Cmd+Option+Escape stay on the Mac
            }

        case .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let plan = mapper.isModifier(code) ? mapper.modifierUp(code) : mapper.keyUp(code)
            switch plan {
            case .events(let events):
                emit(events)
                return nil
            case .leaveOnMac:
                return Unmanaged.passUnretained(event)  // released a key that was not sent while forwarding
            }

        case .flagsChanged:
            // Modifier keys (and Fn / Globe = key code 63) arrive as flagsChanged with their own key code.
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let raw = event.flags.rawValue
            if code == 57 {  // Caps Lock reports state changes, not key presses: send one tap per event
                sendKey(pktKeyDown, code)
                sendKey(pktKeyUp, code)
                return nil
            }
            let down: Bool
            if code == 63 {
                down = (raw & CGEventFlags.maskSecondaryFn.rawValue) != 0
            } else if let m = deviceMask[code] {
                down = (raw & m) != 0
            } else {
                down = false
            }
            if down {
                emit(mapper.modifierDown(code))
            } else {
                switch mapper.modifierUp(code) {
                case .events(let events): emit(events)
                case .leaveOnMac: return Unmanaged.passUnretained(event)
                }
            }
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard mouse.enabled else { return Unmanaged.passUnretained(event) }
            capture.checkDrift(event.location)
            accX += event.getDoubleValueField(.mouseEventDeltaX) * mouse.pointerSpeed
            accY += event.getDoubleValueField(.mouseEventDeltaY) * mouse.pointerSpeed
            let ix = Int(accX)  // truncates toward zero; the fraction stays in the accumulator
            let iy = Int(accY)
            accX -= Double(ix)
            accY -= Double(iy)
            if ix != 0 || iy != 0 { sendPair(pktMouseMove, ix, iy) }
            return nil

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            guard mouse.enabled else { return Unmanaged.passUnretained(event) }
            var button: UInt8 = 2
            switch type {
            case .leftMouseDown, .leftMouseUp: button = 0
            case .rightMouseDown, .rightMouseUp: button = 1
            default:
                let n = event.getIntegerValueField(.mouseEventButtonNumber)  // 2 middle, 3 back, 4 forward
                button = (n >= 2 && n <= 4) ? UInt8(n) : 2
            }
            let down = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
            lastPointerActivity = ProcessInfo.processInfo.systemUptime
            if down {
                held.buttonDown(button)
                link.enqueue([pktMouseButton, button, 1])
                return nil
            }
            if held.buttonUp(button) {
                link.enqueue([pktMouseButton, button, 0])
                return nil
            }
            return Unmanaged.passUnretained(event)  // pressed on the Mac before forwarding started

        case .scrollWheel:
            guard mouse.enabled else { return Unmanaged.passUnretained(event) }
            return handleScroll(event)

        default:
            if type.rawValue == 14 { return handleSystemDefined(event) }
            if gestureEventTypes.contains(type.rawValue) {
                if mouse.enabled { return nil }  // pinch / rotate / swipe must not act on the Mac under the frozen cursor
            }
            return Unmanaged.passUnretained(event)
        }
    }

    /// Sends the events produced by the mapper. `held` mirrors exactly what went on the wire, so a key-up is never
    /// sent for a key whose key-down was not forwarded (e.g. one pressed before forwarding started).
    private func emit(_ events: [WireKeyEvent]) {
        for e in events {
            switch e {
            case .down(let code, let isRepeat):
                held.keyDown(code)
                sendKey(pktKeyDown, code, repeatFlag: isRepeat)
            case .up(let code):
                if held.keyUp(code) { sendKey(pktKeyUp, code) }
            }
        }
    }

    /// Called when the shortcut settings change: release translated modifiers that Windows may still hold.
    func releaseMappedKeys() {
        emit(mapper.releaseAll())
    }

    /// Scrolling: a two-finger trackpad gesture is either a swipe (horizontal) or an ordinary scroll (vertical);
    /// a real mouse wheel, or anything while a modifier is held, is forwarded as before.
    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let py = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))  // pixels, + = up
        let px = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        var result = ScrollResult.scroll(x: px, y: py)

        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0  // trackpad / Magic Mouse
        let noModifiers = (event.flags.rawValue & hotkeyModMask) == 0 && !held.modifiersHeld
        if nav.enabled, continuous, noModifiers, let ns = NSEvent(cgEvent: event) {
            let phase = scrollPhaseKind(ns.phase)
            let momentum = !ns.momentumPhase.isEmpty
            if phase != .none || momentum {
                // Natural scrolling: content follows the fingers, so the delta sign is the finger direction.
                let fingerX = ns.isDirectionInvertedFromDevice ? px : -px
                result = swipe.feed(rawX: px, rawY: py, fingerX: fingerX, phase: phase, momentum: momentum,
                                    threshold: nav.threshold, now: ProcessInfo.processInfo.systemUptime)
            }
        }

        switch result {
        case .none: break
        case .scroll(let x, let y): sendScroll(x, y)
        case .swipe(let forward): sendSwipe(next: forward != nav.reverse)
        }
        return nil
    }

    /// Media keys (volume, play/pause, next, previous) come as NSSystemDefined subtype 8.
    private func handleSystemDefined(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let keyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) != 0
        guard forwardedMediaKeys.contains(keyType) else {
            return Unmanaged.passUnretained(event)  // brightness, keyboard backlight ... stay on the Mac
        }
        if isDown { sendKey(pktKeyDown, UInt16(0x100 + keyType), repeatFlag: isRepeat) }
        return nil
    }
}

// MARK: - Self test and diagnostics (command line: --selftest, --diagnose)

func runSelfTests() -> Int32 {
    var failed = 0
    func check(_ name: String, _ ok: Bool) {
        print((ok ? "PASS  " : "FAIL  ") + name)
        if !ok { failed += 1 }
    }

    typealias S = (dx: Double, dy: Double, p: ScrollPhaseKind, m: Bool, t: Double)
    /// Runs the recognizer over events; `fingerX` equals the raw dx here (natural scrolling).
    func run(_ r: SwipeRecognizer, _ events: [S], threshold: Double = 80) -> [ScrollResult] {
        return events.map {
            r.feed(rawX: $0.dx, rawY: $0.dy, fingerX: $0.dx, phase: $0.p, momentum: $0.m, threshold: threshold, now: $0.t)
        }
    }
    /// A gesture: began, `n - 1` x changed, ended. Each event moves (dx, dy); 10 ms apart, starting at t0.
    func gesture(dx: Double, dy: Double, n: Int, t0: Double) -> [S] {
        var e: [S] = []
        for i in 0..<n {
            let p: ScrollPhaseKind = i == 0 ? .began : .changed
            e.append((dx, dy, p, false, t0 + Double(i) * 0.01))
        }
        e.append((0, 0, .ended, false, t0 + Double(n) * 0.01))
        return e
    }
    func swipes(_ rs: [ScrollResult]) -> [Bool] {
        return rs.compactMap { (x: ScrollResult) -> Bool? in
            if case .swipe(let f) = x { return f }
            return nil
        }
    }
    func scrollSum(_ rs: [ScrollResult]) -> (x: Double, y: Double) {
        var x = 0.0, y = 0.0
        for r in rs { if case .scroll(let a, let b) = r { x += a; y += b } }
        return (x, y)
    }

    // 1/2: direction. Fingers left -> right (+dx) = previous (forward == false); right -> left = next.
    var r = SwipeRecognizer()
    check("swipe left->right fires one 'previous'", swipes(run(r, gesture(dx: 25, dy: 1, n: 8, t0: 100))) == [false])
    r = SwipeRecognizer()
    check("swipe right->left fires one 'next'", swipes(run(r, gesture(dx: -25, dy: -1, n: 8, t0: 100))) == [true])

    // 3: a long horizontal gesture still fires only once, and its inertia does nothing.
    r = SwipeRecognizer()
    var ev = gesture(dx: 30, dy: 0, n: 30, t0: 100)
    ev.append((20, 0, .none, true, 100.5))
    ev.append((10, 0, .none, true, 100.52))
    let rs3 = run(r, ev)
    check("long horizontal gesture: exactly one swipe", swipes(rs3).count == 1)
    check("horizontal gesture + inertia: nothing is scrolled", scrollSum(rs3).x == 0 && scrollSum(rs3).y == 0)

    // 4: vertical scrolling never swipes and loses no distance (the held-back start is flushed).
    r = SwipeRecognizer()
    let rs4 = run(r, gesture(dx: 1, dy: 20, n: 20, t0: 100))
    check("vertical scroll: no swipe", swipes(rs4).isEmpty)
    check("vertical scroll: full distance forwarded (400)", scrollSum(rs4).y == 400)
    check("vertical scroll: no sideways leak", scrollSum(rs4).x == 0)

    // 5: vertical inertia keeps scrolling.
    r = SwipeRecognizer()
    var ev5 = gesture(dx: 0, dy: 15, n: 10, t0: 100)
    ev5.append((0, 9, .none, true, 100.3))
    ev5.append((0, 4, .none, true, 100.32))
    check("vertical inertia is forwarded (150 + 13)", scrollSum(run(r, ev5)).y == 163)

    // 6: small horizontal movement (below the threshold) does nothing at all.
    r = SwipeRecognizer()
    let rs6 = run(r, gesture(dx: 5, dy: 0, n: 8, t0: 100))  // 40 points in total
    check("small horizontal movement: no swipe", swipes(rs6).isEmpty)
    check("small horizontal movement: not scrolled either", scrollSum(rs6).x == 0)

    // 7: diagonal gesture that is mostly vertical is a scroll.
    r = SwipeRecognizer()
    check("mostly vertical diagonal: no swipe", swipes(run(r, gesture(dx: 20, dy: 40, n: 10, t0: 100))).isEmpty)

    // 8: two separate gestures = two swipes; a second one within the cooldown is dropped.
    r = SwipeRecognizer()
    var ev8 = gesture(dx: 30, dy: 0, n: 6, t0: 100)
    ev8 += gesture(dx: 30, dy: 0, n: 6, t0: 100.6)
    check("two gestures 0.6 s apart: two swipes", swipes(run(r, ev8)).count == 2)
    r = SwipeRecognizer()
    var ev8b = gesture(dx: 30, dy: 0, n: 4, t0: 100)
    ev8b += gesture(dx: 30, dy: 0, n: 4, t0: 100.08)
    check("second swipe inside the cooldown is dropped", swipes(run(r, ev8b)).count == 1)

    // 9: a missed 'began' (long silence) starts a new gesture instead of continuing the latched one.
    r = SwipeRecognizer()
    var ev9 = gesture(dx: 30, dy: 0, n: 5, t0: 100)
    ev9.append((30, 0, .changed, false, 105.0))
    ev9.append((30, 0, .changed, false, 105.01))
    ev9.append((30, 0, .changed, false, 105.02))
    check("stale state: events after a long gap start a new gesture", swipes(run(r, ev9)).count == 2)

    // 10: a configurable threshold.
    r = SwipeRecognizer()
    check("threshold 300: a 200-point swipe does not fire", swipes(run(r, gesture(dx: 25, dy: 0, n: 8, t0: 100), threshold: 300)).isEmpty)
    r = SwipeRecognizer()
    check("threshold 30: a 200-point swipe fires", swipes(run(r, gesture(dx: 25, dy: 0, n: 8, t0: 100), threshold: 30)).count == 1)

    // 11: hotkey matching.
    let hk = Hotkey()
    check("default hotkey is Control+Option+Command+W", hk.display == "⌃⌥⌘W" && hk.code == 13)
    check("hotkey matches its chord", hk.matches(code: 13, flags: ctrlFlag | optFlag | cmdFlag))
    check("hotkey tolerates an extra Shift", hk.matches(code: 13, flags: ctrlFlag | optFlag | cmdFlag | shiftFlag))
    check("hotkey needs every modifier", !hk.matches(code: 13, flags: ctrlFlag | cmdFlag))
    check("hotkey needs the right key", !hk.matches(code: 14, flags: ctrlFlag | optFlag | cmdFlag))
    var single = Hotkey()
    single.flags = cmdFlag
    check("a single-modifier hotkey is rejected", !single.isValid && hk.isValid)

    // 12: stuck-key protection.
    var h = HeldState()
    check("release of a key pressed before forwarding is not swallowed", h.keyUp(55) == false)
    h.keyDown(55)
    check("modifier held is reported", h.modifiersHeld)
    check("release of a forwarded key is forwarded", h.keyUp(55) == true)
    check("... only once", h.keyUp(55) == false)
    h.buttonDown(0)
    check("forwarded mouse button is released once", h.buttonUp(0) == true && h.buttonUp(0) == false)
    h.keyDown(0)
    h.buttonDown(1)
    h.reset()
    check("reset forgets everything", !h.modifiersHeld && h.keyUp(0) == false && h.buttonUp(1) == false)

    // 13: shortcut mapping (built before the wire is written).
    let down = { (c: UInt16) -> WireKeyEvent in .down(code: c, repeat: false) }
    let up = { (c: UInt16) -> WireKeyEvent in .up(code: c) }
    let map = KeyboardMapper()
    check("Cmd+Z -> Ctrl+Z", map.modifierDown(55) == [down(59)] && map.keyDown(6, isRepeat: false) == .events([down(6)])
          && map.keyUp(6) == .events([up(6)]) && map.modifierUp(55) == .events([up(59)]))
    check("Shift keeps its semantics", map.modifierDown(56) == [down(56)] && map.modifierUp(56) == .events([up(56)]))
    _ = map.modifierDown(55)
    _ = map.modifierDown(56)
    check("Cmd+Shift+Z -> Ctrl+Y", map.keyDown(6, isRepeat: false) == .events([down(16)])
          && map.keyUp(6) == .events([up(16)]))
    _ = map.modifierUp(56)
    _ = map.modifierUp(55)
    _ = map.modifierDown(55)
    let tabPlan = map.keyDown(48, isRepeat: false)
    check("Cmd+Tab emits an Alt+Tab chord", tabPlan == .events([up(59), down(58), down(48), up(48), up(58), down(59)])
          && map.keyUp(48) == .events([]))
    _ = map.modifierUp(55)
    _ = map.modifierDown(55)
    _ = map.modifierDown(58)
    check("Cmd+Option+Escape stays on the Mac", map.keyDown(53, isRepeat: false) == .leaveOnMac)
    _ = map.modifierUp(58)
    check("Cmd+Space stays on the Mac", map.keyDown(49, isRepeat: false) == .leaveOnMac)
    check("Cmd+Q stays on the Mac", map.keyDown(12, isRepeat: false) == .leaveOnMac)
    _ = map.modifierUp(55)
    check("duplicate key-down is not sent twice", map.keyDown(8, isRepeat: false) == .events([down(8)])
          && map.keyDown(8, isRepeat: false) == .events([]) && map.keyUp(8) == .events([up(8)]))
    check("key-up of a key never sent is ignored", map.keyUp(99) == .leaveOnMac)
    let both = KeyboardMapper()
    _ = both.modifierDown(55)
    _ = both.modifierDown(59)
    check("two physical modifiers map to one Ctrl without early release", both.modifierDown(55) == []
          && both.modifierUp(55) == .events([down(54), up(54)]) && both.modifierUp(59) == .events([up(59)]))
    let solo = KeyboardMapper()
    _ = solo.modifierDown(55)
    check("Command with no other key becomes the Windows key", solo.modifierUp(55) == .events([up(59), down(54), up(54)]))
    let used = KeyboardMapper()
    _ = used.modifierDown(55)
    _ = used.keyDown(8, isRepeat: false)
    _ = used.keyUp(8)
    check("Command used for a shortcut is not a Windows key", used.modifierUp(55) == .events([up(59)]))
    let winMap = KeyboardMapper()
    _ = winMap.modifierDown(55)
    _ = winMap.modifierDown(58)
    check("Option+Command+E -> Win+E", winMap.keyDown(14, isRepeat: false)
          == .events([up(59), up(58), down(54), down(14), up(14), up(54), down(59), down(58)])
          && winMap.keyUp(14) == .events([]))
    check("Option+Command+Q -> Win+Q", winMap.keyDown(12, isRepeat: false)
          == .events([up(59), up(58), down(54), down(12), up(12), up(54), down(59), down(58)]))
    check("releaseAll lifts everything and resets", {
        let m = KeyboardMapper()
        _ = m.modifierDown(55)
        _ = m.keyDown(8, isRepeat: false)
        return m.releaseAll() == [up(8), up(59)] && m.modifierUp(55) == .leaveOnMac
    }())
    var off = ShortcutMappingOptions()
    off.enabled = false
    let raw = KeyboardMapper(options: off)
    check("mapping off forwards raw keys", raw.modifierDown(55) == [down(55)] && raw.modifierUp(55) == .events([up(55)]))

    // 14: clipboard frames (protocol 3).
    let text = Data("Привет, Windows!\nline 2".utf8)
    let pkt = clipboardPacket(kind: clipKindText, payload: text)
    check("clipboard packet header is 6 bytes", pkt.count == 6 + text.count && pkt[0] == pktClipboard && pkt[1] == clipKindText)
    var fp = PeerFrameParser()
    let whole = (try? fp.feed(pkt)) ?? []
    check("clipboard text round-trips", whole == [.clipboard(kind: clipKindText, data: text)])
    fp = PeerFrameParser()
    var pieces: [PeerMessage] = []
    for i in stride(from: 0, to: pkt.count, by: 3) {  // arrives in tiny pieces
        pieces += (try? fp.feed(Array(pkt[i..<min(i + 3, pkt.count)]))) ?? []
    }
    check("clipboard text split over many reads", pieces == [.clipboard(kind: clipKindText, data: text)])
    fp = PeerFrameParser()
    let two = (try? fp.feed([pktClipState, clipFlagOn | clipFlagImages, pktPing, 0, 0, 0, pktClipState, 0])) ?? []
    check("state + ping + state in one read",
          two == [.clipboardState(enabled: true, images: true), .clipboardState(enabled: false, images: false)])
    fp = PeerFrameParser(maxPayload: 10)
    var tooBig = false
    do { _ = try fp.feed(clipboardPacket(kind: clipKindPNG, payload: Data(count: 11))) } catch { tooBig = true }
    check("oversized clipboard is rejected", tooBig)
    fp = PeerFrameParser()
    var unknown = false
    do { _ = try fp.feed([0x7F]) } catch { unknown = true }
    check("unknown packet type is rejected", unknown)
    fp = PeerFrameParser()
    let empty = (try? fp.feed(clipboardPacket(kind: clipKindText, payload: Data()))) ?? []
    check("empty clipboard payload is accepted", empty == [.clipboard(kind: clipKindText, data: Data())])

    print(failed == 0 ? "\nAll self-tests passed." : "\n\(failed) self-test(s) FAILED.")
    return failed == 0 ? 0 : 1
}

var gDiag: [String: Int] = [:]

let diagCallback: CGEventTapCallBack = { _, type, event, _ in
    let name: String
    switch type {
    case .keyDown: name = "keyDown"
    case .keyUp: name = "keyUp"
    case .flagsChanged: name = "flagsChanged"
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: name = "pointer move/drag"
    case .leftMouseDown, .rightMouseDown, .otherMouseDown: name = "button down"
    case .scrollWheel: name = "scroll"
    default: name = "other (\(type.rawValue))"
    }
    gDiag[name, default: 0] += 1
    return Unmanaged.passUnretained(event)
}

/// Prints the privacy-permission state and counts the events a tap really receives for 8 seconds.
func runDiagnose() -> Int32 {
    let p = permissionStatus()
    print("Accessibility:      " + (p.ax ? "granted" : "NOT granted"))
    print("Input Monitoring:   " + (p.im ? "granted" : "NOT granted"))
    print("Secure Event Input: " + (IsSecureEventInputEnabled() ? "ON (an app is blocking keyboard taps)" : "off"))

    var mask: CGEventMask = 0
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
    for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                       eventsOfInterest: mask, callback: diagCallback, userInfo: nil) else {
        print("\nCould not create an event tap: grant Accessibility and Input Monitoring to this app (or to your terminal) first.")
        return 2
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    print("\nListening for 8 seconds - type something, move the pointer, click and scroll with two fingers ...")
    CFRunLoopRunInMode(.defaultMode, 8, false)

    print("\nEvents received by the tap:")
    if gDiag.isEmpty { print("  (none)") }
    for (k, v) in gDiag.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
    let keys = (gDiag["keyDown"] ?? 0) + (gDiag["flagsChanged"] ?? 0)
    if keys == 0 {
        print("\nNo keyboard events arrived. If you typed: Input Monitoring is missing, or Secure Event Input is on.")
        print("MacKeyBridge then cannot see its hotkey through the event tap (the Carbon hotkey fallback still works).")
    } else {
        print("\nKeyboard events are delivered - the event taps work.")
    }
    return 0
}

// MARK: - App controller (window, menu bar item, hotkey recording, permissions)
//
// The window itself is SwiftUI (UI.swift, `AppModel` + views). This class owns the AppKit side: lifecycle, menus,
// the menu bar item, the emergency hotkey and the 1-second watchdog tick.

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var menuStateItem: NSMenuItem!
    var menuToggleItem: NSMenuItem!
    var menuClipItem: NSMenuItem!

    let model = AppModel()
    let carbonHotkey = CarbonHotkey()
    var recordMonitor: Any?
    var timer: Timer?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A previous instance that was killed while forwarding may have left the cursor detached: re-attach it.
        CGAssociateMouseAndMouseCursorPosition(1)
        gLogSink = { [weak self] line in self?.model.appendLog(line) }
        DistributedNotificationCenter.default().addObserver(self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        // Command line arguments override the saved values.
        let cli = parseArgs()
        if let h = cli.host { prefs.host = h }
        if let p = cli.port { prefs.port = p }
        if let s = cli.secret { prefs.secret = s }
        model.reloadConnectionFields()

        buildMenu()
        buildWindow()
        applyAppearance()
        buildStatusItem()

        model.applyOptions()
        gFwd.hotkey = prefs.hotkey
        carbonHotkey.register(gFwd.hotkey)

        gLink.onState = { [weak self] st in
            // Immediately, on the link thread: losing the connection must never leave the Mac captured.
            if st != .connected { gFwd.stop(reason: "connection to Windows lost") }
            gClip.linkStateChanged(st)
            DispatchQueue.main.async { self?.refreshUI() }
        }
        gLink.onMessage = { m in gClip.handle(m) }
        gFwd.onChange = { [weak self] in self?.refreshUI() }
        gClip.onUpdate = { [weak self] in self?.refreshUI() }
        gClip.onTransfer = { [weak self] t in self?.model.clipboardTransferred(t) }
        gClip.start()

        // Release the mouse whenever the Mac goes away from the user: sleep, screen sleep, fast user switching.
        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            wsCenter.addObserver(forName: name, object: nil, queue: nil) { note in
                gFwd.stop(reason: note.name.rawValue)
            }
        }

        requestPermissionsOnce()
        if !gFwd.installTap() { say("Waiting for Accessibility / Input Monitoring permission ...") }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        model.startActivityTimer()

        refreshUI()
        showWindow()
        let canConnect = !prefs.host.isEmpty && !prefs.secret.isEmpty
        if canConnect && ((cli.host != nil && cli.secret != nil) || prefs.autoConnect) { model.connect() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        gFwd.stop(reason: "quit")  // gives the Mac cursor back
        carbonHotkey.unregister()
        gLink.disconnect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)  // keep running in the menu bar
        return false
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitClicked() { NSApp.terminate(nil) }

    func tick() {
        if !gFwd.tapInstalled && gFwd.installTap() { say("Keyboard and trackpad capture is active") }
        gFwd.watchdog()
        refreshUI()
    }

    // MARK: building the UI

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide MacKeyBridge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit MacKeyBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // An Edit menu makes Cmd+C / Cmd+V work in the text fields (e.g. to paste the secret).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = winMenu
        NSApp.mainMenu = main
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menuStateItem = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
        menuStateItem.isEnabled = false
        menu.addItem(menuStateItem)
        menu.addItem(NSMenuItem.separator())
        menuToggleItem = NSMenuItem(title: "Start Forwarding", action: #selector(forwardClicked), keyEquivalent: "")
        menuToggleItem.target = self
        menu.addItem(menuToggleItem)
        menuClipItem = NSMenuItem(title: "Sync Clipboard", action: #selector(clipboardMenuClicked), keyEquivalent: "")
        menuClipItem.target = self
        menu.addItem(menuClipItem)
        menu.addItem(NSMenuItem.separator())
        let show = NSMenuItem(title: "Open MacKeyBridge…", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let quit = NSMenuItem(title: "Quit MacKeyBridge", action: #selector(quitClicked), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func buildWindow() {
        var height: CGFloat = 760
        if let screen = NSScreen.main { height = min(height, screen.visibleFrame.height - 60) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "MacKeyBridge"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 580, height: 540)
        window.contentView = makeMainContentView(model: model)
        window.center()
        window.setFrameAutosaveName("MacKeyBridgeMainWindowRedesign")
    }

    func applyAppearance() {
        switch model.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        model.systemAppearanceTick += 1
    }

    @objc func systemAppearanceChanged() {
        model.systemAppearanceTick += 1
    }

    // MARK: actions

    @objc func forwardClicked() { gFwd.toggle() }

    @objc func clipboardMenuClicked() { model.clipboardSync.toggle() }

    // MARK: hotkey recording

    func changeHotkey() {
        if recordMonitor != nil {
            stopRecording()
            return
        }
        if gFwd.forwarding {
            say("Stop forwarding before changing the hotkey")
            return
        }
        gFwd.recordingHotkey = true  // no hotkey fires while we listen for the new one
        carbonHotkey.unregister()    // otherwise the old combination would be consumed before our window sees it
        model.recordingHotkey = true
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            self?.recorded(ev)
            return nil  // swallow it, no beep
        }
    }

    func recorded(_ ev: NSEvent) {
        let code = UInt16(ev.keyCode)
        let mods = ev.modifierFlags
        if code == 53 && !mods.contains(.control) && !mods.contains(.option) && !mods.contains(.command) {
            stopRecording()  // plain Esc cancels
            return
        }
        var hk = Hotkey()
        hk.code = code
        hk.flags = 0
        if mods.contains(.control) { hk.flags |= ctrlFlag }
        if mods.contains(.option) { hk.flags |= optFlag }
        if mods.contains(.shift) { hk.flags |= shiftFlag }
        if mods.contains(.command) { hk.flags |= cmdFlag }
        if let special = specialKeyNames[code] {
            hk.name = special
        } else if let c = ev.charactersIgnoringModifiers?.uppercased(), !c.isEmpty {
            hk.name = c
        } else {
            hk.name = "Key \(code)"
        }
        guard hk.isValid else {
            say("The hotkey needs at least two of Control, Option, Command (for example Control+Option+Command+W) - try again")
            return
        }
        setHotkey(hk)
        stopRecording()
    }

    func stopRecording() {
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        gFwd.recordingHotkey = false
        carbonHotkey.register(gFwd.hotkey)
        model.recordingHotkey = false
        refreshUI()
    }

    func setHotkey(_ hk: Hotkey) {
        prefs.hotkey = hk
        gFwd.hotkey = hk
        carbonHotkey.register(hk)
        say("Emergency hotkey is now \(hk.display)")
    }

    func resetHotkey() {
        if recordMonitor != nil { stopRecording() }
        setHotkey(Hotkey())
        refreshUI()
    }

    // MARK: permissions

    func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestPermissionsOnce() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }

    // MARK: refreshing

    func refreshUI() {
        guard window != nil, statusItem != nil else { return }
        model.refresh()

        let st = gLink.currentState
        let fwd = gFwd.forwarding
        let hk = gFwd.hotkey.display
        if let b = statusItem.button {
            let symbol = fwd ? "keyboard.fill" : "keyboard"
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacKeyBridge")
                ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MacKeyBridge")
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
            b.title = fwd ? " → PC" : (img == nil ? "⌨" : "")
            b.appearsDisabled = st != .connected
            b.toolTip = fwd ? "MacKeyBridge: forwarding to Windows (\(hk) to stop)"
                : (st == .connected ? "MacKeyBridge: connected" : "MacKeyBridge: not connected")
        }
        switch st {
        case .connected: menuStateItem.title = fwd ? "Forwarding to Windows" : "Connected to Windows"
        case .connecting: menuStateItem.title = "Connecting…"
        default: menuStateItem.title = "Not connected"
        }
        menuToggleItem.title = fwd ? "Stop Forwarding  (\(hk))" : "Start Forwarding  (\(hk))"
        menuToggleItem.isEnabled = fwd || (st == .connected && gFwd.ready)
        menuClipItem.state = model.clipboardSync ? .on : .off
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--selftest") { exit(runSelfTests()) }
if CommandLine.arguments.contains("--diagnose") { exit(runDiagnose()) }

signal(SIGPIPE, SIG_IGN)
// Never leave the Mac cursor frozen if we are killed from the terminal.
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }
}

gLink = Link()
gFwd = Forwarder(link: gLink)
gClip = ClipboardSync(link: gLink)
gApp = AppController()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = gApp
app.run()