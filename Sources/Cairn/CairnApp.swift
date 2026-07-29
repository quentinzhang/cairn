import AppKit
import Combine
import Foundation
import SwiftUI

enum CairnBuildInfo {
    static var displayVersion: String {
        displayVersion(from: Bundle.main.infoDictionary ?? [:])
    }

    static func displayVersion(
        from info: [String: Any],
        localeIdentifier: String? = nil
    ) -> String {
        let unknown = localeIdentifier.map {
            L10n.string("common.unknown", localeIdentifier: $0)
        } ?? L10n.string("common.unknown")
        let version = info["CFBundleShortVersionString"] as? String ?? unknown
        let build = info["CFBundleVersion"] as? String ?? unknown
        if let localeIdentifier {
            return L10n.format(
                "build.version_format",
                localeIdentifier: localeIdentifier,
                arguments: [version, build]
            )
        }
        return L10n.format("build.version_format", version, build)
    }
}

@main
@MainActor
struct CairnApp: App {
    @NSApplicationDelegateAdaptor(CairnAppDelegate.self) private var appDelegate
    @StateObject private var languageSettings: LanguageSettings
    @StateObject private var store: CompletionStore
    @StateObject private var presenter: FloatingQueuePresenter
    @StateObject private var updateChecker: UpdateChecker
    @StateObject private var permissions: PermissionExperience
    @StateObject private var connections: AgentConnectionCenter
    @StateObject private var settings: CairnSettings

    init() {
        let languageSettings = LanguageSettings.shared
        _languageSettings = StateObject(wrappedValue: languageSettings)
        let settings = CairnSettings.shared
        _settings = StateObject(wrappedValue: settings)
        let store = CompletionStore()
        _store = StateObject(wrappedValue: store)
        _presenter = StateObject(
            wrappedValue: FloatingQueuePresenter(
                store: store,
                languageSettings: languageSettings,
                settings: settings
            )
        )
        let updateChecker = UpdateChecker()
        updateChecker.start()
        _updateChecker = StateObject(wrappedValue: updateChecker)
        _permissions = StateObject(wrappedValue: PermissionExperience.shared)
        _connections = StateObject(wrappedValue: AgentConnectionCenter.shared)
    }

    var body: some Scene {
        // Until onboarding finishes there is no menu bar icon: the connect
        // window is the whole app, and Start is what turns the rest on. After
        // that it is the user's to keep or hide — hidden, the desktop control's
        // own menu is the way back in.
        MenuBarExtra(isInserted: Binding(
            get: { connections.surfacesActive && settings.showsMenuBarIcon },
            set: { _ in }
        )) {
            MenuBarQueueView(
                store: store,
                updateChecker: updateChecker,
                permissions: permissions,
                connections: connections,
                languageSettings: languageSettings,
                settings: settings
            )
        } label: {
            Image(nsImage: CairnMenuBarIcon.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status-bar rendition of the stone mark: the same two stones and crown,
/// drawn monochrome as a template image so the system tints it for menu bar
/// appearance and highlight states.
///
/// The lit facet is deliberately dropped here. A template image is one colour,
/// so a highlight on the crown would only eat into the silhouette; at 16pt the
/// crown has to read as a solid stone or not at all.
@MainActor
enum CairnMenuBarIcon {
    static let shared: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let mark = Cairn.Mark.self
            let scale = min(
                rect.width / mark.viewBox.width,
                rect.height / mark.viewBox.height
            )
            let offset = CGPoint(
                x: rect.midX - mark.viewBox.width * scale / 2,
                y: rect.midY - mark.viewBox.height * scale / 2
            )

            func stone(_ stone: Cairn.Mark.Stone) {
                let center = CGPoint(
                    x: offset.x + stone.center.x * scale,
                    y: offset.y + stone.center.y * scale
                )
                let points = Cairn.Mark.outline(stone)
                guard let first = points.first else { return }

                let path = NSBezierPath()
                path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
                for point in points.dropFirst() {
                    path.line(to: CGPoint(x: point.x * scale, y: point.y * scale))
                }
                path.close()

                let transform = NSAffineTransform()
                transform.translateX(by: center.x, yBy: center.y)
                transform.rotate(byDegrees: stone.rotation)
                path.transform(using: transform as AffineTransform)
                path.fill()
            }

            NSColor.black.setFill()
            stone(mark.base)
            stone(mark.middle)
            stone(mark.crown)
            return true
        }
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class CairnAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PermissionExperience.shared.refresh()
        // The first launch goes straight to the one thing Cairn cannot work
        // without: connecting an agent. Access is an optional upgrade and
        // waits in the menu.
        AgentConnectionCenter.shared.start()
    }
}

struct CodexCompletion: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let version: Int
    let event: String
    let sessionID: String
    let turnID: String?
    let cwd: String
    let title: String
    let result: String
    let status: String
    let timestamp: Date
    let source: String?
    let userMessage: String?
    let model: String?
    let platform: String?
    let locator: CairnLocator?

    enum CodingKeys: String, CodingKey {
        case id, version, event, cwd, title, result, status, timestamp, source, model, platform, locator
        case sessionID = "session_id"
        case turnID = "turn_id"
        case userMessage = "user_message"
    }
}

enum CairnJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let timestamp = try container.decode(String.self)
            for options: ISO8601DateFormatter.Options in [
                [.withInternetDateTime, .withFractionalSeconds],
                [.withInternetDateTime],
            ] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: timestamp) {
                    return date
                }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 timestamp."
            )
        }
        return decoder
    }
}

/// The trail a hook captured at completion time: which terminal session and
/// which GUI app hosted the turn. `TrailFinder` replays it on click.
struct CairnLocator: Codable, Hashable, Sendable {
    let termProgram: String?
    let termSessionID: String?
    let itermSessionID: String?
    let tmuxPane: String?
    let tty: String?
    let hostAppPath: String?
    let hostAppPID: Int?
    let agentPID: Int?
    /// Every .app ancestor of the turn's process, innermost first. Layers can
    /// stack (Claude Code's headless harness bundle sits under the Claude
    /// desktop app); the resolver picks the first activatable one.
    let hostApps: [CairnHostApp]?
    /// For turns whose surface is a browser (OpenClaw webchat): the UI to
    /// reopen instead of any local window.
    let webURL: String?
    /// Optional producer-supplied browser hint. OpenClaw's public agent hook
    /// does not expose this today, so TrailFinder also learns the browser
    /// after a successful tab match and remembers it per web origin.
    let browserBundleID: String?

    enum CodingKeys: String, CodingKey {
        case termProgram = "term_program"
        case termSessionID = "term_session_id"
        case itermSessionID = "iterm_session_id"
        case tmuxPane = "tmux_pane"
        case tty
        case hostAppPath = "host_app_path"
        case hostAppPID = "host_app_pid"
        case agentPID = "agent_pid"
        case hostApps = "host_apps"
        case webURL = "web_url"
        case browserBundleID = "browser_bundle_id"
    }
}

struct CairnHostApp: Codable, Hashable, Sendable {
    let path: String?
    let pid: Int?
}

extension CodexCompletion {
    var normalizedSource: String {
        let explicit = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !explicit.isEmpty {
            return explicit
        }
        return event.split(separator: ".").first.map(String.init)?.lowercased() ?? "agent"
    }

    var sessionKey: String {
        "\(normalizedSource):\(sessionID)"
    }

    var identity: Cairn.Agent {
        .identity(for: normalizedSource)
    }

