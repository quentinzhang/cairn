import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

/// The three sizes the desktop control comes in.
///
/// Three steps, not a slider. The control is one small object on a desktop,
/// and the only question anyone actually has about it is how much room it is
/// allowed to take — quieter than default, default, or easier to hit. A size
/// is a single multiplier so that everything the control draws stays derived
/// from one set of tuned numbers.
///
/// Small stops at 0.78 because that is where the control's body still clears
/// the 44pt target macOS asks a pointer to find. Smaller than that is not a
/// discreet control, it is a missed click.
enum CairnControlSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case regular
    case large

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: 0.78
        case .regular: 1
        case .large: 1.34
        }
    }

    var displayName: String {
        switch self {
        case .small: L10n.string("settings.control_size.small")
        case .regular: L10n.string("settings.control_size.regular")
        case .large: L10n.string("settings.control_size.large")
        }
    }
}

/// The third line a settings row grows when there is something to say.
///
/// A reason rather than a sentence. A note is written once and can sit on the
/// screen for as long as the window is open — including across a change of
/// language — so what is remembered is *what happened*, and the wording is
/// resolved at the moment it is drawn.
enum SettingsNote: String, CaseIterable, Sendable, Equatable {
    case loginItemNeedsApproval
    case loginItemRefused
    case shortcutHint
    case shortcutUnavailable

    var text: String {
        switch self {
        case .loginItemNeedsApproval: L10n.string("settings.launch_at_login.approval")
        case .loginItemRefused: L10n.string("settings.launch_at_login.failed")
        case .shortcutHint: L10n.string("settings.shortcut.hint")
        case .shortcutUnavailable: L10n.string("settings.shortcut.unavailable")
        }
    }
}

/// Whether macOS opens Cairn at login, as the app is allowed to see it.
///
/// `needsApproval` is its own state because it is the one outcome that looks
/// like a failure and is not: the registration went through, and macOS is
/// waiting for the user to confirm it in Login Items.
enum LoginItemState: Sendable {
    case enabled
    case disabled
    case needsApproval
}

@MainActor
protocol LoginItem {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
}

/// The real login item, registered under the app's own bundle identifier.
struct SystemLoginItem: LoginItem {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        default: .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            // Unregistering something macOS never registered is not a failure
            // worth reporting — the user asked for off and off is what they
            // already have.
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}

/// The preferences that are not about any one agent: how Cairn starts, how
/// large it sits on the desktop, and which language it speaks.
///
/// Connecting agents and granting access keep their own windows — they are
/// tasks with state of their own, not switches — so Settings links to them
/// rather than absorbing them.
@MainActor
final class CairnSettings: ObservableObject {
    static let shared = CairnSettings()

    @Published private(set) var controlSize: CairnControlSize
    /// Whether the stone mark stands in the menu bar. Turning it off is safe
    /// because the desktop control's own menu carries the same doors — the
    /// app never becomes unreachable.
    @Published private(set) var showsMenuBarIcon: Bool
    @Published private(set) var opensAtLogin: Bool
    /// Whether notes from one agent working in one project arrive as a single
    /// stack. On by default: a queue is easiest to read when one turn is one
    /// row, and a project that answers ten times is still one thing happening.
    @Published private(set) var stacksNotes: Bool
    /// What macOS said about the last login-item change, when it said anything
    /// at all. Nil is the normal state.
    @Published private(set) var loginItemNote: SettingsNote?
    /// The combination that shows and hides the notes from anywhere.
    @Published private(set) var notesShortcut: CairnShortcut
    /// Set when the system would not hand over the keys — which always means
    /// another app claimed them first, and always means the answer is to
    /// record different ones.
    @Published private(set) var shortcutNote: SettingsNote?

    private let defaults: UserDefaults
    private let loginItem: LoginItem
    private var window: NSWindow?

    enum PreferenceKey {
        static let controlSize = "cairn.control.size"
        static let showsMenuBarIcon = "cairn.menuBar.showsIcon"
        static let stacksNotes = "cairn.notes.stacked"
        static let shortcutKey = "cairn.shortcut.toggleNotes.key"
        static let shortcutModifiers = "cairn.shortcut.toggleNotes.modifiers"
        /// What the key printed when it was recorded — the layout's own answer,
        /// kept so the row still says the right key after a relaunch.
        static let shortcutName = "cairn.shortcut.toggleNotes.name"
    }

