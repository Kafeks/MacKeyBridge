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

// MARK: - Protocol constants (version 2)

let protoVersion: UInt8 = 2
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

let hotkeyCode: UInt16 = 13  // kVK_ANSI_W -> Control+Option+Command+W toggles forwarding

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
<<<<<<< HEAD
=======
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
>>>>>>> fe5b228 (Add mouse side-button swipe navigation)
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
Start/stop forwarding with Control+Option+Command+W.
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
    private let sendQ = DispatchQueue(label: "mackeybridge.send")
    var onState: ((LinkState) -> Void)?

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

    func connect(host: String, port: UInt16, secret: Data) {
        lock.lock()
        self.host = host
        self.port = port
        self.secret = secret
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

            let hs = handshake(s, secret: sec)
            if hs != .ok {
                close(s)
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
            lock.unlock()
            lastFailure = ""
            setState(.connected)
            say("Connected to Windows at \(h):\(p)")

            var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            while true {
                lock.lock()
                let g = generation
                lock.unlock()
                if g != gen { break }

                let r = poll(&pfd, 1, 1000)
                if r < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if r == 0 {  // idle for 1 s: ping (the server drops us after 3 s of silence)
                    enqueue([pktPing, 0, 0, 0])
                    continue
                }
                var buf = [UInt8](repeating: 0, count: 64)
                let n = recv(s, &buf, buf.count, 0)
                if n <= 0 { break }  // closed or error
            }

            lock.lock()
            fd = -1
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
    private func handshake(_ s: Int32, secret: Data) -> HandshakeResult {
        guard let ch = readExact(s, 17, timeoutMs: 3000), ch[0] == pktChallenge else { return .notServer }
        let nonce = Data(ch[1...16])
        let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: secret))
        var msg: [UInt8] = [pktAuth, protoVersion]
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

<<<<<<< HEAD
// MARK: - Event tap (keyboard, trackpad / mouse, media keys)
=======
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
>>>>>>> fe5b228 (Add mouse side-button swipe navigation)

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
var gApp: AppController!

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    return gFwd.handle(type: type, event: event)
}

final class Forwarder {
    let link: Link
    var tap: CFMachPort?
    var onChange: (() -> Void)?
    var mouse = MouseOptions()

    private var mouseCaptured = false
    private var accX = 0.0, accY = 0.0       // pointer remainders (sub-pixel movement is not lost)
    private var accSX = 0.0, accSY = 0.0     // scroll remainders

    var forwarding = false {
        didSet {
            if oldValue != forwarding {
                updateMouseCapture()
                onChange?()
            }
        }
    }

    var tapInstalled: Bool { tap != nil }

    init(link: Link) { self.link = link }

    func installTap() -> Bool {
        if tap != nil { return true }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel,
        ]
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        mask |= CGEventMask(1) << CGEventMask(14)  // NSEventType.systemDefined: media keys

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
        return true
    }

    func toggle() {
        if !forwarding {
            guard link.connected else {
                say("Not connected to Windows yet - forwarding not enabled")
                return
            }
            guard tap != nil else {
                say("Keyboard capture is not active - grant Accessibility + Input Monitoring first")
                return
            }
            accX = 0; accY = 0; accSX = 0; accSY = 0
            forwarding = true
            say("Forwarding ON: keyboard and trackpad now control Windows (Control+Option+Command+W to stop)")
        } else {
            link.enqueue([pktAllUp, 0, 0, 0])  // release anything still held on the PC
            forwarding = false
            say("Forwarding OFF: keyboard and trackpad are back on this Mac")
        }
    }

    /// While forwarding the trackpad, detach the cursor from the pointer so the Mac cursor stays put
    /// (relative movement is still reported to the event tap).
    func updateMouseCapture() {
        let want = forwarding && mouse.enabled
        if want != mouseCaptured {
            mouseCaptured = want
            CGAssociateMouseAndMouseCursorPosition(want ? 0 : 1)
        }
    }

    // MARK: sending

    private func sendKey(_ type: UInt8, _ code: UInt16, repeatFlag: Bool = false) {
        link.enqueue([type, repeatFlag ? 1 : 0, UInt8(code & 0xFF), UInt8(code >> 8)])
    }

    private func sendPair(_ type: UInt8, _ a: Int, _ b: Int) {
        let x = UInt16(bitPattern: Int16(clamping: a))
        let y = UInt16(bitPattern: Int16(clamping: b))
        link.enqueue([type, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)])
    }

<<<<<<< HEAD
=======
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