    var contextName: String {
        if ["hermes", "openclaw"].contains(normalizedSource), let platform, !platform.isEmpty {
            return platform.capitalized
        }
        // An empty cwd must not become "/": URL(fileURLWithPath: "") resolves
        // to file:/// and its lastPathComponent is "/".
        guard !cwd.isEmpty else { return L10n.string("common.agent") }
        let workspace = URL(fileURLWithPath: cwd).lastPathComponent
        return workspace.isEmpty ? L10n.string("common.agent") : workspace
    }

    var promptPreview: String? {
        guard let userMessage else { return nil }
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.singleLine
    }
}

enum CairnStorage {
    static let privateDirectoryPermissions = 0o700
    static let privateFilePermissions = 0o600

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cairn", isDirectory: true)
    }

    static func ensurePrivateDirectory(at url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )
        try manager.setAttributes(
            [.posixPermissions: privateDirectoryPermissions],
            ofItemAtPath: url.path
        )
    }

    static func ensurePrivateFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: privateFilePermissions],
            ofItemAtPath: url.path
        )
    }
}

@MainActor
final class CompletionStore: ObservableObject {
    @Published private(set) var completions: [CodexCompletion] = []
    @Published private(set) var listenerStatus = "Starting…"

    var onQueueChange: ((Int) -> Void)?
    var onCompletionReceived: (() -> Void)?

    private let persistenceURL: URL
    private let inbox: FileInboxWatcher

    init() {
        persistenceURL = CairnStorage.directory.appendingPathComponent("completions.json")
        do {
            try CairnStorage.ensurePrivateDirectory(at: CairnStorage.directory)
            if FileManager.default.fileExists(atPath: persistenceURL.path) {
                try CairnStorage.ensurePrivateFile(at: persistenceURL)
            }
        } catch {
            NSLog("Cairn could not secure its local store: \(error.localizedDescription)")
        }
        completions = Self.load(from: persistenceURL)

        inbox = FileInboxWatcher(directory: CairnStorage.directory.appendingPathComponent("inbox", isDirectory: true))
        inbox.onCompletion = { [weak self] completion in
            Task { @MainActor [weak self] in
                self?.receive(completion)
            }
        }
        inbox.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.listenerStatus = status
            }
        }
        inbox.start()
    }

    func dismiss(sessionKey: String) {
        dismiss(sessionKeys: [sessionKey])
    }

    /// A collapsed stack is one object on screen, so its × has to take the
    /// whole pile — dismissing only the card you can see would leave the ones
    /// under it to spring back up in its place.
    func dismiss(sessionKeys: Set<String>) {
        guard !sessionKeys.isEmpty else { return }
        completions.removeAll { sessionKeys.contains($0.sessionKey) }
        save()
        onQueueChange?(completions.count)
    }

    func clear() {
        completions = []
        save()
        onQueueChange?(0)
    }

    private func receive(_ completion: CodexCompletion) {
        guard !completions.contains(where: { $0.id == completion.id }) else { return }

        if let existingIndex = completions.firstIndex(where: { $0.sessionKey == completion.sessionKey }) {
            completions.remove(at: existingIndex)
        }
        completions.insert(completion, at: 0)
        completions = Array(completions.prefix(50))
        save()
        onQueueChange?(completions.count)
        onCompletionReceived?()
    }

    private func save() {
        do {
            try CairnStorage.ensurePrivateDirectory(at: CairnStorage.directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(completions).write(to: persistenceURL, options: .atomic)
            try CairnStorage.ensurePrivateFile(at: persistenceURL)
        } catch {
            NSLog("Cairn could not persist completions: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [CodexCompletion] {
        let decoder = CairnJSON.decoder()
        guard let data = try? Data(contentsOf: url),
              let saved = try? decoder.decode([CodexCompletion].self, from: data) else {
            return []
        }

        var seenSessions = Set<String>()
        return saved
            .sorted { $0.timestamp > $1.timestamp }
            .filter { seenSessions.insert($0.sessionKey).inserted }
            .prefix(50)
            .map { $0 }
    }
}

final class FileInboxWatcher: @unchecked Sendable {
    var onCompletion: (@Sendable (CodexCompletion) -> Void)?
    var onStatusChange: (@Sendable (String) -> Void)?

    private let directory: URL
    private let queue = DispatchQueue(label: "app.cairn.listener")
    private var timer: DispatchSourceTimer?

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        do {
            try CairnStorage.ensurePrivateDirectory(at: directory.deletingLastPathComponent())
            try CairnStorage.ensurePrivateDirectory(at: directory)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(400))
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
            onStatusChange?("Watching")
        } catch {
            onStatusChange?("Inbox unavailable")
        }
    }

    private func scan() {
        let decoder = CairnJSON.decoder()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for file in files
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let completion = try? decoder.decode(CodexCompletion.self, from: data) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: file)
                onCompletion?(completion)
            } catch {
                onStatusChange?("Inbox needs attention")
            }
        }
    }
}

@MainActor
final class FloatingQueuePresenter: ObservableObject {
    @Published private(set) var presentsNotes: Bool
    @Published private(set) var isCallingAttention = false
    /// Which stack is open, if any. One at a time, like the notification centre
    /// this borrows from: two open piles and the queue stops being a queue.
    ///
    /// It lives here rather than in the view because the panel is sized by
    /// AppKit — the window has to know how tall the open stack is before
    /// SwiftUI draws a single card of it.
    @Published private(set) var expandedStackKey: String?

    private let notesPanel: NSPanel
    private let controlPanel: NSPanel
    private var hintPanel: NSPanel?
    private weak var store: CompletionStore?
    private let settings: CairnSettings
    private var screenObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var onboardingObserver: NSObjectProtocol?
    private var startObserver: NSObjectProtocol?
    private var controlSizeObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?
    private var stackingObserver: NSObjectProtocol?
    private var hasFinishedLaunching = false
    /// While onboarding gates the app, the panels stay off screen: an ignored
    /// connect window must look like an app that has not started yet.
    private var surfacesHeld = AgentConnectionCenter.needsOnboardingGate
    private var controlDragStart: NSPoint?
    private var attentionGeneration = 0
    private var notesShortcut: GlobalShortcut?

    private enum PreferenceKey {
        static let presentsNotes = "cairn.presentsNotes"
        static let controlX = "cairn.controlPanel.x"
        static let controlY = "cairn.controlPanel.y"
        static let controlIntroduced = "cairn.control.introduced"
    }