    init(
        defaults: UserDefaults = .standard,
        loginItem: LoginItem = SystemLoginItem()
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        controlSize = Self.savedControlSize(in: defaults)
        showsMenuBarIcon = defaults.object(forKey: PreferenceKey.showsMenuBarIcon) == nil
            ? true
            : defaults.bool(forKey: PreferenceKey.showsMenuBarIcon)
        opensAtLogin = loginItem.state != .disabled
        stacksNotes = defaults.object(forKey: PreferenceKey.stacksNotes) == nil
            ? true
            : defaults.bool(forKey: PreferenceKey.stacksNotes)
        notesShortcut = Self.savedShortcut(in: defaults)
    }

    nonisolated static func savedControlSize(in defaults: UserDefaults) -> CairnControlSize {
        guard let rawValue = defaults.string(forKey: PreferenceKey.controlSize),
              let size = CairnControlSize(rawValue: rawValue) else {
            return .regular
        }
        return size
    }

    func select(_ size: CairnControlSize) {
        defaults.set(size.rawValue, forKey: PreferenceKey.controlSize)
        guard controlSize != size else { return }

        controlSize = size
        NotificationCenter.default.post(name: .cairnControlSizeDidChange, object: size)
    }

    /// The stored combination, or the one Cairn ships with.
    ///
    /// A stored pair that no longer makes a shortcut — a modifier dropped, a
    /// key this keyboard has no character for — falls back rather than leaving
    /// the app with no way in from the keyboard at all.
    nonisolated static func savedShortcut(in defaults: UserDefaults) -> CairnShortcut {
        guard defaults.object(forKey: PreferenceKey.shortcutKey) != nil else {
            return .toggleNotes
        }
        let keyCode = UInt32(max(0, defaults.integer(forKey: PreferenceKey.shortcutKey)))
        let modifiers = NSEvent.ModifierFlags(
            rawValue: UInt(max(0, defaults.integer(forKey: PreferenceKey.shortcutModifiers)))
        )
        return CairnShortcut(
            keyCode: keyCode,
            cocoaModifiers: modifiers,
            typed: defaults.string(forKey: PreferenceKey.shortcutName)
        ) ?? .toggleNotes
    }

    func setNotesShortcut(_ shortcut: CairnShortcut) {
        defaults.set(Int(shortcut.keyCode), forKey: PreferenceKey.shortcutKey)
        defaults.set(
            Int(shortcut.cocoaModifiers.rawValue),
            forKey: PreferenceKey.shortcutModifiers
        )
        defaults.set(shortcut.keyName, forKey: PreferenceKey.shortcutName)
        guard notesShortcut != shortcut else { return }

        notesShortcut = shortcut
        shortcutNote = nil
        NotificationCenter.default.post(
            name: .cairnNotesShortcutDidChange,
            object: shortcut
        )
    }

    /// Back to ⌃⌥⌘C — the combination the docs teach, and the one that is
    /// still right when a recorded experiment turns out not to be.
    func resetNotesShortcut() {
        defaults.removeObject(forKey: PreferenceKey.shortcutKey)
        defaults.removeObject(forKey: PreferenceKey.shortcutModifiers)
        defaults.removeObject(forKey: PreferenceKey.shortcutName)
        guard notesShortcut != .toggleNotes else {
            shortcutNote = nil
            return
        }

        notesShortcut = .toggleNotes
        shortcutNote = nil
        NotificationCenter.default.post(
            name: .cairnNotesShortcutDidChange,
            object: CairnShortcut.toggleNotes
        )
    }

    /// Whether the system actually handed the keys over. Reported by whoever
    /// registers them, because refusal is only knowable at registration — and
    /// only worth saying next to the row that can change them.
    func recordShortcutRegistration(succeeded: Bool) {
        shortcutNote = succeeded ? nil : .shortcutUnavailable
    }

    /// The queue is drawn by SwiftUI but sized by AppKit, so the panel has to
    /// hear about this rather than only the view — an unstacked queue is taller
    /// than the window it was laid out in.
    func setStacksNotes(_ stacks: Bool) {
        defaults.set(stacks, forKey: PreferenceKey.stacksNotes)
        guard stacksNotes != stacks else { return }

        stacksNotes = stacks
        NotificationCenter.default.post(name: .cairnNoteStackingDidChange, object: stacks)
    }

    func setShowsMenuBarIcon(_ shows: Bool) {
        defaults.set(shows, forKey: PreferenceKey.showsMenuBarIcon)
        guard showsMenuBarIcon != shows else { return }
        showsMenuBarIcon = shows
    }