>>>>>>> fe5b228 (Add mouse side-button swipe navigation)
    // MARK: event handling

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that is too slow; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Control+Option+Command+W always works, even while forwarding.
        if type == .keyDown || type == .keyUp {
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let hot: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
            if code == hotkeyCode && event.flags.isSuperset(of: hot) {
                if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { toggle() }
                return nil
            }
        }

        // Safety: only swallow input while the link is up, otherwise the Mac keeps working normally.
        guard forwarding, link.connected else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown, .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let rep = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            sendKey(type == .keyDown ? pktKeyDown : pktKeyUp, code, repeatFlag: rep)
            return nil

        case .flagsChanged:
            // Modifier keys (and Fn / Globe = key code 63) arrive as flagsChanged with their own key code.
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let raw = event.flags.rawValue
            switch code {
            case 63:  // Fn / Globe
                let down = (raw & CGEventFlags.maskSecondaryFn.rawValue) != 0
                sendKey(down ? pktKeyDown : pktKeyUp, code)
            case 57:  // Caps Lock reports state changes, not key presses: send one tap per event
                sendKey(pktKeyDown, code)
                sendKey(pktKeyUp, code)
            default:
                if let m = deviceMask[code] { sendKey((raw & m) != 0 ? pktKeyDown : pktKeyUp, code) }
            }
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard mouse.enabled else { return Unmanaged.passUnretained(event) }
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
            link.enqueue([pktMouseButton, button, down ? 1 : 0])
            return nil

        case .scrollWheel:
            guard mouse.enabled else { return Unmanaged.passUnretained(event) }
            let py = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))  // pixels, + = up
            let px = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            let k = 3.0 * mouse.scrollSpeed  // 120 wheel units (one notch) ~ 40 pixels
            accSY += py * k * (mouse.invertV ? -1.0 : 1.0)
            accSX += -px * k * (mouse.invertH ? -1.0 : 1.0)  // Mac + = scroll left, Windows + = scroll right
            let iy = Int(accSY)
            let ix = Int(accSX)
            accSY -= Double(iy)
            accSX -= Double(ix)
            if ix != 0 || iy != 0 { sendPair(pktMouseWheel, ix, iy) }
            return nil

        default:
            if type.rawValue == 14 { return handleSystemDefined(event) }
            return Unmanaged.passUnretained(event)
        }
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

// MARK: - UI helpers

func makeLabel(_ s: String, bold: Bool = false) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    if bold { t.font = NSFont.boldSystemFont(ofSize: 13) }
    return t
}

func makeLabel(_ s: String, width: CGFloat) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.widthAnchor.constraint(equalToConstant: width).isActive = true
    return t
}

func makeNote(_ s: String, width: CGFloat) -> NSTextField {
    let t = NSTextField(wrappingLabelWithString: s)
    t.font = NSFont.systemFont(ofSize: 11)
    t.textColor = NSColor.secondaryLabelColor
    t.preferredMaxLayoutWidth = width
    t.widthAnchor.constraint(equalToConstant: width).isActive = true
    return t
}

func makeRow(_ views: [NSView]) -> NSStackView {
    let r = NSStackView(views: views)
    r.orientation = .horizontal
    r.alignment = .centerY
    r.spacing = 8
    return r
}

func makeSeparator(width: CGFloat) -> NSBox {
    let b = NSBox()
    b.boxType = .separator
    b.widthAnchor.constraint(equalToConstant: width).isActive = true
    return b
}