    init(
        store: CompletionStore,
        languageSettings: LanguageSettings,
        settings: CairnSettings
    ) {
        let preferences = UserDefaults.standard
        presentsNotes = preferences.object(forKey: PreferenceKey.presentsNotes) == nil
            ? false
            : preferences.bool(forKey: PreferenceKey.presentsNotes)
        self.store = store
        self.settings = settings
        notesPanel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Cairn.Metrics.notePanelWidth,
                height: NoteQueue.minimumHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        controlPanel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: Cairn.Metrics.controlPanel.scaled(by: settings.controlSize.scale)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanels(
            store: store,
            languageSettings: languageSettings,
            settings: settings
        )
        store.onQueueChange = { [weak self] _ in
            guard let self, self.hasFinishedLaunching, !self.surfacesHeld else { return }
            self.syncPanels()
        }
        store.onCompletionReceived = { [weak self] in
            self?.callAttention()
        }
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasFinishedLaunching = true
                guard !self.surfacesHeld else { return }
                self.controlPanel.setFrame(self.initialControlFrame(), display: true)
                self.syncPanels()
                self.installShortcut()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.controlPanel.setFrameOrigin(self.clampedControlOrigin(self.controlPanel.frame.origin))
                self.syncPanels()
            }
        }
        onboardingObserver = NotificationCenter.default.addObserver(
            forName: .cairnOnboardingDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginPresentingSurfaces()
                self?.introduceControl()
            }
        }
        startObserver = NotificationCenter.default.addObserver(
            forName: .cairnAppShouldStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.beginPresentingSurfaces() }
        }
        controlSizeObserver = NotificationCenter.default.addObserver(
            forName: .cairnControlSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let size = notification.object as? CairnControlSize
            Task { @MainActor [weak self] in
                guard let size else { return }
                self?.applyControlSize(size)
            }
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .cairnNotesShortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reinstallShortcut() }
        }
        stackingObserver = NotificationCenter.default.addObserver(
            forName: .cairnNoteStackingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Whichever way the switch went, the pile it referred to is
                // gone: unstacked there is nothing to open, and stacked again
                // the queue should read as one row per project.
                self.expandedStackKey = nil
                self.syncPanels()
            }
        }
    }

    /// A resize keeps the stones centred where they already are: the control is
    /// something the user placed, and growing it around its own centre is the
    /// only change that does not also move it.
    private func applyControlSize(_ size: CairnControlSize) {
        let panelSize = Cairn.Metrics.controlPanel.scaled(by: size.scale)
        let current = controlPanel.frame
        let proposed = NSPoint(
            x: current.midX - panelSize.width / 2,
            y: current.midY - panelSize.height / 2
        )
        controlPanel.setFrame(
            NSRect(
                origin: clampedControlOrigin(proposed, size: panelSize),
                size: panelSize
            ),
            display: true
        )
        // Before launch the panel has no place yet — `initialControlFrame` is
        // still to come, and writing this origin would overwrite the remembered
        // one with a placeholder.
        guard hasFinishedLaunching, !surfacesHeld else { return }
        UserDefaults.standard.set(controlPanel.frame.origin.x, forKey: PreferenceKey.controlX)
        UserDefaults.standard.set(controlPanel.frame.origin.y, forKey: PreferenceKey.controlY)
        syncPanels()
        // The introduction, if it is still standing, was placed beside a control
        // that just changed shape.
        if let hintPanel {
            hintPanel.setFrameOrigin(introductionOrigin(size: hintPanel.frame.size))
        }
    }

    /// The gate has opened: put the control on screen as if the app had just
    /// launched, because for the user it just did.
    private func beginPresentingSurfaces() {
        guard surfacesHeld else { return }
        surfacesHeld = false
        guard hasFinishedLaunching else { return }
        controlPanel.setFrame(initialControlFrame(), display: true)
        syncPanels()
        installShortcut()
    }

    /// The shortcut is claimed only once the app is really running — never
    /// while onboarding still holds the surfaces back. A key that opens a panel
    /// the user has not been shown yet is a key that does nothing.
    private func installShortcut() {
        guard notesShortcut == nil, hasFinishedLaunching, !surfacesHeld else { return }

        let settings = CairnSettings.shared
        let shortcut = GlobalShortcut(settings.notesShortcut) { [weak self] in
            self?.toggleNotesFromShortcut()
        }
        let claimed = shortcut.register()
        // Whether the keys were free is only knowable here, and only
        // actionable in Settings — where they can be recorded again.
        settings.recordShortcutRegistration(succeeded: claimed)
        guard claimed else { return }
        notesShortcut = shortcut
    }

    /// A recorded combination replaces the old one outright: the previous keys
    /// go back to the system first, so Cairn is never listening on two.
    private func reinstallShortcut() {
        notesShortcut?.unregister()
        notesShortcut = nil
        installShortcut()
    }

    /// A click on the control is aimed at something the eye has already found.
    /// The shortcut is pressed blind, from inside another app — so when there
    /// is nothing to expand it answers the way the control answers a finished
    /// turn, with a look rather than with silence.
    private func toggleNotesFromShortcut() {
        guard hasNotes else {
            dismissControlIntroduction()
            callAttention()
            return
        }
        toggleNotes()
    }

    var hasNotes: Bool {
        !(store?.completions.isEmpty ?? true)
    }

    func clearNotes() {
        store?.clear()
    }

    func toggleNotes() {
        dismissControlIntroduction()
        guard let store, !store.completions.isEmpty else { return }
        presentsNotes.toggle()
        // A queue that is put away and taken out again comes back the way a
        // queue looks: every project one row. An open stack is a question
        // being asked right now, not a state worth keeping.
        if !presentsNotes {
            expandedStackKey = nil
        }
        UserDefaults.standard.set(presentsNotes, forKey: PreferenceKey.presentsNotes)
        syncPanels()
    }

    /// Open the pile, or put it back. Only one is ever open, so opening a
    /// second closes the first without anyone having to.
    func toggleStack(_ key: String) {
        expandedStackKey = expandedStackKey == key ? nil : key
        syncPanels()
    }

    func updateControlDrag(translation: CGSize) {
        guard hasFinishedLaunching else { return }
        if controlDragStart == nil {
            controlDragStart = controlPanel.frame.origin
        }
        guard let start = controlDragStart else { return }

        let proposed = NSPoint(
            x: start.x + translation.width,
            y: start.y - translation.height
        )
        controlPanel.setFrameOrigin(clampedControlOrigin(proposed))
        if presentsNotes {
            positionNotesPanel(stacks: currentStacks(), animate: false)
        }
    }

    func finishControlDrag() {
        // Dragging is the first thing the introduction teaches, so doing it
        // is also what graduates from it.
        dismissControlIntroduction()
        controlDragStart = nil
        UserDefaults.standard.set(controlPanel.frame.origin.x, forKey: PreferenceKey.controlX)
        UserDefaults.standard.set(controlPanel.frame.origin.y, forKey: PreferenceKey.controlY)
    }

    /// The desktop control introduces itself, once, right after the first
    /// agent is connected. Its two facts are exactly what a first-run user
    /// cannot discover alone: the stones can be dragged anywhere, and notes
    /// will appear beside wherever they are put. Learned by doing (a drag or
    /// a click) or acknowledged with the button — either way it never
    /// returns.
    func introduceControl() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PreferenceKey.controlIntroduced) else { return }
        guard hasFinishedLaunching, hintPanel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureBasePanel(panel)
        panel.level = controlPanel.level
        panel.animationBehavior = .utilityWindow

        let host = NSHostingView(
            rootView: ControlIntroductionView { [weak self] in
                self?.dismissControlIntroduction()
            }
        )
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.setFrameOrigin(introductionOrigin(size: host.fittingSize))
        hintPanel = panel

        panel.orderFrontRegardless()
        controlPanel.orderFrontRegardless()
        callAttention()
    }

    func dismissControlIntroduction() {
        guard let hintPanel else { return }
        UserDefaults.standard.set(true, forKey: PreferenceKey.controlIntroduced)
        hintPanel.orderOut(nil)
        self.hintPanel = nil
    }

    /// Beside the control, on the side notes will appear — the introduction
    /// stands exactly where what it describes is going to happen.
    private func introductionOrigin(size: NSSize) -> NSPoint {
        let controlFrame = controlPanel.frame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(controlFrame) })
            ?? activeScreen()
        guard let visibleFrame = screen?.visibleFrame else { return .zero }

        let gap = Cairn.Metrics.panelGap
        let margin = Cairn.Metrics.screenMargin
        let hasRoomOnLeft = controlFrame.minX - visibleFrame.minX >= size.width + gap
        let x = hasRoomOnLeft
            ? controlFrame.minX - size.width - gap
            : min(controlFrame.maxX + gap, visibleFrame.maxX - size.width - margin)
        let y = min(
            max(controlFrame.maxY - size.height, visibleFrame.minY + margin),
            visibleFrame.maxY - size.height - margin
        )
        return NSPoint(x: x, y: y)
    }

    private func callAttention() {
        attentionGeneration += 1
        let generation = attentionGeneration
        isCallingAttention = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Cairn.Motion.attentionHold)
            guard let self, self.attentionGeneration == generation else { return }
            self.isCallingAttention = false
        }
    }

    private func configurePanels(
        store: CompletionStore,
        languageSettings: LanguageSettings,
        settings: CairnSettings
    ) {
        configureBasePanel(notesPanel)
        notesPanel.level = .floating
        notesPanel.animationBehavior = .utilityWindow
        notesPanel.contentView = NSHostingView(
            rootView: FloatingQueueView(
                store: store,
                presenter: self,
                languageSettings: languageSettings,
                settings: settings
            )
        )

        configureBasePanel(controlPanel)
        controlPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        controlPanel.acceptsMouseMovedEvents = true
        controlPanel.animationBehavior = .none
        let controlView = CairnControlHostingView(
            rootView: CairnControlView(
                store: store,
                presenter: self,
                languageSettings: languageSettings,
                settings: settings
            ),
            presenter: self
        )
        controlPanel.contentView = controlView
    }

    private func configureBasePanel(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    private func currentStacks() -> [NoteStack] {
        NoteQueue.stacks(
            for: store?.completions ?? [],
            stacking: settings.stacksNotes
        )
    }

    private func syncPanels() {
        controlPanel.orderFrontRegardless()

        let stacks = currentStacks()
        // A pile whose last note was dismissed is not open, it is gone — and a
        // key left pointing at it would swallow the next stack that happens to
        // gather in the same project.
        if let expandedStackKey, !stacks.contains(where: { $0.key == expandedStackKey }) {
            self.expandedStackKey = nil
        }

        if stacks.isEmpty {
            if presentsNotes {
                presentsNotes = false
                UserDefaults.standard.set(false, forKey: PreferenceKey.presentsNotes)
            }
            notesPanel.orderOut(nil)
            return
        }

        guard presentsNotes else {
            notesPanel.orderOut(nil)
            return
        }

        positionNotesPanel(stacks: stacks, animate: notesPanel.isVisible)
        notesPanel.orderFrontRegardless()
        controlPanel.orderFrontRegardless()
    }

    private func positionNotesPanel(stacks: [NoteStack], animate: Bool) {
        guard !stacks.isEmpty else { return }
        let contentHeight = NoteQueue.contentHeight(
            for: stacks,
            expandedKey: expandedStackKey
        )
        let panelHeight = min(contentHeight, maximumNotesPanelHeight())
        let panelSize = NSSize(width: Cairn.Metrics.notePanelWidth, height: panelHeight)
        let frame = notesPanelFrame(size: panelSize)

        notesPanel.setFrame(frame, display: true, animate: animate)
    }

    private func maximumNotesPanelHeight() -> CGFloat {
        let controlFrame = controlPanel.frame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(controlFrame) }) ?? activeScreen()
        guard let visibleFrame = screen?.visibleFrame else {
            return NoteQueue.maximumHeight
        }
        return min(
            NoteQueue.maximumHeight,
            max(
                NoteQueue.minimumHeight,
                visibleFrame.height - Cairn.Metrics.screenMargin * 2
            )
        )
    }

    private func initialControlFrame() -> NSRect {
        let size = controlPanel.frame.size
        let preferences = UserDefaults.standard
        if preferences.object(forKey: PreferenceKey.controlX) != nil,
           preferences.object(forKey: PreferenceKey.controlY) != nil {
            let saved = NSPoint(
                x: preferences.double(forKey: PreferenceKey.controlX),
                y: preferences.double(forKey: PreferenceKey.controlY)
            )
            return NSRect(origin: clampedControlOrigin(saved), size: size)
        }

        guard let screen = activeScreen() else {
            return NSRect(origin: .zero, size: size)
        }
        let visibleFrame = screen.visibleFrame
        let inset = Cairn.Metrics.firstRunInset
        return NSRect(
            x: visibleFrame.maxX - size.width - inset.width,
            y: visibleFrame.maxY - size.height - inset.height,
            width: size.width,
            height: size.height
        )
    }

    private func clampedControlOrigin(_ proposed: NSPoint, size: NSSize? = nil) -> NSPoint {
        let size = size ?? controlPanel.frame.size
        let proposedFrame = NSRect(origin: proposed, size: size)
        let center = NSPoint(x: proposedFrame.midX, y: proposedFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? activeScreen()
        guard let visibleFrame = screen?.visibleFrame else { return proposed }

        let margin = Cairn.Metrics.screenMargin
        return NSPoint(
            x: min(max(proposed.x, visibleFrame.minX + margin), visibleFrame.maxX - size.width - margin),
            y: min(max(proposed.y, visibleFrame.minY + margin), visibleFrame.maxY - size.height - margin)
        )
    }

    private func notesPanelFrame(size: NSSize) -> NSRect {
        let controlFrame = controlPanel.frame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(controlFrame) }) ?? activeScreen()
        guard let visibleFrame = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }

        let gap = Cairn.Metrics.panelGap
        let margin = Cairn.Metrics.screenMargin
        let hasRoomOnLeft = controlFrame.minX - visibleFrame.minX >= size.width + gap
        let x = hasRoomOnLeft
            ? controlFrame.minX - size.width - gap
            : min(controlFrame.maxX + gap, visibleFrame.maxX - size.width - margin)
        let preferredY = controlFrame.maxY - size.height
        let y = min(
            max(preferredY, visibleFrame.minY + margin),
            visibleFrame.maxY - size.height - margin
        )

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private struct CairnControlView: View {
    @ObservedObject var store: CompletionStore
    @ObservedObject var presenter: FloatingQueuePresenter
    @ObservedObject var languageSettings: LanguageSettings
    @ObservedObject var settings: CairnSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var scale: CGFloat { settings.controlSize.scale }

    private var badgeText: String {
        store.completions.count > 99 ? "99+" : "\(store.completions.count)"
    }

    private var controlShadow: Cairn.Shadow {
        if presenter.isCallingAttention { return .controlAttention }
        return isHovering
            ? .controlHover(colorScheme)
            : .controlResting(colorScheme)
    }

    private var controlScale: CGFloat {
        if isHovering { return Cairn.Motion.hoverScale }
        return presenter.isCallingAttention ? Cairn.Motion.attentionScale : 1
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: Cairn.Radius.control * scale, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: Cairn.Radius.control * scale, style: .continuous)
                    .fill(Cairn.Brand.jade.opacity(0.055))

                CairnMark(isExpanded: presenter.presentsNotes, scale: scale)
            }
            .frame(
                width: Cairn.Metrics.controlBody.width * scale,
                height: Cairn.Metrics.controlBody.height * scale
            )
            .overlay {
                RoundedRectangle(cornerRadius: Cairn.Radius.control * scale, style: .continuous)
                    .strokeBorder(
                        isHovering
                            ? Cairn.Stroke.controlHover(colorScheme)
                            : Cairn.Stroke.controlResting(colorScheme),
                        lineWidth: Cairn.Stroke.controlWidth
                    )
            }
            .cairnShadow(controlShadow)
            .scaleEffect(controlScale)

            if !store.completions.isEmpty {
                Text(badgeText)
                    .font(Cairn.Typo.badge(scale))
                    .foregroundStyle(.white)
                    .padding(.horizontal, store.completions.count > 9 ? Cairn.Space.xs * scale : 0)
                    .frame(
                        minWidth: Cairn.Metrics.badgeSize * scale,
                        minHeight: Cairn.Metrics.badgeSize * scale
                    )
                    .background(Cairn.Brand.jade, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Cairn.Stroke.badge, lineWidth: Cairn.Stroke.width)
                    }
                    .cairnShadow(.badge)
                    .offset(x: scale, y: -scale)
            }
        }
        .frame(
            width: Cairn.Metrics.controlPanel.width * scale,
            height: Cairn.Metrics.controlPanel.height * scale
        )
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(Cairn.Motion.toggle, value: presenter.presentsNotes)
        .animation(Cairn.Motion.hover, value: isHovering)
        .animation(Cairn.Motion.attention, value: presenter.isCallingAttention)
        .help(
            store.completions.isEmpty
                ? L10n.string("control.help.listening")
                : L10n.string("control.help.notes")
        )
        .accessibilityLabel(L10n.string("control.accessibility.label"))
        .accessibilityValue(
            presenter.presentsNotes
                ? L10n.string("control.accessibility.expanded")
                : L10n.string("control.accessibility.collapsed")
        )
    }
}

