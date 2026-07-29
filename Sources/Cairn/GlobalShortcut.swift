import AppKit
import Carbon.HIToolbox

/// A combination Cairn answers to, wherever you are.
///
/// ⌃⌥⌘C is what it ships as, and what the docs teach: a global hotkey outranks
/// whatever the frontmost app wanted to do with those keys, so a combination
/// with fewer modifiers would quietly take something away — ⌥⌘C is Finder's
/// copy-as-pathname, and an app that steals it is an app you uninstall.
///
/// It is a default rather than a law, because the one thing a fixed shortcut
/// cannot survive is another app that got there first, or a keyboard where the
/// combination is already spoken for. What stays fixed is the shape: at least
/// one of ⌘ ⌥ ⌃ has to be held, so no setting Cairn offers can turn a letter
/// you type into a panel that opens.
struct CairnShortcut: Sendable, Equatable {
    let keyCode: UInt32
    let cocoaModifiers: NSEvent.ModifierFlags
    /// The key itself, written the way macOS writes it — "C", "␣", "F5".
    let keyName: String

    private init(keyCode: UInt32, cocoaModifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        self.cocoaModifiers = cocoaModifiers
        self.keyName = keyName
    }

    /// A combination recorded from a key press, or nil when it is not one
    /// Cairn will register: no modifier that makes it a shortcut rather than
    /// typing, or a key macOS has no name for.
    ///
    /// `typed` is what the key press itself said it types, when there is one.
    /// A key code is a position on the board rather than a letter — the key
    /// that says C on QWERTY says J on Dvorak — and the event is the only
    /// place that difference is knowable without asking HIToolbox, which is
    /// not a question Cairn can afford to ask on every menu redraw.
    init?(keyCode: UInt32, cocoaModifiers: NSEvent.ModifierFlags, typed: String? = nil) {
        let flags = cocoaModifiers.intersection(Self.acceptedModifiers)
        guard !flags.isDisjoint(with: Self.requiredModifiers),
              let keyName = KeyName.display(for: keyCode, typed: typed) else {
            return nil
        }
        self.init(keyCode: keyCode, cocoaModifiers: flags, keyName: keyName)
    }

    /// Shift alone does not make a shortcut — ⇧A is a capital A.
    static let requiredModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
    static let acceptedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// How the combination is written for a person: the glyphs macOS itself
    /// would draw, in the order macOS draws them.
    var display: String {
        var glyphs = ""
        if cocoaModifiers.contains(.control) { glyphs += "⌃" }
        if cocoaModifiers.contains(.option) { glyphs += "⌥" }
        if cocoaModifiers.contains(.shift) { glyphs += "⇧" }
        if cocoaModifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + keyName
    }

    /// The same combination as Carbon spells it, for the registration.
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if cocoaModifiers.contains(.control) { value |= UInt32(controlKey) }
        if cocoaModifiers.contains(.option) { value |= UInt32(optionKey) }
        if cocoaModifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if cocoaModifiers.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    /// The same combination as AppKit spells it, so a menu row can show the
    /// shortcut it duplicates. Empty for keys a menu cannot print, which costs
    /// the row its right-hand glyphs and nothing else.
    var keyEquivalent: String {
        if let equivalent = KeyName.menuEquivalent(for: keyCode) { return equivalent }
        guard keyName.count == 1,
              let scalar = keyName.unicodeScalars.first,
              scalar.isASCII,
              !CharacterSet.controlCharacters.contains(scalar) else {
            return ""
        }
        return keyName.lowercased()
    }

    /// Show or hide the notes — the combination Cairn ships with and the one
    /// it returns to.
    ///
    static let toggleNotes = CairnShortcut(
        keyCode: UInt32(kVK_ANSI_C),
        cocoaModifiers: [.control, .option, .command],
        keyName: "C"
    )
}

// MARK: - Key names

/// What a key code is called.
///
/// Two tables and one preference. A key that prints nothing has a glyph macOS
/// draws for it everywhere; a key that prints something is named by the key
/// press that recorded it, which is the layout's own answer; and the ANSI
/// table is what is left when there is no key press to ask — a shortcut
/// restored from disk, or the one Cairn ships with.
///
/// Deliberately not HIToolbox. `TISCopyCurrentASCIICapableKeyboardLayoutInputSource`
/// is the layout-correct answer and it aborts the process outright where there
/// is no input-source connection to read — which is every context that is not a
/// running app, the test bundle included. A name is not worth a crash.
enum KeyName {
    /// Keys that print nothing. Drawn as the glyph the system's own menus use,
    /// so a recorded shortcut reads the same in Cairn as everywhere else.
    private static let special: [Int: String] = [
        kVK_Return: "↩",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥",
        kVK_Space: "␣",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1",
        kVK_F2: "F2",
        kVK_F3: "F3",
        kVK_F4: "F4",
        kVK_F5: "F5",
        kVK_F6: "F6",
        kVK_F7: "F7",
        kVK_F8: "F8",
        kVK_F9: "F9",
        kVK_F10: "F10",
        kVK_F11: "F11",
        kVK_F12: "F12"
    ]

