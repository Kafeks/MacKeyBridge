import Cocoa
import CoreGraphics
import CryptoKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

func say(_ s: String) { print("[mackeybridge] \(s)") }

// MARK: - Protocol constants

let protoVersion: UInt8 = 1
let pktChallenge: UInt8 = 0x01
let pktAuth: UInt8 = 0x02
let pktAuthOk: UInt8 = 0x03
let pktKeyDown: UInt8 = 0x10
let pktKeyUp: UInt8 = 0x11
let pktAllUp: UInt8 = 0x12
let pktPing: UInt8 = 0x13

let hotkeyCode: UInt16 = 13  // kVK_ANSI_W  -> Control+Option+Command+W toggles forwarding

// MARK: - Command line

struct Options {
    var host = ""
    var port: UInt16 = 47800
    var secret = ""
}

func usage() {
    print("""
    Usage: mackeybridge-client --host <windows-ip-or-name> [--port 47800] --secret <secret>

      --host     IP address or host name of the Windows PC (shown in the MacKeyBridge settings)
      --port     TCP port (default 47800)
      --secret   shared secret from the MacKeyBridge settings (or env MACKEYBRIDGE_SECRET)

    Toggle forwarding with Control+Option+Command+W or from the menu bar item.
    """)
}

func parseArgs() -> Options {
    var o = Options()
    let env = ProcessInfo.processInfo.environment
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--host": o.host = it.next() ?? ""
        case "--port": o.port = UInt16(it.next() ?? "") ?? 47800
        case "--secret": o.secret = it.next() ?? ""
        case "--help", "-h":
            usage()
            exit(0)
        default:
            fputs("Unknown argument: \(a)\n", stderr)
            usage()
            exit(2)
        }
    }
    if o.host.isEmpty, let e = env["MACKEYBRIDGE_HOST"] { o.host = e }
    if o.secret.isEmpty, let e = env["MACKEYBRIDGE_SECRET"] { o.secret = e }
    return o
}

// MARK: - TCP link (auto-reconnect, HMAC challenge-response, 1 s keep-alive pings)

final class Link {
    private let host: String
    private let port: UInt16
    private let secret: Data
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var isUp = false
    private let sendQ = DispatchQueue(label: "mackeybridge.send")
    var onState: ((Bool) -> Void)?

    init(host: String, port: UInt16, secret: Data) {
        self.host = host
        self.port = port
        self.secret = secret
    }

    var connected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isUp
    }

    func start() {
        let t = Thread { [self] in self.loop() }
        t.name = "mackeybridge.link"
        t.start()
    }

    /// Queue 4 bytes: [type][flags][code lo][code hi]. Order is preserved by the serial queue.
    func enqueue(_ bytes: [UInt8]) {
        sendQ.async { [self] in
            lock.lock()
            let s = fd
            let up = isUp
            lock.unlock()
            guard up, s >= 0 else { return }
            if !writeAll(s, bytes) { shutdown(s, SHUT_RDWR) }  // wakes the link loop, which reconnects
        }
    }

    private func loop() {
        var announcedWaiting = false
        while true {
            guard let s = openSocket() else {
                if !announcedWaiting {
                    say("Waiting for Windows server at \(host):\(port) ...")
                    announcedWaiting = true
                }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            if handshake(s) {
                announcedWaiting = false
                lock.lock()
                fd = s
                isUp = true
                lock.unlock()
                say("Connected to Windows at \(host):\(port)")
                onState?(true)

                var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
                while true {
                    let r = poll(&pfd, 1, 1000)
                    if r < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if r == 0 {  // idle for 1 s: keep-alive ping (the server drops us after 3 s of silence)
                        enqueue([pktPing, 0, 0, 0])
                        continue
                    }
                    var buf = [UInt8](repeating: 0, count: 64)
                    let n = recv(s, &buf, buf.count, 0)
                    if n <= 0 { break }  // closed or error
                }

                lock.lock()
                isUp = false
                fd = -1
                lock.unlock()
                say("Disconnected from Windows")
                onState?(false)
            } else {
                say("Authentication failed - check --secret (see MacKeyBridge settings on Windows)")
                Thread.sleep(forTimeInterval: 2)
            }
            close(s)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func openSocket() -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }

        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                let flags = fcntl(s, F_GETFL, 0)
                _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
                var ok = false
                let r = connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                if r == 0 {
                    ok = true
                } else if errno == EINPROGRESS {
                    var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 3000) > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                        ok = (err == 0)
                    }
                }
                if ok {
                    _ = fcntl(s, F_SETFL, flags)  // back to blocking
                    var one: Int32 = 1
                    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    return s
                }
                close(s)
            }
            p = ai.pointee.ai_next
        }
        return nil
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

    /// server: [0x01][nonce 16]   client: [0x02][version][HMAC-SHA256(secret, nonce)]   server: [0x03]
    private func handshake(_ s: Int32) -> Bool {
        guard let ch = readExact(s, 17, timeoutMs: 3000), ch[0] == pktChallenge else { return false }
        let nonce = Data(ch[1...16])
        let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: secret))
        var msg: [UInt8] = [pktAuth, protoVersion]
        msg.append(contentsOf: Array(mac))
        guard writeAll(s, msg) else { return false }
        guard let r = readExact(s, 1, timeoutMs: 3000), r[0] == pktAuthOk else { return false }
        return true
    }
}

