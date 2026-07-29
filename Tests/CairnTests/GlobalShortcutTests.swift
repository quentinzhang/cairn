import AppKit
import Carbon.HIToolbox
import Testing
@testable import Cairn

/// ⌃⌥⌘C is what Cairn ships with, what the docs teach, and what ⌫ in the
/// recorder goes back to — so it is pinned here rather than left to whoever
/// edits the struct next. Changing it is a decision that has to break a test
/// first.
@Test
func theNotesShortcutShipsAsTheTaughtCombination() {
    let shortcut = CairnShortcut.toggleNotes

    #expect(shortcut.keyCode == UInt32(kVK_ANSI_C))
    #expect(shortcut.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
    #expect(shortcut.cocoaModifiers == [.control, .option, .command])
    #expect(shortcut.display.hasPrefix("⌃⌥⌘"))
}

/// Carbon and AppKit spell the same keys differently, and the menu row prints
/// one while the system registers the other. They have to stay the same keys.
@Test
func theShortcutSpellsTheSameKeysToCarbonAndToAppKit() {
    let shortcut = CairnShortcut.toggleNotes

    #expect(shortcut.keyEquivalent == shortcut.keyName.lowercased())
    #expect(shortcut.carbonModifiers & UInt32(controlKey) != 0)
    #expect(shortcut.carbonModifiers & UInt32(optionKey) != 0)
    #expect(shortcut.carbonModifiers & UInt32(cmdKey) != 0)
    #expect(shortcut.carbonModifiers & UInt32(shiftKey) == 0)
}

/// The shape a recorded combination has to have. Without it, a preference
/// could turn a letter someone types into a panel that opens on top of them.
@Test
func aRecordedCombinationNeedsAModifierThatMakesItOne() {
    let bare = CairnShortcut(keyCode: UInt32(kVK_ANSI_J), cocoaModifiers: [])
    let shifted = CairnShortcut(keyCode: UInt32(kVK_ANSI_J), cocoaModifiers: [.shift])
    let held = CairnShortcut(keyCode: UInt32(kVK_ANSI_J), cocoaModifiers: [.command, .shift])

    #expect(bare == nil)
    // ⇧J is a capital J, not a shortcut.
    #expect(shifted == nil)
    #expect(held != nil)
    // Anything that is not a modifier Cairn registers is dropped, so two
    // recordings of the same keys are the same shortcut.
    #expect(
        CairnShortcut(
            keyCode: UInt32(kVK_ANSI_J),
            cocoaModifiers: [.command, .shift, .capsLock, .function]
        ) == held
    )
}

/// Keys with no character of their own still have to be recordable — and to
/// read as the glyph the rest of macOS draws for them.
@Test
func keysWithoutACharacterAreWrittenAsTheirGlyph() throws {
    let space = try #require(
        CairnShortcut(keyCode: UInt32(kVK_Space), cocoaModifiers: [.control, .option])
    )
    #expect(space.display == "⌃⌥␣")
    #expect(space.keyEquivalent == " ")

    let arrow = try #require(
        CairnShortcut(keyCode: UInt32(kVK_UpArrow), cocoaModifiers: [.command, .shift])
    )
    // Modifier glyphs in the order macOS draws them: ⌃⌥⇧⌘.
    #expect(arrow.display == "⇧⌘↑")
    // A menu cannot print this one, and prints nothing rather than a wrong key.
    #expect(arrow.keyEquivalent.isEmpty)
}

/// A key code is a position on the board, not a letter — but every position
/// Cairn accepts has to have a name to show, or the settings row would go
/// blank and the shortcut would be unreadable.
@Test
func everyAcceptedKeyHasSomethingToPrint() throws {
    let codes = [kVK_ANSI_A, kVK_ANSI_0, kVK_F5, kVK_Escape, kVK_Return, kVK_Delete]

    for code in codes {
        let name = try #require(KeyName.display(for: UInt32(code)), "no name for \(code)")
        #expect(!name.isEmpty)
    }
}

/// The handler belongs to the app, not to the shortcut.
///
/// Carbon identifies a handler by callback, user data and target, and refuses
/// a second install of the same three with `eventHandlerAlreadyInstalledErr`.
/// A per-shortcut handler therefore worked exactly once: the first recorded
/// combination could not be claimed, and neither could the default it was
/// changed back to — the app went deaf to its own shortcut until it was
/// relaunched. Asking twice has to be the same as asking once.
@Test
@MainActor
func theHotKeyHandlerIsInstalledOnceForTheWholeApp() {
    #expect(GlobalShortcut.installHandler())
    #expect(GlobalShortcut.installHandler())
    #expect(GlobalShortcut.installHandler())
}