    /// What a menu item needs instead of a glyph.
    private static let menuEquivalents: [Int: String] = [
        kVK_Return: "\r",
        kVK_ANSI_KeypadEnter: "\u{3}",
        kVK_Tab: "\t",
        kVK_Space: " ",
        kVK_Delete: "\u{8}",
        kVK_ForwardDelete: "\u{7F}",
        kVK_Escape: "\u{1B}"
    ]

    /// The keys that print something, as they are labelled on an ANSI board.
    private static let ansi: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`"
    ]

    /// The name of a key, or nil when it is one Cairn will not accept — a
    /// modifier pressed on its own, or a key with nothing to show for it.
    static func display(for keyCode: UInt32, typed: String? = nil) -> String? {
        if let glyph = special[Int(keyCode)] { return glyph }
        if let typed = printable(typed) { return typed }
        return ansi[Int(keyCode)]
    }

    /// What a menu item needs in place of a glyph, for the keys that have one.
    static func menuEquivalent(for keyCode: UInt32) -> String? {
        menuEquivalents[Int(keyCode)]
    }

    /// What a key press said it types, when that is something a settings row
    /// can show. Control characters are what ⌃ with a letter reports, and they
    /// are neither printable nor the name of the key that was pressed.
    private static func printable(_ typed: String?) -> String? {
        guard let typed, typed.count == 1, let scalar = typed.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.illegalCharacters.contains(scalar) else {
            return nil
        }
        return typed.uppercased()
    }
}

// MARK: - Registration

/// Carbon tags every hotkey with the app that owns it. Cairn's own four bytes
/// keep the handler from acting on anyone else's.
private let cairnShortcutSignature = OSType(0x4341_524E) // 'CARN'

/// A key combination the whole Mac answers to, whichever app is in front.
///
/// This is Carbon's `RegisterEventHotKey` rather than an `NSEvent` monitor on
/// purpose: a global monitor needs Accessibility, and asking for permission to
/// watch every keystroke a person types — to toggle a panel — is a trade nobody
/// should have to make. A registered hotkey needs nothing.
@MainActor
final class GlobalShortcut {
    let combination: CairnShortcut

    private let action: () -> Void
    private let id: UInt32
    private var reference: EventHotKeyRef?

    /// The shortcuts currently registered, so the C handler — which is handed
    /// nothing but an id — can find the one that fired.
    private static var registered: [UInt32: GlobalShortcut] = [:]
    private static var nextID: UInt32 = 1
    /// One handler for the whole app, installed once and never removed.
    ///
    /// Not one per shortcut. Carbon identifies a handler by the triple of
    /// callback, user data and target, and refuses a second install of the
    /// same triple with `eventHandlerAlreadyInstalledErr` — which is exactly
    /// what a re-registration would ask for, since the callback is a C
    /// function with no captured state and the target is the application. A
    /// per-shortcut handler therefore worked once and then failed forever:
    /// the first recorded combination could not be claimed, and neither could
    /// the one it was changed back to.
    private static var handler: EventHandlerRef?

    init(_ combination: CairnShortcut, action: @escaping () -> Void) {
        self.combination = combination
        self.action = action
        id = Self.nextID
        Self.nextID += 1
    }

    /// Claims the combination from the system.
    ///
    /// Returns false when macOS refuses, which in practice means another app
    /// registered the same keys first. Settings says so beside the row — it is
    /// the one place the answer is actionable, because it is where the
    /// combination can be changed.
    @discardableResult
    func register() -> Bool {
        guard reference == nil else { return true }
        guard Self.installHandler() else { return false }

        var claimed: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.carbonModifiers,
            EventHotKeyID(signature: cairnShortcutSignature, id: id),
            GetApplicationEventTarget(),
            0,
            &claimed
        )
        guard status == noErr, let claimed else { return false }

        reference = claimed
        Self.registered[id] = self
        return true
    }

    /// Hands the combination back. A shortcut that has been changed has to let
    /// go of the old keys first, or the app keeps answering to both.
    func unregister() {
        guard let reference else { return }
        UnregisterEventHotKey(reference)
        self.reference = nil
        Self.registered[id] = nil
    }

    /// Installs the app's one hot-key handler, or confirms it is already
    /// there. Internal so a test can ask twice — asking twice is exactly what
    /// re-recording a shortcut does.
    static func installHandler() -> Bool {
        guard handler == nil else { return true }

        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }

                var firing = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firing
                )
                guard read == noErr, firing.signature == cairnShortcutSignature else {
                    return OSStatus(eventNotHandledErr)
                }

                let id = firing.id
                Task { @MainActor in GlobalShortcut.fire(id) }
                return noErr
            },
            1,
            &pressed,
            nil,
            &handler
        )
        return status == noErr
    }

    private static func fire(_ id: UInt32) {
        registered[id]?.action()
    }
}