@MainActor
private final class CairnControlHostingView: NSHostingView<CairnControlView> {
    private weak var presenter: FloatingQueuePresenter?
    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    init(rootView: CairnControlView, presenter: FloatingQueuePresenter) {
        self.presenter = presenter
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: CairnControlView) {
        fatalError("Use init(rootView:presenter:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocation else { return }
        let current = NSEvent.mouseLocation
        let deltaX = current.x - mouseDownLocation.x
        let deltaY = current.y - mouseDownLocation.y
        guard didDrag || hypot(deltaX, deltaY) >= 5 else { return }

        didDrag = true
        presenter?.updateControlDrag(
            translation: CGSize(width: deltaX, height: -deltaY)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            presenter?.finishControlDrag()
        } else {
            presenter?.toggleNotes()
        }
        mouseDownLocation = nil
        didDrag = false
    }

    /// Expanding and clearing act on the notes, so they belong to the control
    /// that draws them — a left click already expands; a right click offers
    /// the rest. The menu bar is for what Cairn *is*, not for what the queue
    /// is doing this minute.
    override func rightMouseDown(with event: NSEvent) {
        guard let presenter else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let shortcut = CairnSettings.shared.notesShortcut
        let toggle = NSMenuItem(
            title: presenter.presentsNotes
                ? L10n.string("menu.collapse_notes")
                : L10n.string("menu.expand_notes"),
            action: #selector(toggleNotesFromMenu),
            keyEquivalent: shortcut.keyEquivalent
        )
        // The menu is where a right click already goes looking; printing the
        // combination beside the row it duplicates is the only teaching the
        // shortcut needs — recorded or shipped.
        toggle.keyEquivalentModifierMask = shortcut.cocoaModifiers
        toggle.target = self
        toggle.isEnabled = presenter.hasNotes
        menu.addItem(toggle)

        let clear = NSMenuItem(
            title: L10n.string("menu.clear"),
            action: #selector(clearNotesFromMenu),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = presenter.hasNotes
        menu.addItem(clear)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: L10n.string("menu.settings"),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        // The way out lives here whether or not the menu bar shows one. Cairn
        // has no Dock icon and no window to close, so the stones on the desktop
        // are the object a person points at when they want it gone — and
        // finding nothing there is what sends them to Activity Monitor.
        let quit = NSMenuItem(
            title: L10n.string("menu.quit"),
            action: #selector(quitFromMenu),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleNotesFromMenu() {
        presenter?.toggleNotes()
    }

    @objc private func clearNotesFromMenu() {
        presenter?.clearNotes()
    }

    @objc private func openSettingsFromMenu() {
        CairnSettings.shared.presentWindow()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}

/// The Cairn mark: two flat river stones and a lit crown.
///
/// Open and closed are told by the crown's light, not by the stack coming
/// apart. Closed, the light is banked — a dull facet and a tight halo. Open,
/// it comes on: the halo blooms, the facet grows and goes near-white, and the
/// crown sits up by a single point. The stones themselves stay put, so the
/// mark never reads as a disclosure triangle rotating.
struct CairnMark: View {
    let isExpanded: Bool
    /// The desktop control's size multiplier. The mark's own geometry is
    /// normalized, so this only sets the box it is fitted into.
    var scale: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    /// The halo's full extent, in mark units. Drawn at full size and scaled
    /// down when banked — a `RadialGradient` animates by transform far more
    /// reliably than by redrawing its radius.
    private static let haloRadius: CGFloat = 30

    private var haloScale: CGFloat { isExpanded ? 1 : 0.5 }
    private var haloOpacity: Double { isExpanded ? 1 : 0.32 }
    private var facetScale: CGFloat { isExpanded ? 1.16 : 0.78 }
    private var facetOpacity: Double { isExpanded ? 1 : 0.48 }
    /// One point on screen at the control's scale. Enough to feel the crown
    /// take the light, not enough to read as movement.
    private var crownLift: CGFloat { isExpanded ? 2 : 0 }
    private var crownRimOpacity: Double { isExpanded ? 0.62 : 0.18 }
    private var crownBrightness: Double { isExpanded ? 0.05 : -0.05 }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / Cairn.Mark.viewBox.width,
                proxy.size.height / Cairn.Mark.viewBox.height
            )
            let offset = CGPoint(
                x: (proxy.size.width - Cairn.Mark.viewBox.width * scale) / 2,
                y: (proxy.size.height - Cairn.Mark.viewBox.height * scale) / 2
            )

            ZStack {
                Ellipse()
                    .fill(Cairn.Surface.groundShadow)
                    .frame(
                        width: Cairn.Mark.ground.width * scale,
                        height: Cairn.Mark.ground.height * scale
                    )
                    .blur(radius: Cairn.Surface.groundShadowBlur * scale)
                    .position(
                        x: offset.x + Cairn.Mark.ground.midX * scale,
                        y: offset.y + Cairn.Mark.ground.midY * scale
                    )

                markStone(
                    Cairn.Mark.base,
                    fill: Cairn.Surface.basePebble,
                    scale: scale,
                    offset: offset
                )
                markStone(
                    Cairn.Mark.middle,
                    fill: Cairn.Surface.middlePebble,
                    scale: scale,
                    offset: offset
                )

                halo(scale: scale, offset: offset)

                markStone(
                    Cairn.Mark.crown,
                    fill: Cairn.Surface.crownPebble(colorScheme),
                    scale: scale,
                    offset: offset,
                    lift: crownLift
                )
                .brightness(crownBrightness)
                .shadow(
                    color: Cairn.Brand.beaconGlow.opacity(crownRimOpacity),
                    radius: isExpanded ? 6 : 2
                )

                Ellipse()
                    .fill(Cairn.Brand.beacon)
                    .frame(
                        width: Cairn.Mark.beacon.width * scale,
                        height: Cairn.Mark.beacon.height * scale
                    )
                    .scaleEffect(facetScale)
                    .opacity(facetOpacity)
                    .position(
                        x: offset.x + Cairn.Mark.beacon.midX * scale,
                        y: offset.y + (Cairn.Mark.beacon.midY - crownLift) * scale
                    )
            }
        }
        .frame(
            width: Cairn.Metrics.controlMark.width * scale,
            height: Cairn.Metrics.controlMark.height * scale
        )
    }

    /// The bloom behind the crown. It sits under the stone so the silhouette
    /// stays hard, and it is the loudest thing that changes between states.
    private func halo(scale: CGFloat, offset: CGPoint) -> some View {
        let diameter = Self.haloRadius * 2 * scale
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Cairn.Brand.beaconGlow.opacity(0.5),
                        Cairn.Brand.beaconGlow.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(haloScale)
            .opacity(haloOpacity)
            .position(
                x: offset.x + Cairn.Mark.crown.center.x * scale,
                y: offset.y + (Cairn.Mark.crown.center.y - crownLift) * scale
            )
    }

    private func markStone(
        _ stone: Cairn.Mark.Stone,
        fill: LinearGradient,
        scale: CGFloat,
        offset: CGPoint,
        lift: CGFloat = 0
    ) -> some View {
        PebbleShape(stone: stone)
            .fill(fill)
            .frame(width: stone.size.width * scale, height: stone.size.height * scale)
            .rotationEffect(.degrees(stone.rotation))
            .position(
                x: offset.x + stone.center.x * scale,
                y: offset.y + (stone.center.y - lift) * scale
            )
    }
}

/// A river stone: the shared superellipse outline, fitted to the given rect.
private struct PebbleShape: Shape {
    let stone: Cairn.Mark.Stone

