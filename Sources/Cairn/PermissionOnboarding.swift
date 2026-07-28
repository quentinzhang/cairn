import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import os

/// Cairn's diagnostics, under one subsystem so a user can retrieve all of them:
///
///     log show --predicate 'subsystem == "app.cairn.Cairn"' --last 30m
///
/// `NSLog` is not an option: on current macOS it writes to stderr without
/// reaching the unified log store, which makes it invisible from outside the
/// app — exactly when a silent permission failure needs explaining. Every
/// interpolation here is marked `.public`; os_log redacts by default, and a
/// redacted diagnostic is not a diagnostic.
extension Logger {
    static let access = Logger(subsystem: "app.cairn.Cairn", category: "access")
    static let trail = Logger(subsystem: "app.cairn.Cairn", category: "trail")
}

enum CairnPermissionState: Equatable, Sendable {
    case checking
    case granted
    case notRequested
    case needsSettings
    case unavailable

    var label: String {
        switch self {
        case .checking: L10n.string("permission.state.checking")
        case .granted: L10n.string("permission.state.on")
        case .notRequested: L10n.string("permission.state.optional")
        case .needsSettings: L10n.string("permission.state.off")
        case .unavailable: L10n.string("permission.state.unavailable")
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
            case .enable: L10n.string("permission.action.enable")
            case .open: L10n.string("permission.action.open")
            case .settings: L10n.string("permission.action.settings")
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
                label: L10n.string("permission.application.not_installed"),
                symbol: "minus.circle",
                isGranted: false,
                action: nil
            )
        case .notRunning:
            Self(
                label: L10n.string("permission.application.not_needed"),
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
    /// Match the harmless event sent by `requestConsent`.
    ///
    /// Wildcard event codes do not identify a concrete capability for TCC to
    /// request. Using the exact read-only event here keeps status checks and
    /// the user-initiated consent request consistent.
    static let eventClass = AEEventClass(kAECoreSuite)
    static let eventID = AEEventID(kAEGetData)

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

    static func reconcile(
        observed: CairnPermissionState,
        knownDenied: Bool
    ) -> CairnPermissionState {
        if observed == .notRequested, knownDenied {
            return .needsSettings
        }
        return observed
    }

    static func state(bundleID: String) -> CairnPermissionState {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let target = descriptor.aeDesc else { return .unavailable }
        // Never ask from here: this runs on every refresh, and a status read
        // must not become a system interruption.
        let status = AEDeterminePermissionToAutomateTarget(
            target,
            eventClass,
            eventID,
            false
        )
        return classify(status)
    }

    /// Ask the system for consent to send the same harmless event we probe.
    ///
    /// A wildcard event cannot produce a useful consent request. The previous
    /// workaround (`tell application ... to return name`) was not sufficient
    /// either: AppleScript can evaluate it locally without dispatching an Apple
    /// Event, so clicking Enable produced no TCC request and no prompt.
    static func requestConsent(
        bundleID: String,
        applicationName: String
    ) -> CairnPermissionState {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let target = descriptor.aeDesc else {
            Logger.access.error(
                "consent: cannot resolve \(applicationName, privacy: .public)"
            )
            return .unavailable
        }

        Logger.access.notice("consent: asking \(applicationName, privacy: .public)")
        let status = AEDeterminePermissionToAutomateTarget(
            target,
            eventClass,
            eventID,
            true
        )
        let result = classify(status)
        Logger.access.notice(
            """
            consent: \(applicationName, privacy: .public) returned \
            \(status, privacy: .public) (\(result.label, privacy: .public))
            """
        )
        return result
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

/// Owns Cairn's permission state and the access-center window that exposes it.
///
/// Permission completion is never stored as a one-time boolean: every status
/// shown in the access center is refreshed from the operating system.
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
        static let accessibilityRequested = "cairn.permissions.accessibilityRequested"
        static let legacyAXPromptShown = "cairn.trailfinder.axPromptShown"
    }


    private var terminalAccess: AutomationAccess {
        AutomationAccess(
            kind: .terminal,
            title: L10n.string("access.terminal.title"),
            detail: L10n.string("access.terminal.short_detail"),
            bundleID: "com.apple.Terminal",
            scriptName: "Terminal",
            icon: "terminal"
        )
    }
    private var itermAccess: AutomationAccess {
        AutomationAccess(
            kind: .iterm,
            title: L10n.string("access.iterm.title"),
            detail: L10n.string("access.iterm.short_detail"),
            bundleID: "com.googlecode.iterm2",
            scriptName: "iTerm2",
            icon: "rectangle.split.2x1"
        )
    }

    private var centerWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// True while the access center is the second onboarding step. It shows a
    /// Skip / Done footer, and closing it — by either button or the close
    /// button — hands the flow back to whoever presented it.
    @Published private(set) var isOnboardingStep = false
    private var onboardingStepCompletion: (() -> Void)?
    private var refreshGeneration = 0
    /// TCC can return `errAEEventNotPermitted` for a real request while its
    /// preflight still reports `errAEEventWouldRequireUserConsent`. Remember
    /// the stronger result for this run so the UI does not jump from Off back
    /// to Optional before the user can act on it.
    private var deniedAutomationBundleIDs: Set<String> = []

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
        workspaceObservers.append(
            center.addObserver(
                forName: .cairnLanguageDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshLocalization() }
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

    func presentCenter() {
        refresh()

        if let centerWindow {
            NSApp.activate(ignoringOtherApps: true)
            centerWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 516),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("access.window.title")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: PermissionCenterView(
                experience: self,
                languageSettings: .shared
            )
        )
        window.center()
        centerWindow = window

        // Closing the window during the onboarding step means the same as
        // Skip: the step is optional, and every grant stays available later
        // from Access in the menu.
        workspaceObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.concludeOnboardingStep() }
            }
        )

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Present the access center as the second step of first-run onboarding:
    /// same window, plus a Skip / Done footer. `completion` runs exactly once,
    /// whichever way the step ends.
    func presentCenterAsOnboardingStep(completion: @escaping () -> Void) {
        isOnboardingStep = true
        onboardingStepCompletion = completion
        presentCenter()
    }

