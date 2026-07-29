import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Cairn

@MainActor
private final class StubLoginItem: LoginItem {
    var state: LoginItemState
    var failure: Error?
    private(set) var requests: [Bool] = []

    init(state: LoginItemState = .disabled) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if let failure { throw failure }
        state = enabled ? .enabled : .disabled
    }
}

private final class NotificationBox: @unchecked Sendable {
    var value: CairnControlSize?
}

private final class ShortcutBox: @unchecked Sendable {
    var value: CairnShortcut?
}

private final class StackingBox: @unchecked Sendable {
    var value: Bool?
}

private struct StubFailure: Error {}

@Test
@MainActor
func theDesktopControlOpensAtItsRestingSize() throws {
    let suiteName = "app.cairn.tests.settings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = CairnSettings(defaults: defaults, loginItem: StubLoginItem())
    #expect(settings.controlSize == .regular)
    #expect(CairnControlSize.regular.scale == 1)
    #expect(CairnControlSize.large.scale > CairnControlSize.regular.scale)
    #expect(CairnControlSize.small.scale < CairnControlSize.regular.scale)
    // Small is the quiet size, not the unusable one: the control's body still
    // has to be something a pointer can find.
    #expect(Cairn.Metrics.controlBody.width * CairnControlSize.small.scale >= 44)
    #expect(Cairn.Metrics.controlBody.height * CairnControlSize.small.scale >= 44)
}

@Test
@MainActor
func controlSizePersistsAndAnnouncesItself() throws {
    let suiteName = "app.cairn.tests.settings.size.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = CairnSettings(defaults: defaults, loginItem: StubLoginItem())
    let box = NotificationBox()
    let token = NotificationCenter.default.addObserver(
        forName: .cairnControlSizeDidChange,
        object: nil,
        queue: nil
    ) { notification in
        box.value = notification.object as? CairnControlSize
    }
    defer { NotificationCenter.default.removeObserver(token) }

    settings.select(.large)
    #expect(settings.controlSize == .large)
    // The panel resizes off this notification, so it has to carry the size.
    #expect(box.value == .large)
    #expect(
        CairnSettings(defaults: defaults, loginItem: StubLoginItem()).controlSize == .large
    )

    // A size Cairn no longer offers still has to open in something.
    defaults.set("enormous", forKey: CairnSettings.PreferenceKey.controlSize)
    #expect(CairnSettings.savedControlSize(in: defaults) == .regular)
}

/// A recorded combination has to survive a relaunch, and has to reach whoever
/// holds the registration — the old keys stay claimed until it does.
@Test
@MainActor
func theNotesShortcutIsRecordedKeptAndAnnounced() throws {
    let suiteName = "app.cairn.tests.settings.shortcut.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = CairnSettings(defaults: defaults, loginItem: StubLoginItem())
    #expect(settings.notesShortcut == .toggleNotes)

    let box = ShortcutBox()
    let token = NotificationCenter.default.addObserver(
        forName: .cairnNotesShortcutDidChange,
        object: nil,
        queue: nil
    ) { notification in
        box.value = notification.object as? CairnShortcut
    }
    defer { NotificationCenter.default.removeObserver(token) }

    let recorded = try #require(
        CairnShortcut(keyCode: UInt32(kVK_Space), cocoaModifiers: [.command, .option])
    )
    settings.setNotesShortcut(recorded)
    #expect(settings.notesShortcut == recorded)
    #expect(box.value == recorded)
    #expect(
        CairnSettings(defaults: defaults, loginItem: StubLoginItem()).notesShortcut == recorded
    )

    settings.resetNotesShortcut()
    #expect(settings.notesShortcut == .toggleNotes)
    #expect(box.value == .toggleNotes)
    #expect(
        CairnSettings(defaults: defaults, loginItem: StubLoginItem()).notesShortcut
            == .toggleNotes
    )
}

/// A stored pair that is no longer a shortcut — a modifier dropped, a key with
/// no name — has to fall back, not leave the app with no way in from the
/// keyboard at all.
@Test
@MainActor
func aStoredCombinationThatIsNoLongerOneFallsBack() throws {
    let suiteName = "app.cairn.tests.settings.shortcut.stored.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(Int(kVK_ANSI_J), forKey: CairnSettings.PreferenceKey.shortcutKey)
    defaults.set(0, forKey: CairnSettings.PreferenceKey.shortcutModifiers)
    #expect(CairnSettings.savedShortcut(in: defaults) == .toggleNotes)

    defaults.set(9999, forKey: CairnSettings.PreferenceKey.shortcutKey)
    defaults.set(
        Int(NSEvent.ModifierFlags.command.rawValue),
        forKey: CairnSettings.PreferenceKey.shortcutModifiers
    )
    #expect(CairnSettings.savedShortcut(in: defaults) == .toggleNotes)
}

/// Refusal is only knowable where the keys are claimed, and only actionable in
/// Settings — so the row that can change them is where it is said.
@Test
@MainActor
func refusedKeysAreReportedBesideTheRowThatChangesThem() throws {
    let suiteName = "app.cairn.tests.settings.shortcut.refused.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = CairnSettings(defaults: defaults, loginItem: StubLoginItem())
    #expect(settings.shortcutNote == nil)

    settings.recordShortcutRegistration(succeeded: false)
    #expect(settings.shortcutNote == .shortcutUnavailable)

    settings.recordShortcutRegistration(succeeded: true)
    #expect(settings.shortcutNote == nil)
}