    func path(in rect: CGRect) -> Path {
        let points = Cairn.Mark.outline(stone)
        guard let first = points.first else { return Path() }
        let sx = rect.width / stone.size.width
        let sy = rect.height / stone.size.height
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.midX + p.x * sx, y: rect.midY + p.y * sy)
        }

        var path = Path()
        path.move(to: place(first))
        for point in points.dropFirst() {
            path.addLine(to: place(point))
        }
        path.closeSubpath()
        return path
    }
}

/// The one-time card beside the control, wearing the same material as the
/// notes that will later stand in its place.
private struct ControlIntroductionView: View {
    @Environment(\.colorScheme) private var scheme
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Cairn.Space.lg) {
            // Wrap rather than truncate: the panel is sized from this view's
            // fitting size, and a measured single line ends in "…" once the
            // fixed width clamps it.
            Label(
                L10n.string("control.intro.drag"),
                systemImage: "hand.draw"
            )
            .fixedSize(horizontal: false, vertical: true)
            Label(
                L10n.string("control.intro.notes"),
                systemImage: "text.bubble"
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.string("control.intro.dismiss"), action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(Cairn.Typo.label)
                    .foregroundStyle(Cairn.Brand.jade)
            }
        }
        .font(Cairn.Typo.meta)
        .foregroundStyle(Cairn.Ink.body)
        .padding(Cairn.Space.xl)
        .frame(width: 264, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)
                .strokeBorder(Cairn.Stroke.controlResting(scheme), lineWidth: Cairn.Stroke.width)
        )
        .cairnShadow(.note(scheme))
        .padding(Cairn.Space.md)
    }
}