    func finishOnboardingStep() {
        guard isOnboardingStep else { return }
        centerWindow?.close()
        // The close notification concludes the step; closing an already
        // closed window (button after X) falls through to conclude directly.
        concludeOnboardingStep()
    }

    private func concludeOnboardingStep() {
        guard isOnboardingStep else { return }
        isOnboardingStep = false
        let completion = onboardingStepCompletion
        onboardingStepCompletion = nil
        completion?()
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
        let trusted = AXIsProcessTrustedWithOptions(options)
        Logger.access.notice("accessibility asked, trusted=\(trusted, privacy: .public)")
        refresh()
    }

    func handleAutomation(_ kind: AutomationAccess.Kind) {
        guard let access = access(for: kind) else {
            Logger.access.error("no automation target for \(kind.rawValue, privacy: .public)")
            return
        }
        let resolved = presentation(for: kind)
        Logger.access.notice(
            """
            \(kind.rawValue, privacy: .public) tapped: state \(resolved.label, privacy: .public), \
            action \(String(describing: resolved.action), privacy: .public)
            """
        )
        switch resolved.action {
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
                title: L10n.format("access.browser.dynamic_title", $0.scriptName),
                detail: L10n.string("access.browser.short_detail"),
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
                self.terminalState = self.resolvedAutomationState(
                    results[.terminal] ?? .unavailable,
                    bundleID: self.terminalAccess.bundleID
                )
            }
            if applicationStates[.iterm] == .running {
                self.itermState = self.resolvedAutomationState(
                    results[.iterm] ?? .unavailable,
                    bundleID: self.itermAccess.bundleID
                )
            }
            if let browser, applicationStates[.browser] == .running {
                self.browserState = self.resolvedAutomationState(
                    results[.browser] ?? .unavailable,
                    bundleID: browser.bundleID
                )
            }
        }
    }

    private func refreshLocalization() {
        centerWindow?.title = L10n.string("access.window.title")
        refresh()
    }

    private func migrateLegacyState() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PreferenceKey.accessibilityRequested) else { return }
        if defaults.bool(forKey: PreferenceKey.legacyAXPromptShown) {
            defaults.set(true, forKey: PreferenceKey.accessibilityRequested)
        }
    }

    private func access(for kind: AutomationAccess.Kind) -> AutomationAccess? {
        switch kind {
        case .terminal: terminalAccess
        case .iterm: itermAccess
        case .browser: browserAccess
        }
    }

    private func requestAutomation(_ access: AutomationAccess) {
        setState(.checking, for: access.kind)
        Task { [weak self] in
            // Detached because the consent dialog is modal to us: asking on the
            // main actor would freeze the access center behind it.
            let state = await Task.detached {
                AutomationPermissionProbe.requestConsent(
                    bundleID: access.bundleID,
                    applicationName: access.scriptName
                )
            }.value
            self?.rememberAutomationState(state, bundleID: access.bundleID)
            self?.setState(state, for: access.kind)
            if state == .needsSettings {
                self?.openPrivacySettings(anchor: "Privacy_Automation")
            } else {
                self?.refresh()
            }
        }
    }

    private func rememberAutomationState(
        _ state: CairnPermissionState,
        bundleID: String
    ) {
        switch state {
        case .granted:
            deniedAutomationBundleIDs.remove(bundleID)
        case .needsSettings:
            deniedAutomationBundleIDs.insert(bundleID)
        case .checking, .notRequested, .unavailable:
            break
        }
    }

    private func resolvedAutomationState(
        _ observed: CairnPermissionState,
        bundleID: String
    ) -> CairnPermissionState {
        rememberAutomationState(observed, bundleID: bundleID)
        return AutomationPermissionProbe.reconcile(
            observed: observed,
            knownDenied: deniedAutomationBundleIDs.contains(bundleID)
        )
    }

    private func setState(
        _ state: CairnPermissionState,
        for kind: AutomationAccess.Kind
    ) {
        switch kind {
        case .terminal:
            terminalState = state
        case .iterm:
            itermState = state
        case .browser:
            browserState = state
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

private struct PermissionCenterView: View {
    @ObservedObject var experience: PermissionExperience
    @ObservedObject var languageSettings: LanguageSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cairn.Space.xl) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Cairn.Space.xs) {
                        Text(L10n.string("access.title"))
                            .font(.title2.weight(.semibold))
                        Text(L10n.string("access.subtitle"))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: experience.refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("access.refresh"))
                }

                PermissionAccessRow(
                    icon: "macwindow",
                    title: L10n.string("access.editor.title"),
                    detail: L10n.string("access.editor.detail"),
                    presentation: experience.accessibilityPresentation,
                    action: experience.requestAccessibility
                )

                Divider()

                automationRow(
                    icon: "terminal",
                    title: L10n.string("access.terminal.title"),
                    detail: L10n.string("access.terminal.detail"),
                    kind: .terminal
                )
                automationRow(
                    icon: "rectangle.split.2x1",
                    title: L10n.string("access.iterm.title"),
                    detail: L10n.string("access.iterm.detail"),
                    kind: .iterm
                )

                if let browser = experience.browserAccess {
                    automationRow(
                        icon: browser.icon,
                        title: browser.title,
                        detail: L10n.string("access.browser.detail"),
                        kind: .browser
                    )
                } else {
                    PermissionAccessRow(
                        icon: "globe",
                        title: L10n.string("access.browser.title"),
                        detail: L10n.string("access.browser.unsupported"),
                        presentation: .permission(.unavailable),
                        action: {}
                    )
                }
            }
            .padding(Cairn.Space.xxl)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if experience.isOnboardingStep {
                // The onboarding footer. Skip and Done lead to the same place
                // — the step is optional and the rows above are the actual
                // work — but both words have to exist: a person who granted
                // nothing is skipping, and one who granted something is done.
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: Cairn.Space.md) {
                        Text(L10n.string("access.onboarding.hint"))
                            .font(.caption)
                            .foregroundStyle(Cairn.Ink.tertiary)

                        Spacer()

                        Button(L10n.string("access.onboarding.skip")) {
                            experience.finishOnboardingStep()
                        }

                        Button(L10n.string("access.onboarding.done")) {
                            experience.finishOnboardingStep()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.horizontal, Cairn.Space.xxl)
                    .padding(.vertical, Cairn.Space.lg)
                }
                .background(.bar)
            }
        }
        .frame(width: 500, height: 496)
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
                    .help(L10n.string("access.open_settings"))
                    .accessibilityLabel(L10n.string("access.settings"))
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