/// The menu bar icon is on until someone says otherwise, and the answer has to
/// survive a relaunch — an icon that comes back every morning is not hidden.
@Test
@MainActor
func theMenuBarIconIsKeptUnlessItIsTurnedOff() throws {
    let suiteName = "app.cairn.tests.settings.menubar.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = CairnSettings(defaults: defaults, loginItem: StubLoginItem())
    #expect(settings.showsMenuBarIcon)

    settings.setShowsMenuBarIcon(false)
    #expect(!settings.showsMenuBarIcon)
    #expect(
        !CairnSettings(defaults: defaults, loginItem: StubLoginItem()).showsMenuBarIcon
    )

    settings.setShowsMenuBarIcon(true)
    #expect(CairnSettings(defaults: defaults, loginItem: StubLoginItem()).showsMenuBarIcon)
}

/// Stacking is how the queue reads by default, and the panel is sized by
/// AppKit — so the switch has to survive a relaunch and has to reach whoever
/// measures the window, not only the view that draws it.
@Test
@MainActor
func stackingIsOnUntilItIsTurnedOffAndSaysSoWhenItChanges() throws {
    let suiteName = "app.cairn.tests.settings.stacking.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = CairnSettings(defaults: defaults, loginItem: StubLoginItem())
    #expect(settings.stacksNotes)

    let box = StackingBox()
    let token = NotificationCenter.default.addObserver(
        forName: .cairnNoteStackingDidChange,
        object: nil,
        queue: nil
    ) { notification in
        box.value = notification.object as? Bool
    }
    defer { NotificationCenter.default.removeObserver(token) }

    settings.setStacksNotes(false)
    #expect(!settings.stacksNotes)
    #expect(box.value == false)
    #expect(
        !CairnSettings(defaults: defaults, loginItem: StubLoginItem()).stacksNotes
    )

    settings.setStacksNotes(true)
    #expect(box.value == true)
    #expect(CairnSettings(defaults: defaults, loginItem: StubLoginItem()).stacksNotes)
}

@Test
@MainActor
func openAtLoginFollowsWhatMacOSHolds() throws {
    let suiteName = "app.cairn.tests.settings.login.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let loginItem = StubLoginItem()
    let settings = CairnSettings(defaults: defaults, loginItem: loginItem)
    #expect(!settings.opensAtLogin)

    settings.setOpensAtLogin(true)
    #expect(loginItem.requests == [true])
    #expect(settings.opensAtLogin)
    #expect(settings.loginItemNote == nil)

    settings.setOpensAtLogin(false)
    #expect(loginItem.requests == [true, false])
    #expect(!settings.opensAtLogin)
}

/// A switch that stays on after the system refused it is a lie the user acts
/// on, so a refusal has to snap it back and say what happened.
@Test
@MainActor
func arefusedLoginItemSnapsBackAndExplains() throws {
    let suiteName = "app.cairn.tests.settings.refused.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let loginItem = StubLoginItem()
    loginItem.failure = StubFailure()
    let settings = CairnSettings(defaults: defaults, loginItem: loginItem)

    settings.setOpensAtLogin(true)
    #expect(!settings.opensAtLogin)
    #expect(settings.loginItemNote == .loginItemRefused)
}

/// Waiting for approval is the one outcome that looks like a failure and is
/// not: the registration went through, and Login Items has the last word.
@Test
@MainActor
func awaitingApprovalReadsAsOnWithSomethingToDo() throws {
    let suiteName = "app.cairn.tests.settings.approval.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let loginItem = StubLoginItem(state: .needsApproval)
    let settings = CairnSettings(defaults: defaults, loginItem: loginItem)
    #expect(settings.opensAtLogin)

    settings.refreshLoginItem()
    #expect(settings.opensAtLogin)
    #expect(settings.loginItemNote == .loginItemNeedsApproval)
}

/// A note is a reason, not a sentence: it is resolved as it is drawn, so a
/// window left open across a change of language re-words itself instead of
/// keeping the sentence it was written in.
@Test
func everySettingsNoteIsWordedWhenItIsDrawn() {
    for note in SettingsNote.allCases {
        #expect(!note.text.isEmpty)
        // A missing key comes back as itself.
        #expect(!note.text.hasPrefix("settings."), "\(note) is showing its key")
    }
}

@Test
func everySettingsStringIsTranslated() {
    let keys = [
        "menu.settings",
        "settings.window.title",
        "settings.section.preferences",
        "settings.section.setup",
        "settings.done",
        "settings.open",
        "settings.launch_at_login",
        "settings.launch_at_login.detail",
        "settings.launch_at_login.approval",
        "settings.launch_at_login.failed",
        "settings.launch_at_login.open",
        "settings.language.detail",
        "settings.menu_bar_icon",
        "settings.menu_bar_icon.detail",
        "settings.control_size",
        "settings.control_size.detail",
        "settings.control_size.small",
        "settings.control_size.regular",
        "settings.control_size.large",
        "settings.stack_notes",
        "settings.stack_notes.detail",
        "settings.shortcut",
        "settings.shortcut.detail",
        "settings.shortcut.recording",
        "settings.shortcut.hint",
        "settings.shortcut.unavailable",
        "settings.apps.detail",
        "settings.access.detail",
    ]

    for locale in L10n.supportedLocales {
        for key in keys {
            let value = L10n.string(key, localeIdentifier: locale)
            #expect(value != key, "\(locale) is missing \(key)")
        }
    }
}
