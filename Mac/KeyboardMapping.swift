import Foundation

struct ShortcutMappingOptions: Equatable {
    var enabled = true
    var commandToControl = true
    var cmdShiftZToCtrlY = true
    var cmdTabToAltTab = true
}

enum WireKeyEvent: Equatable {
    case down(code: UInt16, repeat: Bool)
    case up(code: UInt16)
}

enum KeyEventPlan: Equatable {
    case events([WireKeyEvent])
    case leaveOnMac
}

private let mkModifierCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

private let mkLeftCommand: UInt16 = 55
private let mkRightCommand: UInt16 = 54
private let mkLeftControl: UInt16 = 59
private let mkRightControl: UInt16 = 62
private let mkLeftOption: UInt16 = 58
private let mkKeyZ: UInt16 = 6
private let mkKeyY: UInt16 = 16
private let mkKeyQ: UInt16 = 12
private let mkKeyTab: UInt16 = 48
private let mkKeySpace: UInt16 = 49
private let mkKeyEscape: UInt16 = 53

/// Translates physical Mac keys into the key codes that are put on the wire. The protocol itself is untouched:
/// the Windows side sees ordinary key-down / key-up packets, only with different key codes where a shortcut applies.
///
/// All state is main-thread only (the main event tap runs on the main thread). `physical` is the set of modifier
/// keys actually held by the user, so the result does not depend on the order in which modifiers were pressed.
final class KeyboardMapper {
    var options: ShortcutMappingOptions

    private var physical = Set<UInt16>()
    private var wireSources: [UInt16: Int] = [:]
    private var bindings: [UInt16: [UInt16]] = [:]
    private var consumed = Set<UInt16>()

    init(options: ShortcutMappingOptions = ShortcutMappingOptions()) {
        self.options = options
    }

    func reset() {
        physical.removeAll()
        wireSources.removeAll()
        bindings.removeAll()
        consumed.removeAll()
    }

    func isModifier(_ code: UInt16) -> Bool { mkModifierCodes.contains(code) }

    var commandHeld: Bool { physical.contains(mkLeftCommand) || physical.contains(mkRightCommand) }
    var shiftHeld: Bool { physical.contains(56) || physical.contains(60) }
    var optionHeld: Bool { physical.contains(mkLeftOption) || physical.contains(61) }
    var controlHeld: Bool { physical.contains(mkLeftControl) || physical.contains(mkRightControl) }

    func modifierDown(_ code: UInt16) -> [WireKeyEvent] {
        guard isModifier(code), physical.insert(code).inserted else { return [] }
        return press(wireCode(forModifier: code))
    }

    func modifierUp(_ code: UInt16) -> KeyEventPlan {
        guard isModifier(code), physical.remove(code) != nil else { return .leaveOnMac }
        return .events(lift(wireCode(forModifier: code)))
    }

    func keyDown(_ code: UInt16, isRepeat: Bool) -> KeyEventPlan {
        if options.enabled {
            let cmd = commandHeld
            let shift = shiftHeld
            let opt = optionHeld
            let ctrl = controlHeld

            if cmd && opt && code == mkKeyEscape { return .leaveOnMac }
            if cmd && code == mkKeySpace { return .leaveOnMac }
            if cmd && code == mkKeyQ { return .leaveOnMac }

            if cmd && options.cmdTabToAltTab && code == mkKeyTab {
                consumed.insert(code)
                return .events(cmdTabChord())
            }

            if cmd && shift && !opt && !ctrl && options.cmdShiftZToCtrlY && code == mkKeyZ {
                return bind(code, to: mkKeyY, isRepeat: isRepeat)
            }
        }
        return bind(code, to: code, isRepeat: isRepeat)
    }

    func keyUp(_ code: UInt16) -> KeyEventPlan {
        if consumed.remove(code) != nil { return .events([]) }
        guard let wires = bindings.removeValue(forKey: code) else { return .leaveOnMac }
        return .events(wires.reversed().flatMap { lift($0) })
    }

    /// Emits a key-up for every wire key we currently hold. Used when mapping is switched off while forwarding:
    /// the Mac keys themselves stay untouched, but Windows must not keep the translated modifiers pressed.
    func releaseAll() -> [WireKeyEvent] {
        var events: [WireKeyEvent] = []
        for code in wireSources.keys.sorted() {
            if wireSources[code, default: 0] > 0 { events.append(.up(code: code)) }
        }
        reset()
        return events
    }

    private func wireCode(forModifier code: UInt16) -> UInt16 {
        guard options.enabled && options.commandToControl else { return code }
        if code == mkLeftCommand { return mkLeftControl }
        if code == mkRightCommand { return mkRightControl }
        return code
    }

    private func bind(_ physicalCode: UInt16, to wire: UInt16, isRepeat: Bool) -> KeyEventPlan {
        if bindings[physicalCode] == nil {
            bindings[physicalCode] = [wire]
            return .events(press(wire))
        }
        if isRepeat { return .events([.down(code: wire, repeat: true)]) }
        return .events([])
    }

    private func press(_ code: UInt16) -> [WireKeyEvent] {
        let n = wireSources[code, default: 0]
        wireSources[code] = n + 1
        return n == 0 ? [.down(code: code, repeat: false)] : []
    }

    private func lift(_ code: UInt16) -> [WireKeyEvent] {
        let n = wireSources[code, default: 0]
        if n <= 1 {
            wireSources.removeValue(forKey: code)
            return [.up(code: code)]
        }
        wireSources[code] = n - 1
        return []
    }

    private func cmdTabChord() -> [WireKeyEvent] {
        var events: [WireKeyEvent] = []
        var lifted: [UInt16] = []
        for cmd in [mkLeftCommand, mkRightCommand] where physical.contains(cmd) {
            let wc = wireCode(forModifier: cmd)
            events.append(.up(code: wc))
            lifted.append(wc)
        }
        events.append(.down(code: mkLeftOption, repeat: false))
        events.append(.down(code: mkKeyTab, repeat: false))
        events.append(.up(code: mkKeyTab))
        events.append(.up(code: mkLeftOption))
        for wc in lifted { events.append(.down(code: wc, repeat: false)) }
        return events
    }
}
