import AppKit
import ApplicationServices
import Carbon
import SwiftUI

enum CairnPermissionState: Equatable, Sendable {
    case checking
    case granted
    case notRequested
    case needsSettings
    case unavailable

    var label: String {
        switch self {
        case .checking: "Checking…"
        case .granted: "On"
        case .notRequested: "Optional"
        case .needsSettings: "Off"
        case .unavailable: "Unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "ellipsis"
        case .granted: "checkmark.circle.fill"
        case .notRequested: "circle"
        case .needsSettings: "exclamationmark.circle.fill"
        case .unavailable: "minus.circle"
        }
    }
}

enum CairnApplicationState: Equatable, Sendable {
    case notInstalled
    case notRunning
    case running
}

struct CairnAccessPresentation: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case enable
        case open
        case settings

        var title: String {
            switch self {
            case .enable: "Enable"
            case .open: "Open"
            case .settings: "Settings"
            }
        }
    }

    let label: String
    let symbol: String
    let isGranted: Bool
    let action: Action?

    static func permission(_ state: CairnPermissionState) -> Self {
        let action: Action?
        switch state {
        case .granted, .needsSettings:
            action = .settings
        case .notRequested:
            action = .enable
        case .checking, .unavailable:
            action = nil
        }

        return Self(
            label: state.label,
            symbol: state.symbol,
            isGranted: state == .granted,
            action: action
        )
    }

    /// Accessibility says "Off" for a different reason than Automation does, so
    /// its button leads somewhere else.
    ///
    /// An Automation "Off" is `errAEEventNotPermitted` — a denial the system
    /// recorded, which it will never re-ask about, so Settings is the only way
    /// back. Accessibility has no such signal: "Off" only means Cairn's own
    /// flag says it asked once. The system may never have registered Cairn at
    /// all, in which case Settings shows no row to switch on and the button is
    /// a dead end. Asking again is what creates that row, and the system prompt
    /// offers Settings itself.
    static func accessibility(_ state: CairnPermissionState) -> Self {
        guard state == .needsSettings else { return permission(state) }
        return Self(
            label: state.label,
            symbol: state.symbol,
            isGranted: false,
            action: .enable
        )
    }

    static func automation(
        application: CairnApplicationState,
        permission permissionState: CairnPermissionState
    ) -> Self {
        switch application {
        case .notInstalled:
            Self(
                label: "Not installed",
                symbol: "minus.circle",
                isGranted: false,
                action: nil
            )
        case .notRunning:
            Self(
                label: "Not needed yet",
                symbol: "moon.zzz",
                isGranted: false,
                action: .open
            )
        case .running:
            permission(permissionState)
        }
    }
}

enum AutomationPermissionProbe {
    static func classify(_ status: OSStatus) -> CairnPermissionState {
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notRequested
        case OSStatus(errAEEventNotPermitted):
            return .needsSettings
        case OSStatus(procNotFound):
            return .unavailable
        default:
            return .unavailable
        }
    }

    static func state(bundleID: String) -> CairnPermissionState {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let target = descriptor.aeDesc else { return .unavailable }
        // Never ask from here: this runs on every refresh, and a status read
        // must not become a system interruption.
        let status = AEDeterminePermissionToAutomateTarget(
            target,
            typeWildCard,
            typeWildCard,
            false
        )
        return classify(status)
    }

    /// Ask the system for consent by sending a real, read-only Apple Event.
    ///
    /// `AEDeterminePermissionToAutomateTarget` with a wildcard event pair only
    /// *reports* whether consent is needed — it never *asks*, whatever
    /// `askUserIfNeeded` says. Driving the Enable button through it meant the
    /// button did nothing at all. Sending an actual event is what raises the
    /// consent dialog, so this asks for the smallest one there is.
    static func requestConsent(scriptName: String) {
        let source = "tell application \"\(scriptName)\" to return name"
        guard let script = NSAppleScript(source: source) else {
            NSLog("Cairn automation consent: could not compile a request for \(scriptName)")
            return
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 is a recorded denial: macOS will not ask again, and only
            // Settings can undo it. Anything else is worth seeing.
            NSLog("Cairn automation consent for \(scriptName): error \(error)")
        } else {
            NSLog("Cairn automation consent for \(scriptName): granted (\(result.stringValue ?? "?"))")
        }
    }
}