private struct FloatingQueueView: View {
    @ObservedObject var store: CompletionStore
    @ObservedObject var presenter: FloatingQueuePresenter
    @ObservedObject var languageSettings: LanguageSettings
    @ObservedObject var settings: CairnSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var scrollMetrics = QueueScrollMetrics()
    @State private var indicatorVisible = false
    @State private var indicatorHideTask: Task<Void, Never>?
    @State private var isClearHovering = false

    private var stacks: [NoteStack] {
        NoteQueue.stacks(for: store.completions, stacking: settings.stacksNotes)
    }

    var body: some View {
        let stacks = self.stacks

        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(spacing: Cairn.Metrics.noteCardSpacing) {
                    ForEach(stacks) { stack in
                        NoteStackRow(
                            stack: stack,
                            isExpanded: presenter.expandedStackKey == stack.key,
                            onToggle: { presenter.toggleStack(stack.key) },
                            onDismiss: { keys in
                                withAnimation(Cairn.Motion.dismiss) {
                                    store.dismiss(sessionKeys: keys)
                                }
                            }
                        )
                        .id(stack.key)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.96).combined(with: .opacity)
                        ))
                    }
                }
                .padding(Cairn.Space.lg)
                .background(QueueScrollObserver(onChange: scrollDidChange))
            }
            .scrollIndicators(.never)
            .overlay(alignment: .topTrailing) { scrollIndicator }

            if NoteQueue.showsClearAll(for: stacks.count) {
                clearAllControl
            }
        }
        .frame(width: Cairn.Metrics.notePanelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // The whole panel, not just the cards: a wheel event that lands in the
        // gap between two notes has to reach this window rather than the app
        // behind it, and macOS decides that per pixel.
        .background(Cairn.Surface.eventVeil)
        .animation(Cairn.Motion.enqueue, value: store.completions.map(\.sessionKey))
        .animation(Cairn.Motion.toggle, value: presenter.expandedStackKey)
    }

    /// Below the stack rather than above it: notes arrive at the top, and a
    /// control that the newest note pushes around is a control you misclick.
    /// It stays pinned outside the scroll view so a long queue cannot bury it.
    private var clearAllControl: some View {
        Button {
            withAnimation(Cairn.Motion.dismiss) {
                store.clear()
            }
        } label: {
            HStack(spacing: Cairn.Space.xs) {
                Image(systemName: "xmark")
                    .font(Cairn.Typo.glyph)
                Text(L10n.string("note.clear_all"))
                    .font(Cairn.Typo.meta)
            }
            .foregroundStyle(Cairn.Ink.secondary)
            .padding(.horizontal, Cairn.Space.lg)
            .frame(height: Cairn.Metrics.noteClearAllHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isClearHovering
                            ? Color.white.opacity(colorScheme == .dark ? 0.28 : 0.72)
                            : Cairn.Stroke.card(colorScheme),
                        lineWidth: Cairn.Stroke.width
                    )
            }
            .cairnShadow(.note(colorScheme))
        }
        .buttonStyle(.plain)
        .padding(.bottom, Cairn.Space.lg)
        .onHover { hovering in
            isClearHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(Cairn.Motion.hover, value: isClearHovering)
        // Clearing the queue takes the pill out from under the cursor, so the
        // pointing hand has to be popped on the way out or it sticks.
        .onDisappear {
            if isClearHovering {
                isClearHovering = false
                NSCursor.pop()
            }
        }
        .help(L10n.string("note.clear_all.help"))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Dark core with a light hairline, so the thumb reads over any wallpaper.
    @ViewBuilder
    private var scrollIndicator: some View {
        let metrics = scrollMetrics
        if metrics.content > metrics.viewport + 1 {
            let trackHeight = metrics.viewport - Cairn.Space.lg * 2
            let thumbHeight = max(
                Cairn.Metrics.scrollThumbMinHeight,
                trackHeight * metrics.viewport / metrics.content
            )
            let travel = max(0, trackHeight - thumbHeight)
            let progress = min(max(metrics.offset / (metrics.content - metrics.viewport), 0), 1)

            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: Cairn.Stroke.width)
                }
                .frame(width: Cairn.Metrics.scrollThumbWidth, height: thumbHeight)
                .offset(y: Cairn.Space.lg + progress * travel)
                .padding(.trailing, Cairn.Space.xs)
                .allowsHitTesting(false)
                .opacity(indicatorVisible ? 1 : 0)
        }
    }

    private func scrollDidChange(_ metrics: QueueScrollMetrics) {
        // Content growing past a screenful counts as cause to flash the thumb:
        // it is the one hint that older notes are stacked below the fold.
        let moved = abs(metrics.offset - scrollMetrics.offset) > 0.5
            || abs(metrics.content - scrollMetrics.content) > 0.5
        scrollMetrics = metrics
        if moved, metrics.content > metrics.viewport + 1 {
            revealIndicator()
        }
    }

    private func revealIndicator() {
        withAnimation(Cairn.Motion.hover) { indicatorVisible = true }
        indicatorHideTask?.cancel()
        indicatorHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { indicatorVisible = false }
        }
    }
}

private struct QueueScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
}