// MARK: - Event tap

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

var gForwarder: Forwarder!

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    return gForwarder.handle(type: type, event: event)
}

final class Forwarder {
    let link: Link
    var forwarding = false
    var tap: CFMachPort?
    var onChange: (() -> Void)?

    init(link: Link) { self.link = link }

    func installTap() -> Bool {
        var mask: CGEventMask = 0
        for t in [CGEventType.keyDown, CGEventType.keyUp, CGEventType.flagsChanged] {
            mask |= CGEventMask(1) << CGEventMask(t.rawValue)
        }
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
            forwarding = true
            say("Forwarding ON: this keyboard now types on Windows")
        } else {
            forwarding = false
            link.enqueue([pktAllUp, 0, 0, 0])  // release anything still held on the PC
            say("Forwarding OFF: keyboard is back on this Mac")
        }
        onChange?()
    }

    private func send(_ type: UInt8, _ code: UInt16, repeatFlag: Bool = false) {
        link.enqueue([type, repeatFlag ? 1 : 0, UInt8(code & 0xFF), UInt8(code >> 8)])
    }

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

        // Safety: only swallow keys while the link is up, otherwise the Mac keeps working normally.
        guard forwarding, link.connected else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown, .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let rep = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            send(type == .keyDown ? pktKeyDown : pktKeyUp, code, repeatFlag: rep)
            return nil

        case .flagsChanged:
            // Modifier keys (and Fn / Globe = key code 63) arrive as flagsChanged with their own key code.
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let raw = event.flags.rawValue
            switch code {
            case 63:  // Fn / Globe
                let down = (raw & CGEventFlags.maskSecondaryFn.rawValue) != 0
                send(down ? pktKeyDown : pktKeyUp, code)
            case 57:  // Caps Lock reports state changes, not key presses: send one tap per event
                send(pktKeyDown, code)
                send(pktKeyUp, code)
            default:
                if let m = deviceMask[code] { send((raw & m) != 0 ? pktKeyDown : pktKeyUp, code) }
            }
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
        if isDown { send(pktKeyDown, UInt16(0x100 + keyType), repeatFlag: isRepeat) }
        return nil
    }
}

// MARK: - Menu bar item

var gUI: StatusUI!

final class StatusUI: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var toggleItem: NSMenuItem!
    var stateItem: NSMenuItem!

    override init() {
        super.init()
        let menu = NSMenu()
        stateItem = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
        menu.addItem(stateItem)
        toggleItem = NSMenuItem(title: "Forward keyboard to Windows", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        refresh()
    }

    @objc func toggle() { gForwarder.toggle() }
    @objc func quit() { NSApp.terminate(nil) }

    func refresh() {
        let connected = gForwarder.link.connected
        let fwd = gForwarder.forwarding
        item.button?.title = fwd ? "⌨ → PC" : (connected ? "⌨ PC ✓" : "⌨ PC ✗")
        stateItem.title = connected ? "Connected to Windows" : "Not connected (retrying...)"
        toggleItem.state = fwd ? .on : .off
        toggleItem.title = fwd ? "Stop forwarding (⌃⌥⌘W)" : "Forward keyboard to Windows (⌃⌥⌘W)"
    }
}

// MARK: - Main

let opts = parseArgs()
if opts.host.isEmpty || opts.secret.isEmpty {
    usage()
    exit(2)
}

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
if !trusted {
    say("Accessibility permission is required. Open System Settings > Privacy & Security > Accessibility")
    say("(and Input Monitoring), enable your terminal app (or this program), then start it again.")
}

let link = Link(host: opts.host, port: opts.port, secret: Data(opts.secret.utf8))
gForwarder = Forwarder(link: link)

if !gForwarder.installTap() {
    say("Cannot create the keyboard event tap. Grant Accessibility + Input Monitoring permission and restart.")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
gUI = StatusUI()
gForwarder.onChange = { gUI.refresh() }

link.onState = { up in
    DispatchQueue.main.async {
        if !up { gForwarder.forwarding = false }  // never resume swallowing keys by surprise after a reconnect
        gUI.refresh()
    }
}
link.start()

say("Started. Press Control+Option+Command+W (or use the menu bar item) to forward the keyboard to Windows.")
say("Tip: System Settings > Keyboard > 'Press 🌐 key to' = Do Nothing, so the Fn/Globe key is not handled by macOS.")
app.run()