struct AutomationAccess: Identifiable, Equatable {
    enum Kind: String {
        case terminal
        case iterm
        case browser
    }

    let kind: Kind
    let title: String
    let detail: String
    let bundleID: String
    /// The name this application answers to in AppleScript, which is not always
    /// its display name. Needed to ask for consent — see `requestAutomation`.
    let scriptName: String
    let icon: String

    var id: String { bundleID }
}

/// Owns Cairn's permission state and the two small windows that expose it.
///
/// The welcome screen is versioned, but permission completion is never stored
/// as a one-time boolean. Every status shown in the access center is refreshed
/// from the operating system.
@MainActor
final class PermissionExperience: ObservableObject {
    static let shared = PermissionExperience()

    @Published private(set) var accessibilityState: CairnPermissionState = .checking
    @Published private(set) var terminalState: CairnPermissionState = .checking
    @Published private(set) var itermState: CairnPermissionState = .checking
    @Published private(set) var browserState: CairnPermissionState = .checking
    @Published private(set) var terminalApplicationState: CairnApplicationState = .notRunning
    @Published private(set) var itermApplicationState: CairnApplicationState = .notRunning
    @Published private(set) var browserApplicationState: CairnApplicationState = .notRunning
    @Published private(set) var browserAccess: AutomationAccess?

    private enum PreferenceKey {
        static let journeyVersion = "cairn.permissions.journeyVersion"
        static let accessibilityRequested = "cairn.permissions.accessibilityRequested"
        static let legacyAXPromptShown = "cairn.trailfinder.axPromptShown"
    }

    private static let currentJourneyVersion = 1

    private let terminalAccess = AutomationAccess(
        kind: .terminal,
        title: "Terminal tabs",
        detail: "Return to the exact tab.",
        bundleID: "com.apple.Terminal",
        scriptName: "Terminal",
        icon: "terminal"
    )
    private let itermAccess = AutomationAccess(
        kind: .iterm,
        title: "iTerm2 sessions",
        detail: "Return to the exact session.",
        bundleID: "com.googlecode.iterm2",
        scriptName: "iTerm2",
        icon: "rectangle.split.2x1"
    )

    private var welcomeWindow: NSWindow?
    private var centerWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshGeneration = 0