// MARK: - App controller (window, menu bar item, permissions)

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var menuStateItem: NSMenuItem!
    var menuToggleItem: NSMenuItem!

    var hostField: NSTextField!
    var portField: NSTextField!
    var secretField: NSSecureTextField!
    var connectButton: NSButton!
    var statusLabel: NSTextField!
    var forwardButton: NSButton!
    var forwardHint: NSTextField!
    var mouseCheck: NSButton!
    var pointerSlider: NSSlider!
    var pointerValue: NSTextField!
    var scrollSlider: NSSlider!
    var scrollValue: NSTextField!
    var invertVCheck: NSButton!
    var invertHCheck: NSButton!
    var axLabel: NSTextField!
    var imLabel: NSTextField!
    var autoCheck: NSButton!
    var logView: NSTextView!

    var timer: Timer?
    var inputError: String?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        buildStatusItem()
        gLogSink = { [weak self] line in self?.appendLog(line) }

        // Command line arguments override the saved values.
        let cli = parseArgs()
        if let h = cli.host { prefs.host = h }
        if let p = cli.port { prefs.port = p }
        if let s = cli.secret { prefs.secret = s }
        loadControlsFromPrefs()
        applyMouseOptions()

        gLink.onState = { [weak self] st in
            DispatchQueue.main.async {
                if st != .connected { gFwd.forwarding = false }
                self?.refreshUI()
            }
        }
        gFwd.onChange = { [weak self] in self?.refreshUI() }

        requestPermissionsOnce()
        if !gFwd.installTap() { say("Waiting for Accessibility / Input Monitoring permission ...") }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }

        refreshUI()
        showWindow()
        let canConnect = !prefs.host.isEmpty && !prefs.secret.isEmpty
        if canConnect && ((cli.host != nil && cli.secret != nil) || prefs.autoConnect) { connectNow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        gFwd.forwarding = false  // gives the Mac cursor back
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
        refreshUI()
    }

    // MARK: building the UI

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit MacKeyBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // An Edit menu makes Cmd+C / Cmd+V work in the text fields (e.g. to paste the secret).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menuStateItem = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
        menu.addItem(menuStateItem)
        menu.addItem(NSMenuItem.separator())
        let show = NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menuToggleItem = NSMenuItem(title: "Start forwarding", action: #selector(forwardClicked), keyEquivalent: "")
        menuToggleItem.target = self
        menu.addItem(menuToggleItem)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit MacKeyBridge", action: #selector(quitClicked), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func buildWindow() {
        let W: CGFloat = 468

        hostField = NSTextField(frame: .zero)
        hostField.placeholderString = "e.g. 192.168.0.10"
        hostField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        portField = NSTextField(frame: .zero)
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        secretField = NSSecureTextField(frame: .zero)
        secretField.placeholderString = "secret from the Windows settings"
        secretField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        connectButton = NSButton(title: "Connect", target: self, action: #selector(connectClicked))
        statusLabel = makeLabel("● Not connected")

        forwardButton = NSButton(title: "Start forwarding", target: self, action: #selector(forwardClicked))
        forwardHint = makeNote("", width: W)

        mouseCheck = NSButton(checkboxWithTitle: "Forward trackpad / mouse too", target: self, action: #selector(optionsChanged))
        pointerSlider = NSSlider(value: 1.0, minValue: 0.3, maxValue: 3.0, target: self, action: #selector(optionsChanged))
        pointerSlider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        pointerValue = makeLabel("1.0x", width: 44)
        scrollSlider = NSSlider(value: 1.0, minValue: 0.3, maxValue: 3.0, target: self, action: #selector(optionsChanged))
        scrollSlider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        scrollValue = makeLabel("1.0x", width: 44)
        invertVCheck = NSButton(checkboxWithTitle: "Invert vertical scroll", target: self, action: #selector(optionsChanged))
        invertHCheck = NSButton(checkboxWithTitle: "Invert horizontal scroll", target: self, action: #selector(optionsChanged))

        axLabel = makeLabel("Accessibility: ?", width: 230)
        imLabel = makeLabel("Input Monitoring: ?", width: 230)
        let axButton = NSButton(title: "Open settings...", target: self, action: #selector(openAX))
        let imButton = NSButton(title: "Open settings...", target: self, action: #selector(openIM))
        let lnButton = NSButton(title: "Open settings...", target: self, action: #selector(openLN))
        autoCheck = NSButton(checkboxWithTitle: "Connect automatically when the app starts", target: self, action: #selector(optionsChanged))

<<<<<<< HEAD
=======
        hotkeyLabel = makeLabel("", width: 90)
        hotkeyButton = NSButton(title: "Change...", target: self, action: #selector(changeHotkeyClicked))
        hotkeyResetButton = NSButton(title: "Reset", target: self, action: #selector(resetHotkeyClicked))

        navCheck = NSButton(checkboxWithTitle: "Two-finger horizontal swipe = previous / next slide or page", target: self, action: #selector(optionsChanged))
        swipeSlider = NSSlider(value: 80, minValue: 30, maxValue: 300, target: self, action: #selector(optionsChanged))
        swipeSlider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        swipeValue = makeLabel("80", width: 44)
        swipeKeysPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        swipeKeysPopup.addItems(withTitles: ["Left / Right arrow", "Page Up / Page Down", "Mouse side buttons (Back / Forward)"])
        swipeKeysPopup.target = self
        swipeKeysPopup.action = #selector(optionsChanged)
        swipeReverseCheck = NSButton(checkboxWithTitle: "Reverse swipe direction", target: self, action: #selector(optionsChanged))

>>>>>>> fe5b228 (Add mouse side-button swipe navigation)
        let scroll = NSTextView.scrollableTextView()
        logView = scroll.documentView as? NSTextView
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        scroll.widthAnchor.constraint(equalToConstant: W).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true

        var views: [NSView] = []
        views.append(makeLabel("Windows PC", bold: true))
        views.append(makeRow([makeLabel("Address", width: 70), hostField]))
        views.append(makeRow([makeLabel("Port", width: 70), portField]))
        views.append(makeRow([makeLabel("Secret", width: 70), secretField]))
        views.append(makeRow([connectButton, statusLabel]))
        views.append(makeSeparator(width: W))
        views.append(makeLabel("Keyboard & trackpad", bold: true))
        views.append(forwardButton)
        views.append(forwardHint)
        views.append(mouseCheck)
        views.append(makeRow([makeLabel("Pointer speed", width: 100), pointerSlider, pointerValue]))
        views.append(makeRow([makeLabel("Scroll speed", width: 100), scrollSlider, scrollValue]))
        views.append(makeRow([invertVCheck, invertHCheck]))
        views.append(makeSeparator(width: W))
        views.append(makeLabel("Permissions", bold: true))
        views.append(makeRow([axLabel, axButton]))
        views.append(makeRow([imLabel, imButton]))
        views.append(makeRow([makeLabel("Local Network (needed to reach the PC)", width: 230), lnButton]))
        views.append(autoCheck)
        views.append(scroll)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 640))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "MacKeyBridge"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 500, height: stack.fittingSize.height + 32))
        window.center()
    }

    // MARK: preferences <-> controls

    func loadControlsFromPrefs() {
        hostField.stringValue = prefs.host
        portField.stringValue = String(prefs.port)
        secretField.stringValue = prefs.secret
        mouseCheck.state = prefs.forwardMouse ? .on : .off
        pointerSlider.doubleValue = prefs.pointerSpeed
        scrollSlider.doubleValue = prefs.scrollSpeed
        invertVCheck.state = prefs.invertV ? .on : .off
        invertHCheck.state = prefs.invertH ? .on : .off
        autoCheck.state = prefs.autoConnect ? .on : .off
<<<<<<< HEAD
=======
        navCheck.state = prefs.swipeNav ? .on : .off
        swipeSlider.doubleValue = prefs.swipeThreshold
        swipeKeysPopup.selectItem(at: min(max(prefs.swipeKeys, 0), 2))
        swipeReverseCheck.state = prefs.swipeReverse ? .on : .off
>>>>>>> fe5b228 (Add mouse side-button swipe navigation)
    }

    func applyMouseOptions() {
        gFwd.mouse = MouseOptions(enabled: prefs.forwardMouse, pointerSpeed: prefs.pointerSpeed,
                                  scrollSpeed: prefs.scrollSpeed, invertV: prefs.invertV, invertH: prefs.invertH)
<<<<<<< HEAD
=======
        gFwd.nav = NavOptions(enabled: prefs.swipeNav, threshold: prefs.swipeThreshold,
                              output: min(max(prefs.swipeKeys, 0), 2), reverse: prefs.swipeReverse)
>>>>>>> fe5b228 (Add mouse side-button swipe navigation)
        gFwd.updateMouseCapture()
    }

    @objc func optionsChanged() {
        prefs.forwardMouse = mouseCheck.state == .on
        prefs.pointerSpeed = pointerSlider.doubleValue
        prefs.scrollSpeed = scrollSlider.doubleValue
        prefs.invertV = invertVCheck.state == .on
        prefs.invertH = invertHCheck.state == .on
        prefs.autoConnect = autoCheck.state == .on
<<<<<<< HEAD
=======
        prefs.swipeNav = navCheck.state == .on
        prefs.swipeThreshold = swipeSlider.doubleValue
        prefs.swipeKeys = min(max(swipeKeysPopup.indexOfSelectedItem, 0), 2)
        prefs.swipeReverse = swipeReverseCheck.state == .on
>>>>>>> fe5b228 (Add mouse side-button swipe navigation)
        applyMouseOptions()
        refreshUI()
    }

    // MARK: actions

    @objc func connectClicked() {
        if gLink.isWanted {
            gLink.disconnect()
            gFwd.forwarding = false
            refreshUI()
        } else {
            connectNow()
        }
    }

    func connectNow() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let secret = secretField.stringValue.trimmingCharacters(in: .whitespaces)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !secret.isEmpty, let port = UInt16(portText), port > 0 else {
            inputError = "Fill in address, port (1-65535) and secret"
            refreshUI()
            return
        }
        inputError = nil
        prefs.host = host
        prefs.port = Int(port)
        prefs.secret = secret
        gLink.connect(host: host, port: port, secret: Data(secret.utf8))
        refreshUI()
    }

    @objc func forwardClicked() { gFwd.toggle() }

    func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openAX() { openPane("Privacy_Accessibility") }
    @objc func openIM() { openPane("Privacy_ListenEvent") }
    @objc func openLN() { openPane("Privacy_LocalNetwork") }

    func requestPermissionsOnce() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }

    // MARK: refreshing

    func appendLog(_ line: String) {
        guard let tv = logView else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        tv.textStorage?.append(NSAttributedString(string: line + "\n", attributes: attrs))
        if let ts = tv.textStorage, ts.length > 20000 { ts.deleteCharacters(in: NSRange(location: 0, length: 10000)) }
        tv.scrollToEndOfDocument(nil)
    }

    func refreshUI() {
        guard window != nil else { return }
        let st = gLink.currentState
        let fwd = gFwd.forwarding

        switch st {
        case .idle:
            if let e = inputError {
                statusLabel.stringValue = "● " + e
                statusLabel.textColor = NSColor.systemRed
            } else {
                statusLabel.stringValue = "● Not connected"
                statusLabel.textColor = NSColor.secondaryLabelColor
            }
        case .connecting:
            statusLabel.stringValue = "● Connecting..."
            statusLabel.textColor = NSColor.systemOrange
        case .connected:
            statusLabel.stringValue = "● Connected"
            statusLabel.textColor = NSColor.systemGreen
        case .failed(let msg):
            statusLabel.stringValue = "● " + msg
            statusLabel.textColor = NSColor.systemRed
        }
        connectButton.title = gLink.isWanted ? "Disconnect" : "Connect"

        forwardButton.isEnabled = (st == .connected) && gFwd.tapInstalled
        forwardButton.title = fwd ? "Stop forwarding  (⌃⌥⌘W)" : "Start forwarding  (⌃⌥⌘W)"
        if !gFwd.tapInstalled {
            forwardHint.stringValue = "Grant Accessibility and Input Monitoring below. Forwarding becomes available automatically."
        } else if fwd {
            forwardHint.stringValue = "The Mac keyboard and trackpad now control the Windows PC. Press Control+Option+Command+W to get them back on this Mac (clicking here will not work while the trackpad is forwarded)."
        } else {
            forwardHint.stringValue = "Press Control+Option+Command+W from any app to start or stop forwarding."
        }

        pointerValue.stringValue = String(format: "%.1fx", pointerSlider.doubleValue)
        scrollValue.stringValue = String(format: "%.1fx", scrollSlider.doubleValue)
        let mouseOn = mouseCheck.state == .on
        pointerSlider.isEnabled = mouseOn
        scrollSlider.isEnabled = mouseOn
        invertVCheck.isEnabled = mouseOn
        invertHCheck.isEnabled = mouseOn

        let ax = AXIsProcessTrusted()
        let im = CGPreflightListenEventAccess()
        axLabel.stringValue = "Accessibility: " + (ax ? "✓ granted" : "✗ not granted")
        axLabel.textColor = ax ? NSColor.systemGreen : NSColor.systemRed
        imLabel.stringValue = "Input Monitoring: " + (im ? "✓ granted" : "✗ not granted")
        imLabel.textColor = im ? NSColor.systemGreen : NSColor.systemRed

        statusItem.button?.title = fwd ? "⌨ → PC" : (st == .connected ? "⌨ PC ✓" : "⌨ PC ✗")
        menuStateItem.title = st == .connected ? "Connected to Windows" : "Not connected"
        menuToggleItem.title = fwd ? "Stop forwarding (⌃⌥⌘W)" : "Start forwarding (⌃⌥⌘W)"
        menuToggleItem.isEnabled = forwardButton.isEnabled
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
// Never leave the Mac cursor frozen if we are killed from the terminal.
signal(SIGINT) { _ in
    CGAssociateMouseAndMouseCursorPosition(1)
    exit(0)
}
signal(SIGTERM) { _ in
    CGAssociateMouseAndMouseCursorPosition(1)
    exit(0)
}

gLink = Link()
gFwd = Forwarder(link: gLink)
gApp = AppController()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = gApp
app.run()