    /// Login Items is a system list the user can also edit behind Cairn's back,
    /// so the switch is read from macOS rather than remembered.
    func refreshLoginItem() {
        let state = loginItem.state
        opensAtLogin = state != .disabled
        loginItemNote = state == .needsApproval ? .loginItemNeedsApproval : nil
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            refreshLoginItem()
        } catch {
            // The switch snaps back to what macOS actually holds: a toggle that
            // stays on after the system refused it is a lie the user acts on.
            opensAtLogin = loginItem.state != .disabled
            loginItemNote = .loginItemRefused
        }
    }

    /// Login Items lives in System Settings, and an approval Cairn cannot grant
    /// itself is only actionable there.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Window

    func presentWindow() {
        refreshLoginItem()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // No title bar of its own: the window opens with the mark and the
        // product's name already at the top, and a chrome title above them
        // would say it a second time in a smaller font. Only the close button
        // stays — the sheet is a fixed size, so zoom would do nothing, and
        // minimising a window you opened for one switch is a way to lose it.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Cairn.Metrics.settingsWindow),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("settings.window.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // The title bar is gone, so the window is dragged by its own ground.
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: CairnSettingsView(
                settings: self,
                languageSettings: .shared,
                connections: .shared,
                close: { [weak window] in window?.performClose(nil) }
            )
        )
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    /// The desktop control changed size. The presenter answers by resizing its
    /// panel around the same centre, so the stones stay where they were put.
    static let cairnControlSizeDidChange = Notification.Name("app.cairn.controlSizeDidChange")
    /// The notes shortcut changed. Whoever holds the old registration hands it
    /// back and claims the new keys.
    static let cairnNotesShortcutDidChange = Notification.Name("app.cairn.notesShortcutDidChange")
    /// Notes started or stopped stacking. The presenter answers by measuring
    /// the queue again, because the same notes now occupy a different height.
    static let cairnNoteStackingDidChange = Notification.Name("app.cairn.noteStackingDidChange")
}


// MARK: - Window