    private init() {
        migrateLegacyState()

        let center = NotificationCenter.default
        workspaceObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            )
        }
    }

    func presentWelcomeIfNeeded() {
        refresh()
        guard UserDefaults.standard.integer(forKey: PreferenceKey.journeyVersion)
                < Self.currentJourneyVersion else {
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Cairn"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: PermissionWelcomeView(
                onReview: { [weak self] in
                    self?.finishWelcome()
                    self?.presentCenter()
                },
                onLater: { [weak self] in self?.finishWelcome() }
            )
        )
        window.center()
        welcomeWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func presentCenter() {
        refresh()

        if let centerWindow {
            NSApp.activate(ignoringOtherApps: true)
            centerWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cairn Access"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PermissionCenterView(experience: self))
        window.center()
        centerWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func requestAccessibility() {
        // Granted is the only state where Settings is the right destination:
        // there is nothing left to ask for, only something to review or revoke.
        if accessibilityState == .granted {
            openPrivacySettings(anchor: "Privacy_Accessibility")
            return
        }

        // Otherwise always ask, and never open Settings on the user's behalf.
        // The system prompt already carries an "Open System Settings" button,
        // so opening it ourselves both steals the decision and buries the
        // prompt behind the Settings window. Asking again is also what
        // REGISTERS Cairn in the Accessibility list — remembering "already
        // asked" and going straight to Settings instead was a dead end,
        // because the row the user was told to switch on did not exist yet.
        UserDefaults.standard.set(true, forKey: PreferenceKey.accessibilityRequested)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func handleAutomation(_ kind: AutomationAccess.Kind) {
        guard let access = access(for: kind) else {
            NSLog("Cairn access: no automation target for \(kind.rawValue)")
            return
        }
        NSLog("Cairn access: \(kind.rawValue) -> \(String(describing: presentation(for: kind).action))")
        switch presentation(for: kind).action {
        case .open:
            openTarget(access)
        case .settings:
            openPrivacySettings(anchor: "Privacy_Automation")
        case .enable:
            requestAutomation(access)
        case nil:
            break
        }
    }

    func canAutomate(bundleID: String) -> Bool {
        if bundleID == terminalAccess.bundleID {
            return terminalState == .granted
        }
        if bundleID == itermAccess.bundleID {
            return itermState == .granted
        }
        if bundleID == browserAccess?.bundleID {
            return browserState == .granted
        }
        return false
    }

    fileprivate func state(for kind: AutomationAccess.Kind) -> CairnPermissionState {
        switch kind {
        case .terminal: terminalState
        case .iterm: itermState
        case .browser: browserState
        }
    }

    fileprivate var accessibilityPresentation: CairnAccessPresentation {
        .accessibility(accessibilityState)
    }

    fileprivate func presentation(
        for kind: AutomationAccess.Kind
    ) -> CairnAccessPresentation {
        let application: CairnApplicationState
        switch kind {
        case .terminal:
            application = terminalApplicationState
        case .iterm:
            application = itermApplicationState
        case .browser:
            application = browserApplicationState
        }
        return .automation(application: application, permission: state(for: kind))
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration

        let accessibilityRequested = UserDefaults.standard.bool(
            forKey: PreferenceKey.accessibilityRequested
        )
        accessibilityState = AXIsProcessTrusted()
            ? .granted
            : (accessibilityRequested ? .needsSettings : .notRequested)

        let browser = TrailFinder.defaultScriptableBrowser().map {
            AutomationAccess(
                kind: .browser,
                title: "\($0.scriptName) tabs",
                detail: "Reuse the matching tab.",
                bundleID: $0.bundleID,
                scriptName: $0.scriptName,
                icon: "safari"
            )
        }
        let previousBrowserBundleID = browserAccess?.bundleID
        browserAccess = browser
        if browser == nil {
            browserState = .unavailable
        } else if browser?.bundleID != previousBrowserBundleID {
            browserState = .checking
        }

        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        )
        let accesses = [terminalAccess, itermAccess] + (browser.map { [$0] } ?? [])
        let applicationStates = Dictionary(
            uniqueKeysWithValues: accesses.map { access in
                let bundleID = access.bundleID.lowercased()
                let state: CairnApplicationState
                if runningBundleIDs.contains(bundleID) {
                    state = .running
                } else if NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: access.bundleID
                ) != nil {
                    state = .notRunning
                } else {
                    state = .notInstalled
                }
                return (access.kind, state)
            }
        )

        terminalApplicationState = applicationStates[.terminal] ?? .notInstalled
        itermApplicationState = applicationStates[.iterm] ?? .notInstalled
        browserApplicationState = applicationStates[.browser] ?? .notInstalled

        Task { [weak self] in
            let results = await withTaskGroup(
                of: (AutomationAccess.Kind, CairnPermissionState).self,
                returning: [AutomationAccess.Kind: CairnPermissionState].self
            ) { group in
                for access in accesses {
                    let applicationState = applicationStates[access.kind]
                    group.addTask {
                        guard applicationState == .running else {
                            return (access.kind, .checking)
                        }
                        let state = await Task.detached {
                            AutomationPermissionProbe.state(bundleID: access.bundleID)
                        }.value
                        return (access.kind, state)
                    }
                }

                var collected: [AutomationAccess.Kind: CairnPermissionState] = [:]
                for await (kind, state) in group {
                    collected[kind] = state
                }
                return collected
            }

            guard let self, self.refreshGeneration == generation else { return }
            if applicationStates[.terminal] == .running {
                self.terminalState = results[.terminal] ?? .unavailable
            }
            if applicationStates[.iterm] == .running {
                self.itermState = results[.iterm] ?? .unavailable
            }
            if browser != nil, applicationStates[.browser] == .running {
                self.browserState = results[.browser] ?? .unavailable
            }
        }
    }

    private func migrateLegacyState() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PreferenceKey.accessibilityRequested) else { return }
        if defaults.bool(forKey: PreferenceKey.legacyAXPromptShown) {
            defaults.set(true, forKey: PreferenceKey.accessibilityRequested)
        }
    }

    private func finishWelcome() {
        UserDefaults.standard.set(
            Self.currentJourneyVersion,
            forKey: PreferenceKey.journeyVersion
        )
        welcomeWindow?.close()
        welcomeWindow = nil
    }

    private func access(for kind: AutomationAccess.Kind) -> AutomationAccess? {
        switch kind {
        case .terminal: terminalAccess
        case .iterm: itermAccess
        case .browser: browserAccess
        }
    }

    private func requestAutomation(_ access: AutomationAccess) {
        let scriptName = access.scriptName
        Task { [weak self] in
            // Detached because the consent dialog is modal to us: asking on the
            // main actor would freeze the access center behind it.
            await Task.detached {
                AutomationPermissionProbe.requestConsent(scriptName: scriptName)
            }.value
            self?.refresh()
        }
    }

    private func openTarget(_ access: AutomationAccess) {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: access.bundleID
        ) else { return }

        Task { [weak self] in
            _ = try? await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            try? await Task.sleep(for: .milliseconds(500))
            self?.refresh()
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionWelcomeView: View {
    let onReview: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Cairn.Space.xl) {
            HStack(spacing: Cairn.Space.md) {
                Image(nsImage: CairnMenuBarIcon.shared)
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("Cairn is ready")
                    .font(.title2.weight(.semibold))
            }

            Text("Completed agent turns can appear without extra access.")
                .foregroundStyle(.secondary)

            Label("No screen recording or keyboard monitoring", systemImage: "hand.raised")
                .font(.subheadline)
            Label("Enable precise return when you want it", systemImage: "arrow.uturn.backward")
                .font(.subheadline)

            Spacer()

            HStack {
                Spacer()
                Button("Later", action: onLater)
                    .keyboardShortcut(.cancelAction)
                Button("Review Access", action: onReview)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Cairn.Space.xxl)
        .frame(width: 420, height: 280)
    }
}

