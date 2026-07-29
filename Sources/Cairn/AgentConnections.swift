import AppKit
import Combine
import Foundation
import SwiftUI
import os

extension Logger {
    static let connect = Logger(subsystem: "app.cairn.Cairn", category: "connect")
}

// MARK: - Protocol

/// How one agent stands in relation to Cairn, as `cairn_connect.py` reports it.
///
/// The bridge answers in codes, never sentences: this window is localized and
/// English prose arriving inside a JSON payload could never be. An unknown
/// code degrades to `.attention` rather than failing the whole read — a newer
/// bridge beside an older app must still be legible.
enum AgentConnectionState: String, Decodable, Sendable {
    case notInstalled = "not_installed"
    case available
    case connected
    case attention

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentConnectionState(rawValue: raw) ?? .attention
    }

    var label: String {
        switch self {
        case .notInstalled: L10n.string("connect.state.not_installed")
        case .available: L10n.string("connect.state.available")
        case .connected: L10n.string("connect.state.connected")
        case .attention: L10n.string("connect.state.attention")
        }
    }

    var symbol: String {
        switch self {
        case .notInstalled: "minus.circle"
        case .available: "circle"
        case .connected: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        }
    }
}

struct AgentConnectionStatus: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let state: AgentConnectionState
    /// A code naming what is imperfect — see `connect.issue.*` in the strings
    /// file. Present on healthy rows too: a connected runtime can still be
    /// running someone else's copy of the bridge, and the window writes one
    /// here when a user declines the step a connection needed.
    var issue: String?
    /// Free text the bridge could not express as a code — paths, parser
    /// errors. Shown verbatim, never translated.
    let message: String?
    /// True when connecting needs the user's explicit consent first.
    let consent: Bool
    /// Something true and useful that Cairn cannot do on the user's behalf.
    /// Carried by a status when it is permanent (Codex will not run an
    /// untrusted hook), and grafted on from an action's result when it is a
    /// consequence of what just happened (a running agent has to be restarted).
    var followUp: String?

    enum CodingKeys: String, CodingKey {
        case id, state, issue, message, consent
        case followUp = "follow_up"
    }

    var isConnected: Bool { state == .connected }
}

struct AgentConnectionReport: Decodable, Sendable {
    let schema: Int
    let runtimes: [AgentConnectionStatus]
}

struct AgentConnectionOutcome: Decodable, Sendable {
    let id: String
    let ok: Bool
    let message: String?
    let issue: String?
    let followUp: String?
    let state: AgentConnectionStatus

    enum CodingKeys: String, CodingKey {
        case id, ok, message, issue, state
        case followUp = "follow_up"
    }
}

// MARK: - Bridge

/// Runs `cairn_connect.py` and nothing else.
///
/// Cairn deliberately does not reimplement the installers in Swift. Every
/// config merge already exists in Python, is already tested from the command
/// line, and is what the documentation describes; a second implementation
/// would be a second set of bugs and a second definition of "connected".
enum AgentConnectionBridge {
    enum Failure: Error, Sendable {
        case scriptMissing
        case timedOut
        case launchFailed(String)
        case malformed(String)
    }

    static let statusTimeout: TimeInterval = 30
    /// Connecting can restart the OpenClaw Gateway, which is the slow one.
    static let actionTimeout: TimeInterval = 180