/// Settings, as one sheet: the product's own face at the top, the switches
/// grouped under it, and a single way out at the bottom.
///
/// The mark is there because this is the only window that is about Cairn
/// rather than about a note — and because a preferences window that opens with
/// its own icon tells you which app you are changing before you read a word.
private struct CairnSettingsView: View {
    @ObservedObject var settings: CairnSettings
    @ObservedObject var languageSettings: LanguageSettings
    @ObservedObject var connections: AgentConnectionCenter
    var close: () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    @State private var isRecordingShortcut = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Cairn.Space.xl) {
                    header
                    preferences
                    doors
                }
                .padding(.horizontal, Cairn.Space.xxl)
                .padding(.bottom, Cairn.Space.xxl)
            }

            footer
        }
        .frame(
            width: Cairn.Metrics.settingsWindow.width,
            height: Cairn.Metrics.settingsWindow.height
        )
        .background(Cairn.Surface.windowGround(scheme))
    }

    /// The mark and the name, centred — the one part of the window that is not
    /// a row.
    ///
    /// Nothing else: a line describing what the window is for is a line nobody
    /// reads twice, and the build number belongs where it is actionable, which
    /// is the menu that offers to check for a newer one.
    private var header: some View {
        VStack(spacing: Cairn.Space.xs) {
            CairnMark(isExpanded: true, scale: Cairn.Metrics.settingsMarkScale)

            Text(verbatim: "Cairn")
                .font(.title.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        // Clear of the close button, which now floats over the content.
        .padding(.top, Cairn.Space.xxl)
        .padding(.bottom, Cairn.Space.sm)
    }

    /// The switches: everything answered once and then forgotten.
    private var preferences: some View {
        SettingsSection(title: L10n.string("settings.section.preferences")) {
            SettingsRow(
                title: L10n.string("settings.launch_at_login"),
                detail: L10n.string("settings.launch_at_login.detail"),
                note: settings.loginItemNote
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { settings.opensAtLogin },
                        set: { settings.setOpensAtLogin($0) }
                    )
                )
                .toggleStyle(.switch)
                .tint(Cairn.Brand.jade)
                .labelsHidden()
                .accessibilityLabel(L10n.string("settings.launch_at_login"))
            }

            if settings.loginItemNote != nil {
                Button(L10n.string("settings.launch_at_login.open")) {
                    settings.openLoginItemsSettings()
                }
                .buttonStyle(.link)
                .font(Cairn.Typo.meta)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Cairn.Space.sm)
            }

            CardDivider()

            SettingsRow(
                title: L10n.string("settings.menu_bar_icon"),
                detail: L10n.string("settings.menu_bar_icon.detail")
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { settings.showsMenuBarIcon },
                        set: { settings.setShowsMenuBarIcon($0) }
                    )
                )
                .toggleStyle(.switch)
                .tint(Cairn.Brand.jade)
                .labelsHidden()
                .accessibilityLabel(L10n.string("settings.menu_bar_icon"))
            }

            CardDivider()

            SettingsRow(
                title: L10n.string("settings.control_size"),
                detail: L10n.string("settings.control_size.detail")
            ) {
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.controlSize },
                        set: { settings.select($0) }
                    )
                ) {
                    ForEach(CairnControlSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Cairn.Brand.jade)
                .labelsHidden()
                .id(languageSettings.selection)
                .fixedSize()
                .accessibilityLabel(L10n.string("settings.control_size"))
            }

            CardDivider()

            SettingsRow(
                title: L10n.string("settings.stack_notes"),
                detail: L10n.string("settings.stack_notes.detail")
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { settings.stacksNotes },
                        set: { settings.setStacksNotes($0) }
                    )
                )
                .toggleStyle(.switch)
                .tint(Cairn.Brand.jade)
                .labelsHidden()
                .accessibilityLabel(L10n.string("settings.stack_notes"))
            }

            CardDivider()

            // The one row that takes a key press rather than a click. Its note
            // is whichever of the two things there is to say: how to record
            // while it is listening, and what the system said once it has.
            SettingsRow(
                title: L10n.string("settings.shortcut"),
                detail: L10n.string("settings.shortcut.detail"),
                note: isRecordingShortcut ? .shortcutHint : settings.shortcutNote
            ) {
                ShortcutRecorder(
                    shortcut: settings.notesShortcut,
                    isRecording: $isRecordingShortcut,
                    record: settings.setNotesShortcut,
                    reset: settings.resetNotesShortcut
                )
            }

            CardDivider()

            SettingsRow(
                title: L10n.string("language.menu"),
                detail: L10n.string("settings.language.detail")
            ) {
                Picker(
                    "",
                    selection: Binding(
                        get: { languageSettings.selection },
                        set: { languageSettings.select($0) }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L10n.string("language.menu"))
            }
        }
    }

    /// The two windows that are tasks rather than switches. They keep their own
    /// surfaces; Settings is only the door — so these rows are doors, chevron
    /// and all, rather than rows with a button parked on the right.
    private var doors: some View {
        SettingsSection(title: L10n.string("settings.section.setup")) {
            SettingsLinkRow(
                title: L10n.string("menu.connect"),
                detail: L10n.string("settings.apps.detail"),
                action: connections.presentWindow
            ) {
                // The marks answer "which" and the count answers "how many" —
                // the same pair, in the same order, as the menu bar's own row.
                HStack(spacing: Cairn.Space.sm) {
                    AgentGlyphStrip(
                        agents: connections.connectedAgents,
                        size: Cairn.Metrics.agentGlyphRow
                    )

                    Text(L10n.format("menu.connect_count", connections.connectedAgentCount))
                        .font(Cairn.Typo.meta.monospacedDigit())
                        .foregroundStyle(
                            connections.connectedAgentCount > 0
                                ? Cairn.Brand.jade
                                : Cairn.Ink.tertiary
                        )
                }
            }

            CardDivider()

            SettingsLinkRow(
                title: L10n.string("menu.access"),
                detail: L10n.string("settings.access.detail")
            ) {
                PermissionExperience.shared.presentCenter()
            }
        }
    }

    /// One way out, the width of the sheet. Settings saves as it goes — nothing
    /// here is pending — so the button is Done, not OK, and Escape and the
    /// close button do exactly the same thing.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)

            Button(action: close) {
                Text(L10n.string("settings.done"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Cairn.Brand.jade)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, Cairn.Space.xxl)
            .padding(.vertical, Cairn.Space.xl)
            .background {
                // Escape leaves too, which one button cannot say on its own —
                // a shortcut modifier replaces rather than adds. The second
                // button exists to hold the second key: behind the first, so
                // it can never take a click meant for Done, and drawing
                // nothing.
                Button("", action: close)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Rows

/// A titled band of rows, sitting on the window's ground as one card.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Cairn.Space.md) {
            Text(title)
                .font(Cairn.Typo.meta)
                .foregroundStyle(Cairn.Ink.tertiary)
                .textCase(.uppercase)
                .padding(.leading, Cairn.Space.xs)

            VStack(spacing: 0) { content }
                .padding(.horizontal, Cairn.Space.xl)
                .padding(.vertical, Cairn.Space.xs)
                .background(
                    Cairn.Surface.card(scheme),
                    in: RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)
                        .strokeBorder(Cairn.Stroke.card(scheme), lineWidth: Cairn.Stroke.width)
                }
        }
    }
}