private struct PermissionCenterView: View {
    @ObservedObject var experience: PermissionExperience

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cairn.Space.xl) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Cairn.Space.xs) {
                        Text("Precise return")
                            .font(.title2.weight(.semibold))
                        Text("Cairn works without extra access.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: experience.refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }

                PermissionAccessRow(
                    icon: "macwindow",
                    title: "Editor windows",
                    detail: "Uses Accessibility to raise the right window.",
                    presentation: experience.accessibilityPresentation,
                    action: experience.requestAccessibility
                )

                Divider()

                automationRow(
                    icon: "terminal",
                    title: "Terminal tabs",
                    detail: "Uses Automation to return to the exact tab.",
                    kind: .terminal
                )
                automationRow(
                    icon: "rectangle.split.2x1",
                    title: "iTerm2 sessions",
                    detail: "Uses Automation to return to the exact session.",
                    kind: .iterm
                )

                if let browser = experience.browserAccess {
                    automationRow(
                        icon: browser.icon,
                        title: browser.title,
                        detail: "Uses Automation to reuse the matching tab.",
                        kind: .browser
                    )
                } else {
                    PermissionAccessRow(
                        icon: "globe",
                        title: "Browser tabs",
                        detail: "Current browser is not supported.",
                        presentation: .permission(.unavailable),
                        action: {}
                    )
                }

                Divider()

                Label(
                    "No screen recording, input monitoring, or notification access.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(Cairn.Space.xxl)
        }
        .frame(width: 500, height: 520)
    }

    private func automationRow(
        icon: String,
        title: String,
        detail: String,
        kind: AutomationAccess.Kind
    ) -> some View {
        return PermissionAccessRow(
            icon: icon,
            title: title,
            detail: detail,
            presentation: experience.presentation(for: kind),
            action: { experience.handleAutomation(kind) }
        )
    }
}

private struct PermissionAccessRow: View {
    let icon: String
    let title: String
    let detail: String
    let presentation: CairnAccessPresentation
    let action: () -> Void

    private var statusColor: Color {
        presentation.isGranted ? Cairn.Status.listening : Cairn.Ink.tertiary
    }

    var body: some View {
        HStack(spacing: Cairn.Space.md) {
            Image(systemName: icon)
                .foregroundStyle(Cairn.Brand.jade)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: Cairn.Space.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Cairn.Space.md)

            Label(presentation.label, systemImage: presentation.symbol)
                .font(.caption)
                .foregroundStyle(statusColor)
                .labelStyle(.titleAndIcon)

            if let accessAction = presentation.action {
                if accessAction == .settings, presentation.isGranted {
                    Button(action: action) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Open Settings")
                    .accessibilityLabel("Settings")
                } else {
                    Button(accessAction.title, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, Cairn.Space.xs)
    }
}