    /// Where the bridge lives, in each of the three shapes Cairn runs in.
    static func scriptURL() -> URL? {
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CAIRN_SCRIPTS_DIR"] {
            let candidate = URL(fileURLWithPath: override)
                .appendingPathComponent("cairn_connect.py")
            if manager.isReadableFile(atPath: candidate.path) { return candidate }
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("cairn_connect.py"),
           manager.isReadableFile(atPath: bundled.path) {
            return bundled
        }
        // Development: `swift run` puts the executable in .build/<config>, so
        // walk up until the checkout's Scripts directory appears.
        var directory = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Scripts")
                .appendingPathComponent("cairn_connect.py")
            if manager.isReadableFile(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    /// A `Process` is not `Sendable`, and the watchdog has to reach it from
    /// another queue. The box is the whole exception, and it is only ever
    /// touched from `run(_:timeout:)`.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    static func run(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        guard let script = scriptURL() else { throw Failure.scriptMissing }

        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments

        // stdout carries the payload and nothing else — the bridge moves its
        // own diagnostics, and those of every CLI it drives, onto stderr. That
        // is sent to a file rather than a second pipe so a chatty installer
        // can never fill a buffer and wedge the process we are waiting on.
        let output = Pipe()
        process.standardOutput = output
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-connect-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)
        process.standardError = logHandle ?? FileHandle.nullDevice
        defer {
            try? logHandle?.close()
            try? FileManager.default.removeItem(at: log)
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let watchdog = DispatchWorkItem {
            if box.process.isRunning { box.process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        // The watchdog is the only thing that signals this process, so an
        // uncaught signal means the deadline passed.
        let timedOut = process.terminationReason == .uncaughtSignal

        if data.isEmpty {
            if timedOut { throw Failure.timedOut }
            let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw Failure.malformed(diagnostics.trimmed(to: 400))
        }
        return data
    }

    static func status() throws -> [AgentConnectionStatus] {
        let data = try run(["status", "--json"], timeout: statusTimeout)
        do {
            return try JSONDecoder().decode(AgentConnectionReport.self, from: data).runtimes
        } catch {
            throw Failure.malformed(String(data: data, encoding: .utf8)?.trimmed(to: 400) ?? "")
        }
    }

    static func perform(
        _ action: String,
        runtime: String,
        allowConversationAccess: Bool
    ) throws -> AgentConnectionOutcome {
        var arguments = [action, runtime, "--json"]
        if allowConversationAccess { arguments.append("--allow-conversation-access") }
        let data = try run(arguments, timeout: actionTimeout)
        do {
            return try JSONDecoder().decode(AgentConnectionOutcome.self, from: data)
        } catch {
            throw Failure.malformed(String(data: data, encoding: .utf8)?.trimmed(to: 400) ?? "")
        }
    }
}

private extension String {
    func trimmed(to limit: Int) -> String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= limit ? value : String(value.prefix(limit)) + "…"
    }
}

// MARK: - Identity

/// Which agents this window is about, in the order it lists them, what each one
/// is called, and which colour it owns.
///
/// The window's own rows still carry no icon and no colour: every row there
/// says the same kind of thing about the same kind of subject, and a glyph per
/// agent only makes four identical rows look like four different ones. A mark
/// earns its place where agents are told *apart* rather than listed — the menu
/// bar's connected count, and the notes themselves. See `Cairn.Tone`.
struct AgentRuntimeIdentity: Sendable {
    let id: String
    let name: String
    /// The note `source` this runtime writes, which is what `Cairn.Agent`
    /// keys its colours on. Only Claude Code disagrees with its runtime id.
    let toneSource: String

    static let all: [AgentRuntimeIdentity] = [
        AgentRuntimeIdentity(id: "codex", name: "Codex", toneSource: "codex"),
        AgentRuntimeIdentity(id: "claude", name: "Claude Code", toneSource: "claude-code"),
        AgentRuntimeIdentity(id: "openclaw", name: "OpenClaw", toneSource: "openclaw"),
        AgentRuntimeIdentity(id: "opencode", name: "OpenCode", toneSource: "opencode"),
        AgentRuntimeIdentity(id: "hermes", name: "Hermes", toneSource: "hermes"),
    ]

    static func identity(for id: String) -> AgentRuntimeIdentity {
        all.first { $0.id == id }
            ?? AgentRuntimeIdentity(id: id, name: id.capitalized, toneSource: id)
    }
}

// MARK: - Center

@MainActor
final class AgentConnectionCenter: ObservableObject {
    static let shared = AgentConnectionCenter()

    @Published private(set) var runtimes: [AgentConnectionStatus] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var busy: Set<String> = []
    /// Set when the bridge itself could not be run — a missing script, a
    /// timeout. Distinct from a runtime that reported a problem of its own.
    @Published private(set) var failure: String?
    @Published private(set) var lastOutcome: AgentConnectionOutcome?
    /// True while the window is the first-run gate: it was presented because
    /// nothing is connected yet, and it shows a Start button that stays
    /// disabled until at least one agent is.
    @Published private(set) var isOnboarding = false
    /// Whether the app is allowed to look like an app: menu bar icon, desktop
    /// control. False from launch until onboarding completes, so an ignored
    /// gate window is an app that has not started — not one quietly running
    /// behind a window nobody read.
    @Published private(set) var surfacesActive: Bool

    /// True until onboarding has completed once on this Mac.
    nonisolated static var needsOnboardingGate: Bool {
        UserDefaults.standard.integer(forKey: PreferenceKey.journeyVersion)
            < currentJourneyVersion
    }

    private enum PreferenceKey {
        static let journeyVersion = "cairn.connect.journeyVersion"
    }

    private nonisolated static let currentJourneyVersion = 1

    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var hasLoaded = false

    private init() {
        surfacesActive = !Self.needsOnboardingGate
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .cairnLanguageDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.window?.title = L10n.string("connect.window.title")
                }
            }
        )
    }

    /// The runtimes this window is about, in a fixed order. The bridge also
    /// knows how to install the `cairn-save` skill, but that is a Cairn
    /// feature rather than an agent to connect — it stays on the command line.
    var agents: [AgentConnectionStatus] {
        AgentRuntimeIdentity.all.compactMap { identity in
            runtimes.first { $0.id == identity.id }
        }
    }

    /// Detected but not yet connected — what decides whether Cairn offers the
    /// window on a first launch.
    var pendingCount: Int {
        agents.filter { $0.state == .available || $0.state == .attention }.count
    }

    /// Which coding agents are actually sending Cairn their turns, in the fixed
    /// order — what the menu bar draws marks for.
    var connectedAgents: [Cairn.Agent] {
        agents.filter(\.isConnected).map {
            .identity(for: AgentRuntimeIdentity.identity(for: $0.id).toneSource)
        }
    }

    /// How many coding agents are actually sending Cairn their turns — the one
    /// number the menu bar shows.
    var connectedAgentCount: Int {
        connectedAgents.count
    }

    func status(for id: String) -> AgentConnectionStatus? {
        runtimes.first { $0.id == id }
    }

    /// Called once at launch: detect, and offer the window if this Mac has
    /// agents that are not sending Cairn anything yet.
    func start() {
        refresh(presentWhenPending: true)
    }

    func refresh(presentWhenPending: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try AgentConnectionBridge.status() }
            }.value

            guard let self else { return }
            self.isRefreshing = false
            self.hasLoaded = true
            switch outcome {
            case .success(let runtimes):
                self.runtimes = runtimes
                self.failure = nil
                if presentWhenPending { self.presentIfNeeded() }
            case .failure(let error):
                self.failure = Self.describe(error)
                Logger.connect.error("status failed: \(self.failure ?? "", privacy: .public)")
                if presentWhenPending, !self.surfacesActive {
                    self.isOnboarding = true
                    self.presentWindow()
                }
            }
        }
    }

    func connect(_ id: String) {
        guard let status = status(for: id) else { return }
        if id == "openclaw", status.consent {
            askForConsentThenConnect(id)
            return
        }
        perform("connect", id: id, allowConversationAccess: false)
    }

    /// Cancelling has to leave a mark. Silence after a press is indistinguishable
    /// from a press that did not register, and the row simply settling back to
    /// "ready to connect" reads as a failure with no cause.
    private func askForConsentThenConnect(_ id: String) {
        requestConversationConsent { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.annotate(id, issue: "no_consent")
                Logger.connect.notice("connect \(id, privacy: .public) declined by the user")
                return
            }
            self.perform("connect", id: id, allowConversationAccess: true)
        }
    }

    private func annotate(_ id: String, issue: String) {
        guard let index = runtimes.firstIndex(where: { $0.id == id }) else { return }
        var updated = runtimes[index]
        updated.issue = issue
        runtimes[index] = updated
    }

    func disconnect(_ id: String) {
        perform("disconnect", id: id, allowConversationAccess: false)
    }

    private func perform(_ action: String, id: String, allowConversationAccess: Bool) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        failure = nil
        Logger.connect.notice("\(action, privacy: .public) \(id, privacy: .public)")

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try AgentConnectionBridge.perform(
                        action,
                        runtime: id,
                        allowConversationAccess: allowConversationAccess
                    )
                }
            }.value

            guard let self else { return }
            self.busy.remove(id)
            switch outcome {
            case .success(let result):
                self.lastOutcome = result
                self.merge(result.state, followUp: result.followUp)
                // The bridge answered, but with a failure. Its message is the
                // only explanation there is — a row that just snaps back to
                // "ready to connect" reads as a click that did nothing.
                if !result.ok, let message = result.message, !message.isEmpty {
                    self.failure = message
                }
                // The bridge refused for want of consent, which means what this
                // window believed about the runtime was out of date. Ask now
                // and try again, rather than leaving the row exactly as it was.
                if result.issue == "needs_consent", action == "connect" {
                    self.askForConsentThenConnect(id)
                    return
                }
                Logger.connect.notice(
                    """
                    \(action, privacy: .public) \(id, privacy: .public) → \
                    \(result.state.state.rawValue, privacy: .public)
                    """
                )
            case .failure(let error):
                self.failure = Self.describe(error)
                Logger.connect.error(
                    "\(action, privacy: .public) \(id, privacy: .public) failed: \(self.failure ?? "", privacy: .public)"
                )
                self.refresh()
            }
        }
    }

    private func merge(_ status: AgentConnectionStatus, followUp: String? = nil) {
        var merged = status
        if merged.followUp == nil { merged.followUp = followUp }
        if let index = runtimes.firstIndex(where: { $0.id == merged.id }) {
            runtimes[index] = merged
        } else {
            runtimes.append(merged)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let failure = error as? AgentConnectionBridge.Failure else {
            return error.localizedDescription
        }
        switch failure {
        case .scriptMissing:
            return L10n.string("connect.failure.script_missing")
        case .timedOut:
            return L10n.string("connect.failure.timed_out")
        case .launchFailed(let detail):
            return detail
        case .malformed(let detail):
            return detail.isEmpty ? L10n.string("connect.failure.unreadable") : detail
        }
    }

    // MARK: Windows

    func presentWindow() {
        refresh()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("connect.window.title")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: AgentConnectionsView(center: self, languageSettings: .shared)
        )
        window.center()
        self.window = window

        // The red close button during onboarding: connecting an agent was the
        // finish line, not pressing a particular button — so a close with one
        // connected completes the flow. A close with none declines it, and
        // declining quits Cairn: without an agent it is a listener nothing
        // will ever write to, and a menu bar icon with no purpose is worse
        // than no icon. The offer stays unspent, so the next launch asks
        // again.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isOnboarding else { return }
                    self.isOnboarding = false
                    if self.connectedAgentCount > 0 {
                        self.completeOnboarding()
                    } else {
                        Logger.connect.notice("onboarding declined — quitting")
                        NSApp.terminate(nil)
                    }
                }
            }
        )

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The first-run gate. Until an agent is connected the app stays
    /// surfaceless — no menu bar icon, no desktop control — and this window
    /// is all there is of Cairn. Completing it (or arriving already
    /// connected, as an upgrade does) is what turns the rest of the app on.
    func presentIfNeeded() {
        guard hasLoaded else { return }
        guard Self.needsOnboardingGate else { return }
        // Already connected — an upgrade from a version without this flow, or
        // a command-line setup. There is nothing left to onboard.
        guard connectedAgentCount == 0 else {
            activateSurfaces(introducingControl: false)
            return
        }
        isOnboarding = true
        presentWindow()
    }

    /// The user pressed Start (or closed the window with an agent connected):
    /// the app is now in a state where it can actually receive something, so
    /// the one-time offer is spent and the desktop control gets its turn.
    func finishOnboarding() {
        guard isOnboarding else { return }
        isOnboarding = false
        window?.close()
        completeOnboarding()
    }

    /// The first agent is connected: spend the one-time offer, then walk the
    /// second step — access. It is optional and skippable, but a first run is
    /// the one moment the user should at least see that these permissions
    /// exist; afterwards they only live behind a menu item. The app's
    /// surfaces wait until the step is answered, so onboarding stays one
    /// window at a time.
    private func completeOnboarding() {
        UserDefaults.standard.set(
            Self.currentJourneyVersion,
            forKey: PreferenceKey.journeyVersion
        )
        PermissionExperience.shared.presentCenterAsOnboardingStep { [weak self] in
            self?.activateSurfaces(introducingControl: true)
        }
    }

    /// Let the app become visible. The control introduces itself only when a
    /// real first run just finished — an upgrade that arrives already
    /// connected gets its surfaces without a lecture.
    private func activateSurfaces(introducingControl: Bool) {
        UserDefaults.standard.set(
            Self.currentJourneyVersion,
            forKey: PreferenceKey.journeyVersion
        )
        guard !surfacesActive else { return }
        surfacesActive = true
        NotificationCenter.default.post(
            name: introducingControl ? .cairnOnboardingDidFinish : .cairnAppShouldStart,
            object: nil
        )
    }

    private func requestConversationConsent(_ completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = L10n.string("connect.consent.title")
        alert.informativeText = L10n.string("connect.consent.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string("connect.consent.allow"))
        alert.addButton(withTitle: L10n.string("connect.consent.cancel"))

        if let window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

// MARK: - Views

struct AgentConnectionsView: View {
    @ObservedObject var center: AgentConnectionCenter
    @ObservedObject var languageSettings: LanguageSettings

    private var visible: [AgentConnectionStatus] {
        center.agents
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cairn.Space.xl) {
                header

                if let failure = center.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Cairn.Status.degraded)
                        .textSelection(.enabled)
                }

                ForEach(visible) { status in
                    AgentConnectionRow(
                        identity: .identity(for: status.id),
                        status: status,
                        isBusy: center.busy.contains(status.id),
                        connect: { center.connect(status.id) },
                        disconnect: { center.disconnect(status.id) }
                    )
                    if status.id != visible.last?.id { Divider() }
                }

                if visible.isEmpty, center.failure == nil {
                    Text(L10n.string("connect.empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Label(L10n.string("connect.footer"), systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Cairn.Space.xxl)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if center.isOnboarding {
                // The first-run gate, pinned to the bottom of the window: Cairn
                // without a connected agent is a listener nothing will ever
                // write to, so Start holds the line until at least one row
                // above says connected.
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: Cairn.Space.md) {
                        if center.connectedAgentCount == 0 {
                            Text(L10n.string("connect.onboarding.requirement"))
                                .font(.caption)
                                .foregroundStyle(Cairn.Ink.tertiary)
                        }

                        Spacer()

                        Button(L10n.string("connect.onboarding.start")) {
                            center.finishOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(center.connectedAgentCount == 0)
                    }
                    .padding(.horizontal, Cairn.Space.xxl)
                    .padding(.vertical, Cairn.Space.lg)
                }
                .background(.bar)
            }
        }
        .frame(width: 520, height: 500)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Cairn.Space.xs) {
                Text(L10n.string("connect.title"))
                    .font(.title2.weight(.semibold))
                Text(L10n.string("connect.subtitle"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                center.refresh()
            } label: {
                if center.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(center.isRefreshing)
            .help(L10n.string("connect.refresh"))
        }
    }
}

/// One agent, on one line: name, state, and the one thing you can do about it.
///
/// A row only grows a second line when something is actually wrong, or right
/// after an action that leaves the user something to do. A standing note under
/// a healthy row — "remember to trust the hook" — is read once and then becomes
/// four lines of furniture.
private struct AgentConnectionRow: View {
    let identity: AgentRuntimeIdentity
    let status: AgentConnectionStatus
    let isBusy: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    private var agent: Cairn.Agent {
        .identity(for: identity.toneSource)
    }

    private var caption: String? {
        var lines: [String] = []
        if let issue = status.issue, let text = Self.localized("connect.issue.\(issue)") {
            lines.append(text)
        }
        if let followUp = status.followUp,
           status.state != .notInstalled,
           let text = Self.localized("connect.followup.\(followUp)") {
            lines.append(text)
        }
        if let message = status.message, !message.isEmpty, status.state == .attention {
            lines.append(message)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func localized(_ key: String) -> String? {
        let value = L10n.string(key)
        return value == key ? nil : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Cairn.Space.xs) {
            HStack(spacing: Cairn.Space.md) {
                AgentGlyph(agent: agent, size: Cairn.Metrics.agentGlyphRow)

                Text(identity.name)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: Cairn.Space.md)

                Label(
                    isBusy ? L10n.string("connect.state.working") : status.state.label,
                    systemImage: isBusy ? "ellipsis" : status.state.symbol
                )
                .font(.caption)
                .foregroundStyle(status.isConnected ? Cairn.Status.listening : Cairn.Ink.tertiary)

                controls
            }

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(status.state == .attention ? Cairn.Status.degraded : Cairn.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Cairn.Space.xs)
        .opacity(status.state == .notInstalled ? 0.55 : 1)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Cairn.Space.sm) {
            switch status.state {
            case .notInstalled:
                EmptyView()
            case .available:
                Button(L10n.string("connect.action.connect"), action: connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
            case .attention:
                Button(L10n.string("connect.action.repair"), action: connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
            case .connected:
                if status.issue != nil {
                    Button(L10n.string("connect.action.reconnect"), action: connect)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBusy)
                }
                Button(L10n.string("connect.action.disconnect"), action: disconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
            }
        }
    }
}