/// The bridge under the note queue's ScrollView. Two AppKit jobs SwiftUI
/// can't do itself: `.scrollIndicators` cannot suppress legacy scrollers (the
/// opaque bars shown when a mouse is attached and "Show scroll bars" resolves
/// to always), and scroll offset is read from the clip view directly rather
/// than through the preference-key chain. Scroller removal is re-applied from
/// `layout()` because SwiftUI restores it when the scroll view reconfigures.
private struct QueueScrollObserver: NSViewRepresentable {
    let onChange: (QueueScrollMetrics) -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObservingView: NSView {
        var onChange: ((QueueScrollMetrics) -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var lastReported = QueueScrollMetrics()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func layout() {
            super.layout()
            attach()
            report()
        }

        private func attach() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false

            guard observedScrollView !== scrollView else { return }
            if let previous = observedScrollView {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: previous.contentView
                )
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            observedScrollView = scrollView
        }

        @objc private func clipViewBoundsChanged(_ notification: Notification) {
            report()
        }

        private func report() {
            guard let scrollView = observedScrollView else { return }
            let metrics = QueueScrollMetrics(
                offset: scrollView.documentVisibleRect.origin.y,
                viewport: scrollView.contentView.bounds.height,
                content: scrollView.documentView?.frame.height ?? 0
            )
            guard metrics != lastReported else { return }
            lastReported = metrics
            // Defer: reports can fire mid-layout, inside a SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(metrics)
            }
        }
    }
}

/// One row of the queue: a note, or a pile of them.
///
/// Collapsed, the pile is the newest note with the edges of the ones under it
/// showing below — the same shape macOS uses in Notification Center, for the
/// same reason: a project that answered five times is one thing that happened,
/// and it should cost one row until you ask for the rest.
private struct NoteStackRow: View {
    let stack: NoteStack
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDismiss: (Set<String>) -> Void

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        if !stack.isStacked {
            CompletionNote(completion: stack.newest) {
                onDismiss([stack.newest.sessionKey])
            }
        } else if isExpanded {
            VStack(spacing: Cairn.Metrics.noteCardSpacing) {
                CompletionNote(
                    completion: stack.newest,
                    stackCount: stack.count,
                    isStackExpanded: true,
                    onToggleStack: onToggle
                ) {
                    onDismiss([stack.newest.sessionKey])
                }

                ForEach(stack.older, id: \.sessionKey) { note in
                    CompletionNote(completion: note) {
                        onDismiss([note.sessionKey])
                    }
                }
            }
        } else {
            ZStack(alignment: .top) {
                shoulders

                CompletionNote(
                    completion: stack.newest,
                    stackCount: stack.count,
                    isStackExpanded: false,
                    onToggleStack: onToggle
                ) {
                    onDismiss(stack.sessionKeys)
                }
            }
            // The shoulders are offset rather than laid out, so the row has to
            // be told how tall it really is — by the same arithmetic that sized
            // the panel around it.
            .frame(height: NoteQueue.height(of: stack, isExpanded: false), alignment: .top)
        }
    }

    /// The edges of the notes underneath: the card's own material and tint,
    /// drawn in from each side and slid down, so what shows below the top card
    /// is a curve that belongs to it.
    private var shoulders: some View {
        let depth = min(stack.count - 1, NoteQueue.maximumShoulders)
        let tone = stack.newest.identity.tone
        let shape = RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)

        // Deepest first, so the nearer shoulder covers it.
        return ForEach(Array(stride(from: depth, through: 1, by: -1)), id: \.self) { level in
            shape
                .fill(.ultraThinMaterial)
                .overlay { shape.fill(tone.wash(colorScheme)) }
                .overlay {
                    shape.strokeBorder(
                        Cairn.Stroke.card(colorScheme),
                        lineWidth: Cairn.Stroke.width
                    )
                }
                .frame(height: Cairn.Metrics.noteCardHeight)
                .padding(.horizontal, Cairn.Metrics.noteStackInset * CGFloat(level))
                .offset(y: Cairn.Metrics.noteStackShoulder * CGFloat(level))
                .cairnShadow(.note(colorScheme))
        }
        // Nothing here is a target. The card on top carries every gesture the
        // pile answers to, and a shape that eats a scroll event is a queue that
        // stops scrolling.
        .allowsHitTesting(false)
    }
}

private struct CompletionNote: View {
    let completion: CodexCompletion
    /// How many notes this card stands for. One is a note; more is a pile, and
    /// the header grows the chip that opens it.
    var stackCount: Int = 1
    var isStackExpanded: Bool = false
    var onToggleStack: (() -> Void)?
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var agent: Cairn.Agent {
        completion.identity
    }

    private var isStacked: Bool {
        stackCount > 1 && onToggleStack != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Cairn.Space.sm) {
            HStack(spacing: Cairn.Space.sm) {
                HStack(spacing: Cairn.Space.xs) {
                    AgentGlyph(agent: agent, size: Cairn.Metrics.agentGlyphNote)

                    Text(agent.name)
                        .font(Cairn.Typo.label)
                        .foregroundStyle(agent.tone.label(colorScheme))

                    Text("· \(completion.contextName)")
                        .font(Cairn.Typo.meta)
                        .foregroundStyle(Cairn.Ink.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Cairn.Space.md)

                if isStacked {
                    stackChip
                }

                CompactRelativeTime(timestamp: completion.timestamp)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Cairn.Typo.glyph)
                        .frame(
                            width: Cairn.Metrics.dismissTarget,
                            height: Cairn.Metrics.dismissTarget
                        )
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Cairn.Ink.secondary)
                .help(
                    isStacked && !isStackExpanded
                        ? L10n.string("note.dismiss_stack")
                        : L10n.string("note.dismiss")
                )
            }

            if let prompt = completion.promptPreview {
                Text(prompt)
                    .font(Cairn.Typo.noteTitle)
                    .lineLimit(1)
            }

            Text(completion.result.singleLine)
                .font(Cairn.Typo.noteBody)
                .foregroundStyle(Cairn.Ink.body)
                .lineLimit(completion.promptPreview == nil ? 3 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Cairn.Space.xl)
        .padding(.vertical, Cairn.Space.lg)
        .frame(height: Cairn.Metrics.noteCardHeight, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)
                    .fill(agent.tone.wash(colorScheme))
            }
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(agent.tone.rail(colorScheme))
                .frame(
                    width: Cairn.Metrics.noteRailWidth,
                    height: Cairn.Metrics.noteRailHeight
                )
                .padding(.leading, Cairn.Space.xs)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous)
                .strokeBorder(
                    isHovering ? agent.tone.rail(colorScheme).opacity(0.55) : Cairn.Stroke.card(colorScheme),
                    lineWidth: Cairn.Stroke.width
                )
        }
        .cairnShadow(.note(colorScheme))
        .contentShape(RoundedRectangle(cornerRadius: Cairn.Radius.card, style: .continuous))
        .onTapGesture {
            TrailFinder.follow(completion)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(Cairn.Motion.hover, value: isHovering)
        .help(L10n.string("note.follow"))
    }

    /// How many notes are under this one, and the way to them.
    ///
    /// Its own control rather than a second meaning for the card: a click on
    /// the card already goes back to where the turn ran, and that is the
    /// promise the queue is built on. The chip wears the agent's colour because
    /// what it counts is that agent's work.
    private var stackChip: some View {
        Button {
            onToggleStack?()
        } label: {
            HStack(spacing: Cairn.Space.xxs) {
                Text("\(stackCount)")
                    .font(Cairn.Typo.micro.weight(.semibold).monospacedDigit())
                Image(systemName: isStackExpanded ? "chevron.up" : "chevron.down")
                    .font(Cairn.Typo.glyph)
            }
            .foregroundStyle(agent.tone.label(colorScheme))
            .padding(.horizontal, Cairn.Space.sm)
            .frame(height: Cairn.Metrics.dismissTarget)
            .background(.quaternary, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(stackHelp)
        .accessibilityLabel(stackHelp)
    }

    private var stackHelp: String {
        isStackExpanded
            ? L10n.string("note.stack.collapse")
            : L10n.format("note.stack.expand", stackCount)
    }
}

private struct CompactRelativeTime: View {
    let timestamp: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(timestamp.compactRelative(to: context.date))
                .font(Cairn.Typo.micro)
                .foregroundStyle(Cairn.Ink.tertiary)
        }
    }
}