/// The hairline between two rows of a card. Inset from neither edge — the card
/// already holds the inset, and a divider that stops short of it reads as a
/// second, narrower card.
private struct CardDivider: View {
    var body: some View {
        Divider().opacity(0.5)
    }
}

/// One setting on one line: what it is on the left, what you can do about it on
/// the right, and a third line only when there is something to say.
private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    var note: SettingsNote?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: Cairn.Space.lg) {
            SettingsRowLabel(title: title, detail: detail, note: note)

            Spacer(minLength: Cairn.Space.md)

            control
        }
        .padding(.vertical, Cairn.Space.md)
    }
}

/// A row that opens a window instead of changing a value. It reads as a door:
/// the whole row is the target, and the chevron says where it goes.
private struct SettingsLinkRow<Trailing: View>: View {
    let title: String
    let detail: String
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Cairn.Space.lg) {
                SettingsRowLabel(title: title, detail: detail)

                Spacer(minLength: Cairn.Space.md)

                trailing

                Image(systemName: "chevron.right")
                    .font(Cairn.Typo.meta.weight(.semibold))
                    .foregroundStyle(isHovering ? Cairn.Brand.jade : Cairn.Ink.tertiary)
            }
            .padding(.vertical, Cairn.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Cairn.Motion.hover) { isHovering = hovering }
        }
    }
}

extension SettingsLinkRow where Trailing == EmptyView {
    init(title: String, detail: String, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, action: action) { EmptyView() }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let detail: String
    var note: SettingsNote?

    var body: some View {
        VStack(alignment: .leading, spacing: Cairn.Space.xxs) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cairn.Ink.primary)
            Text(detail)
                .font(Cairn.Typo.meta)
                .foregroundStyle(Cairn.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note {
                Text(note.text)
                    .font(Cairn.Typo.micro)
                    .foregroundStyle(Cairn.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Recorder

/// The shortcut, and the way to change it: press the chip, then press the keys.
///
/// Recording is a local event monitor, not a text field. The combination Cairn
/// is after is one the *system* will answer to, so the only honest way to ask
/// for it is to take the keys exactly as they are pressed — including the ones
/// a text field would have swallowed — and hand every one of them back
/// unspent while it listens.
private struct ShortcutRecorder: View {
    let shortcut: CairnShortcut
    @Binding var isRecording: Bool
    let record: (CairnShortcut) -> Void
    let reset: () -> Void

    @State private var monitor: Any?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            if isRecording {
                stop()
            } else {
                start()
            }
        } label: {
            Text(isRecording ? L10n.string("settings.shortcut.recording") : shortcut.display)
                .font(.body.monospaced())
                .foregroundStyle(isRecording ? Cairn.Brand.jade : Cairn.Ink.secondary)
                .padding(.horizontal, Cairn.Space.lg)
                .padding(.vertical, Cairn.Space.sm)
                .frame(minWidth: 108)
                .background(
                    isRecording ? AnyShapeStyle(Cairn.Brand.jade.opacity(0.12)) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: Cairn.Radius.sm, style: .continuous)
                )
                .overlay {
                    // The chip is a button, and on a card the only thing that
                    // says so is its edge — so the edge is drawn against the
                    // card rather than borrowed from it.
                    RoundedRectangle(cornerRadius: Cairn.Radius.sm, style: .continuous)
                        .strokeBorder(
                            isRecording
                                ? Cairn.Brand.jade.opacity(0.6)
                                : Cairn.Ink.tertiary.opacity(isHovering ? 0.55 : 0.28),
                            lineWidth: Cairn.Stroke.controlWidth
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Cairn.Motion.hover) { isHovering = hovering }
        }
        .accessibilityLabel(L10n.string("settings.shortcut"))
        .accessibilityValue(shortcut.display)
        .onDisappear(perform: stop)
    }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            // Nothing typed while recording belongs to anything else on the
            // window — least of all Return, which would otherwise close it.
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(CairnShortcut.acceptedModifiers)

        // Bare keys are the two ways out rather than a combination: nothing
        // Cairn would register can be pressed without a modifier anyway.
        guard !modifiers.isDisjoint(with: CairnShortcut.requiredModifiers) else {
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                reset()
                stop()
            default:
                break
            }
            return
        }

        guard let combination = CairnShortcut(
            keyCode: UInt32(event.keyCode),
            cocoaModifiers: modifiers,
            typed: event.charactersIgnoringModifiers
        ) else {
            return
        }

        record(combination)
        stop()
    }
}