private struct MenuBarQueueView: View {
    @ObservedObject var store: CompletionStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var permissions: PermissionExperience
    @ObservedObject var connections: AgentConnectionCenter
    @ObservedObject var languageSettings: LanguageSettings
    @ObservedObject var settings: CairnSettings

    private var listenerStatusLabel: String {
        switch store.listenerStatus {
        case "Starting…":
            L10n.string("listener.starting")
        case "Watching":
            L10n.string("listener.watching")
        case "Inbox unavailable":
            L10n.string("listener.inbox_unavailable")
        case "Inbox needs attention":
            L10n.string("listener.inbox_attention")
        default:
            store.listenerStatus
        }
    }

    /// The listener has nothing to say while it is working. Only the two states
    /// that stop notes from arriving are worth a row — and they replace the
    /// header that used to spend a line telling you the app is called Cairn.
    private var listenerNeedsAttention: Bool {
        store.listenerStatus == "Inbox unavailable"
            || store.listenerStatus == "Inbox needs attention"
    }

    var body: some View {
        VStack(spacing: 0) {
            if listenerNeedsAttention {
                Label(listenerStatusLabel, systemImage: "exclamationmark.triangle")
                    .font(Cairn.Typo.menuRow)
                    .foregroundStyle(Cairn.Status.degraded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Cairn.Space.xl)
                    .padding(.vertical, Cairn.Space.lg)

                Divider()
            }

            if let update = updateChecker.available {
                UpdateAvailableRow(update: update) {
                    updateChecker.skip(update)
                }

                Divider()
            }

            // Setup: the three things a person changes once and forgets. The
            // queue's own controls are not here — expanding and clearing act
            // on the notes, so they live on the control that draws them.
            MenuGroup {
                MenuActionRow(
                    title: L10n.string("menu.connect"),
                    action: connections.presentWindow
                ) {
                    // The marks answer "which" and the count answers "how
                    // many" — so the marks come first, in reading order, and
                    // disappear along with the question when nothing is
                    // connected.
                    HStack(spacing: Cairn.Space.sm) {
                        AgentGlyphStrip(
                            agents: connections.connectedAgents,
                            size: Cairn.Metrics.agentGlyphMenu
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

                MenuActionRow(
                    title: L10n.string("menu.access"),
                    action: permissions.presentCenter
                )

                // Language used to sit here as a picker. It belongs with the
                // rest of the switches now: a menu row that opens a menu is one
                // click deeper than the window that holds every other one.
                MenuActionRow(
                    title: L10n.string("menu.settings"),
                    action: settings.presentWindow
                )
            }

            Divider()

            // Version, then the check it belongs to, then the way out — the
            // shape every menu bar app ends in.
            MenuGroup {
                // Not a row you can press, so not a MenuActionRow — only the
                // inset is shared, which is what lines it up with the rest.
                Text(CairnBuildInfo.displayVersion)
                    .font(Cairn.Typo.menuRow.monospacedDigit())
                    .foregroundStyle(Cairn.Ink.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Cairn.Space.xl)
                    .padding(.vertical, Cairn.Space.sm)

                UpdateCheckRow(status: updateChecker.status) {
                    updateChecker.checkNow()
                }

                MenuActionRow(title: L10n.string("menu.quit")) {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(.vertical, Cairn.Space.xs)
        .frame(width: Cairn.Metrics.menuWidth)
    }
}

// MARK: - Menu rows

/// One band of related rows, inset from the dividers that separate it.
private struct MenuGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, Cairn.Space.xs)
    }
}

/// A full-width menu row: icon, label, and whatever the row wants to say on
/// the right.
///
/// Six controls competing on one line read as a toolbar, and a toolbar is a
/// thing you scan. A menu is a thing you read — one action per line, each with
/// room for the one number that matters to it.
private struct MenuActionRow<Trailing: View>: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            MenuRowLabel(
                title: title,
                isHighlighted: isHovering && isEnabled
            ) {
                trailing
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering in
            withAnimation(Cairn.Motion.hover) { isHovering = hovering }
        }
    }
}

extension MenuActionRow where Trailing == EmptyView {
    init(
        title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            isEnabled: isEnabled,
            action: action
        ) { EmptyView() }
    }
}

private struct MenuRowLabel<Trailing: View>: View {
    let title: String
    let isHighlighted: Bool
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Cairn.Space.md) {
            Text(title)
            Spacer(minLength: Cairn.Space.sm)
            trailing
        }
        .font(Cairn.Typo.menuRow)
        .foregroundStyle(Cairn.Ink.secondary)
        .padding(.horizontal, Cairn.Space.sm)
        .padding(.vertical, Cairn.Space.sm)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Cairn.Radius.sm, style: .continuous)
                .fill(isHighlighted ? Cairn.Ink.secondary.opacity(0.12) : .clear)
        )
        .padding(.horizontal, Cairn.Space.md)
    }
}

private struct UpdateAvailableRow: View {
    let update: AppUpdate
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: Cairn.Space.md) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Cairn.Brand.jade)

            VStack(alignment: .leading, spacing: Cairn.Space.xxs) {
                Text(L10n.string("update.available"))
                    .font(Cairn.Typo.label)
                Text(L10n.format("update.version_format", update.version))
                    .font(Cairn.Typo.meta)
                    .foregroundStyle(Cairn.Ink.secondary)
            }

            Spacer(minLength: Cairn.Space.sm)

            Button(L10n.string("update.view")) {
                NSWorkspace.shared.open(update.releaseURL)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Cairn.Brand.jade)
            .font(Cairn.Typo.label)

            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(Cairn.Typo.glyph)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Cairn.Ink.tertiary)
            .help(L10n.string("update.skip"))
        }
        .padding(.horizontal, Cairn.Space.xl)
        .padding(.vertical, Cairn.Space.md)
    }
}

/// The update check as one row: the title never moves, the outcome sits on the
/// right. A label that rewrites itself between "check", "checking", and "try
/// again" makes the row jump under the pointer that is about to press it.
private struct UpdateCheckRow: View {
    let status: UpdateCheckStatus
    let onCheck: () -> Void

    var body: some View {
        MenuActionRow(
            title: L10n.string("update.check"),
            isEnabled: status != .checking,
            action: onCheck
        ) {
            switch status {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .upToDate:
                Text(L10n.string("update.up_to_date"))
                    .font(Cairn.Typo.meta)
                    .foregroundStyle(Cairn.Ink.tertiary)
            case .failed:
                Text(L10n.string("update.failed"))
                    .font(Cairn.Typo.meta)
                    .foregroundStyle(Cairn.Status.degraded)
            }
        }
    }
}

private extension String {
    var singleLine: String {
        replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Date {
    func compactRelative(to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(self)))
        if seconds < 60 { return L10n.string("relative.now") }
        if seconds < 3_600 { return L10n.format("relative.minutes", seconds / 60) }
        if seconds < 86_400 { return L10n.format("relative.hours", seconds / 3_600) }
        return L10n.format("relative.days", seconds / 86_400)
    }
}
