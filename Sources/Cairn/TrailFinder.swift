import AppKit
import ScriptingBridge
import ApplicationServices
import Foundation
import os

/// 寻迹 — follow a note back to the window its turn ran in.
///
/// A hook records a `CairnLocator` while it is still inside the agent's
/// process tree. TrailFinder replays those clues, most precise first:
///
/// 1. Apple Terminal — match the session's tty against every tab (AppleScript).
/// 2. iTerm2 — match the session UUID from `ITERM_SESSION_ID` (AppleScript).
/// 3. Any GUI host (VS Code, Cursor, a desktop client…) — activate the exact
///    app the turn ran under, and if Accessibility is granted, raise the
///    window whose title mentions the working directory.
/// 4. Last resort — reveal the working directory in Finder, so a click always
///    lands somewhere.
///
/// AppleScript steps need the one-time Automation consent per target app;
/// window-level raising needs Accessibility. Every step degrades quietly to
/// the next when a permission is missing or a session no longer exists.
enum ConversationTrail {
    /// Codex Desktop's public handoff URL uses the same conversation UUID that
    /// Codex supplies to Stop hooks as `session_id`.
    static func codexThreadURL(for completion: CodexCompletion) -> URL? {
        let explicitSource = completion.source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let eventSource = completion.event
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased()
        guard (explicitSource?.isEmpty == false ? explicitSource : eventSource) == "codex",
              UUID(uuidString: completion.sessionID) != nil else {
            return nil
        }
        return URL(string: "codex://threads/\(completion.sessionID)")
    }

    /// Hermes Web Dashboard documents `/chat?resume=<session-id>` as its
    /// session-recovery route. The bridge records its Dashboard base only for
    /// browser-embedded turns, so Desktop and CLI notes retain their existing
    /// app/terminal trails.
    static func hermesDashboardSessionURL(for completion: CodexCompletion) -> URL? {
        guard completion.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hermes",
              !completion.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              completion.sessionID != "unknown-session",
              let webURL = completion.locator?.webURL,
              var components = URLComponents(string: webURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.hasSuffix("chat")
            ? "/\(basePath)"
            : "/\(basePath.isEmpty ? "" : "\(basePath)/")chat"

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "resume" }
        queryItems.append(URLQueryItem(name: "resume", value: completion.sessionID))
        components.queryItems = queryItems
        return components.url
    }

    /// Where a Mac keeps its applications, the user's own copy first.
    ///
    /// A source fallback knows an agent's app by the name on its icon, not by
    /// a bundle id: Launch Services can only answer for ids it has already
    /// registered, so the search widens to the folders apps actually live in.
    static func applicationBundleCandidates(
        named name: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let bundleName = "\(name).app"
        return [
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
        ].map { $0.appendingPathComponent(bundleName) }
    }

    /// Prefer a thread deep link only when the turn actually lived in Codex
    /// Desktop. CLI and editor turns should still return to their terminal or
    /// editor, even though Codex Desktop can also display the same session.
    static func wasHostedByCodexDesktop(_ locator: CairnLocator?) -> Bool {
        guard let locator else { return false }

        return hostBundlePaths(locator).contains { path in
            let appURL = URL(fileURLWithPath: path)
            if Bundle(url: appURL)?.bundleIdentifier?.lowercased() == "com.openai.codex" {
                return true
            }
            let appName = appURL.lastPathComponent.lowercased()
            return appName == "codex.app" || appName == "chatgpt.app"
        }
    }

    /// True when the turn ran inside the Claude desktop app.
    ///
    /// Claude Code's desktop harness is a background-only `claude.app` nested
    /// under the desktop application, so the ancestry records two Claude
    /// bundles for one turn and either layer settles the question. A turn run
    /// from a terminal has neither: the standalone CLI is a bare executable
    /// under `~/.local/share/claude`, not an app bundle.
    ///
    /// What hangs on the answer is `claude://resume?session=<uuid>`, which
    /// *imports* a CLI session into the desktop app. For a turn that already
    /// ran there the import is a second entry for one conversation, and the
    /// user's sidebar fills with untitled twins of everything they clicked.
    static func wasHostedByClaudeDesktop(_ locator: CairnLocator?) -> Bool {
        guard let locator else { return false }

        return hostBundlePaths(locator).contains { path in
            let appURL = URL(fileURLWithPath: path)
            let bundleID = Bundle(url: appURL)?.bundleIdentifier?.lowercased()
            if bundleID == "com.anthropic.claudefordesktop" || bundleID == "com.anthropic.claude-code" {
                return true
            }
            return appURL.lastPathComponent.lowercased() == "claude.app"
        }
    }

    /// The conversation this Claude Code turn belongs to, addressed by the id
    /// the desktop app files it under rather than the CLI's.
    ///
    /// `claude://resume?session=<cli-uuid>` is the obvious way in and the wrong
    /// one: it *imports* the transcript, filing a second session under
    /// `local_<cli-uuid>` beside the one the app already has, and rewriting the
    /// CLI transcript on the way through. This route asks for the session the
    /// app already holds, so nothing is created and nothing is rewritten.
    ///
    /// `/claude-code-desktop/<id>` is the app's older spelling of that route,
    /// kept working by a redirect the app itself maintains — a steadier thing
    /// to hard-code than the current internal name, which has already changed
    /// once. It costs one window reload, which is the price of not leaving a
    /// duplicate behind.
    static func claudeDesktopConversationURL(
        for completion: CodexCompletion,
        in store: URL? = nil
    ) -> URL? {
        guard completion.source?.lowercased() == "claude-code",
              UUID(uuidString: completion.sessionID) != nil,
              let desktopID = ClaudeDesktopSessions.sessionID(
                  forCLISession: completion.sessionID,
                  in: store
              ),
              let encoded = desktopID.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              ) else {
            return nil
        }
        return URL(string: "claude://claude.ai/claude-code-desktop/\(encoded)")
    }

    /// Every `.app` the turn ran under, innermost first.
    private static func hostBundlePaths(_ locator: CairnLocator) -> [String] {
        var paths = (locator.hostApps ?? []).compactMap(\.path)
        if let path = locator.hostAppPath, !paths.contains(path) {
            paths.append(path)
        }
        return paths
    }
}

// MARK: - Claude Desktop's session store

/// What the Claude desktop app knows about the sessions it runs.
///
/// Cairn reads it for exactly one fact: the id the app files a given CLI
/// session under. A hook only ever learns the CLI session id, and every way
/// into the app that takes one imports a second copy of the conversation.
///
/// Read-only, and never load-bearing: an unreadable store, a moved directory
/// or a layout Cairn does not recognize all answer "no session", and the trail
/// falls through to activating the app.
enum ClaudeDesktopSessions {
    static var defaultStore: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// The desktop app's own id for a CLI session, or nil when it does not
    /// hold that conversation.
    ///
    /// A Mac can carry two records for one conversation: the app's own, and a
    /// twin an earlier Cairn imported beside it. Both resume the same
    /// transcript, so nothing is lost either way — but the app's own is the
    /// row that carries the title the user recognizes, so it wins, and the
    /// twins quietly stop being anywhere Cairn sends them. An imported session
    /// is recognizable by the id the import derives: `local_<cli-uuid>`.
    /// Where that tells them apart, the liveliest record does.
    static func sessionID(forCLISession cliSessionID: String, in store: URL? = nil) -> String? {
        guard !cliSessionID.isEmpty else { return nil }
        let importedID = "local_\(cliSessionID)"

        var best: (id: String, ownedByTheApp: Bool, activity: Double)?
        for record in records(in: store ?? defaultStore) {
            guard let data = try? Data(contentsOf: record),
                  let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  fields["cliSessionId"] as? String == cliSessionID,
                  let id = fields["sessionId"] as? String,
                  !id.isEmpty else {
                continue
            }
            let candidate = (
                id: id,
                ownedByTheApp: id != importedID,
                activity: (fields["lastActivityAt"] as? Double) ?? 0
            )
            guard let winner = best else {
                best = candidate
                continue
            }
            if candidate.ownedByTheApp != winner.ownedByTheApp {
                if candidate.ownedByTheApp { best = candidate }
            } else if candidate.activity > winner.activity {
                best = candidate
            }
        }
        return best?.id
    }

    /// The store nests one directory per install and one per account inside
    /// it, so a Mac that has signed into two accounts holds two of them.
    private static func records(in store: URL) -> [URL] {
        func children(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        return children(store)
            .flatMap(children)
            .flatMap(children)
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
    }
}

@MainActor
enum TrailFinder {

    static func follow(_ completion: CodexCompletion) {
        // Asynchronous because the most precise steps may need a one-time
        // Automation consent, and that dialog must not block the app.
        Task { @MainActor in
            await followTrail(completion)
        }
    }

    private static func followTrail(_ completion: CodexCompletion) async {
        let locator = completion.locator
        // At most one consent dialog per click, spent on the most precise
        // step this note can use. Declining costs nothing: the trail simply
        // continues to the fuzzier fallbacks below, exactly as if the
        // permission were missing.
        var consentBudget = true

        if let tty = shortTTY(locator?.tty),
           locator?.termProgram == "Apple_Terminal",
           isRunning(bundleID: "com.apple.Terminal"),
           await ensureAutomationConsent(
               bundleID: "com.apple.Terminal",
               displayName: "Terminal",
               mayPrompt: &consentBudget
           ),
           selectTerminalTab(tty: tty) {
            return
        }

        if let session = itermUUID(locator?.itermSessionID),
           isRunning(bundleID: "com.googlecode.iterm2"),
           await ensureAutomationConsent(
               bundleID: "com.googlecode.iterm2",
               displayName: "iTerm2",
               mayPrompt: &consentBudget
           ),
           selectITermSession(uuid: session) {
            return
        }

        if let hermesSessionURL = ConversationTrail.hermesDashboardSessionURL(for: completion) {
            await reuseOrOpen(
                hermesSessionURL,
                preferredBrowserBundleID: nil,
                mayPrompt: &consentBudget
            )
            return
        }

        // A Claude Code turn that ran inside the desktop app is addressable at
        // CONVERSATION level, and that beats merely raising the app's window:
        // the desktop app has one window, and it is showing whatever session
        // the user opened last. Terminal and iTerm still win above — they are
        // the session's real home — and a turn hosted anywhere else falls
        // through to its own host, so an editor turn still returns to the
        // editor.
        if ConversationTrail.wasHostedByClaudeDesktop(locator),
           let conversation = ConversationTrail.claudeDesktopConversationURL(for: completion),
           NSWorkspace.shared.open(conversation) {
            return
        }

        // Codex/ChatGPT Desktop supports conversation-level navigation via
        // `codex://threads/<session_id>`. Use it before generic app activation
        // only when the captured host really was Codex Desktop; a Codex turn
        // run in VS Code should continue returning to VS Code.
        let codexThreadURL = ConversationTrail.codexThreadURL(for: completion)
        if ConversationTrail.wasHostedByCodexDesktop(locator),
           let codexThreadURL,
           NSWorkspace.shared.open(codexThreadURL) {
            return
        }

        if let app = hostApp(locator) {
            if app.isHidden { app.unhide() }
            unminimizeWindows(of: app)
            raiseBestWindow(of: app, matching: workspaceHints(for: completion))
            app.activate()
            return
        }

        // A browser-surfaced turn: return to its web UI.
        if let web = locator?.webURL, let url = URL(string: web) {
            await reuseOrOpen(
                url,
                preferredBrowserBundleID: locator?.browserBundleID,
                mayPrompt: &consentBudget
            )
            return
        }

        // Older Codex notes may not have a locator, or their original host may
        // already be gone. The stable session id still gives them an exact
        // conversation-level recovery path in Codex Desktop.
        if let codexThreadURL, NSWorkspace.shared.open(codexThreadURL) {
            return
        }

        if await followSourceFallback(completion, mayPrompt: &consentBudget) {
            return
        }

        revealInFinder(cwd: completion.cwd)
    }

    // MARK: - Source-level fallbacks

    /// Some turns run under processes with no reachable GUI ancestor — the
    /// Hermes gateway is parented by launchd, OpenClaw's webchat lives in a
    /// browser tab, and older notes predate the locator entirely. When the
    /// captured trail leads nowhere, fall back to what the *source* implies.
    private static func followSourceFallback(
        _ completion: CodexCompletion,
        mayPrompt: inout Bool
    ) async -> Bool {
        let source = completion.source?.lowercased() ?? ""
        switch source {
        case "hermes":
            return await activateOrLaunchApp(
                named: "Hermes",
                bundleIDs: ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"]
            )
        case "openclaw":
            // The gateway's web UI is where webchat conversations live.
            if let url = URL(string: "http://127.0.0.1:\(openClawGatewayPort())") {
                await reuseOrOpen(url, preferredBrowserBundleID: nil, mayPrompt: &mayPrompt)
                return true
            }
            return false
        case "claude-code":
            // The turn's host is gone — a terminal that has since closed, or a
            // note old enough to predate the locator. If the desktop app holds
            // the conversation anyway, that is still the way back to it.
            if let conversation = ConversationTrail.claudeDesktopConversationURL(for: completion),
               NSWorkspace.shared.open(conversation) {
                return true
            }
            // Nobody holds it. Now `claude://resume?session=<uuid>` is the
            // right tool rather than the wrong one: importing the transcript
            // is the only second life a dead terminal session has. It stays
            // withheld from turns that ran in the desktop app — if the lookup
            // above found nothing for one of those, the store moved under us,
            // and importing would leave the duplicate this all began with.
            if !ConversationTrail.wasHostedByClaudeDesktop(completion.locator),
               UUID(uuidString: completion.sessionID) != nil,
               let deepLink = URL(string: "claude://resume?session=\(completion.sessionID)"),
               NSWorkspace.shared.open(deepLink) {
                return true
            }
            return await activateOrLaunchApp(
                named: "Claude",
                bundleIDs: ["com.anthropic.claudefordesktop"]
            )
        default:
            return false
        }
    }

    /// Bring the agent's own app forward — launching it when it is closed,
    /// restoring it when its windows sit miniaturized in the Dock.
    ///
    /// A closed app used to fail this step outright and the trail fell through
    /// to `revealInFinder`, so clicking a Hermes note with Hermes quit opened
    /// the home folder. An installed app is the honest reading of that click,
    /// running or not; only a missing one should hand the trail back.
    ///
    /// A *minimized* app was the same click with a quieter failure: `activate()`
    /// makes an app frontmost but never un-miniaturizes it, so the menu bar
    /// changed and the window stayed in the Dock. So a running app takes the
    /// same launch path as a closed one — opening an already-running app sends
    /// it the reopen event, which is exactly what a Dock icon click does, and
    /// needs no Accessibility grant to work.
    private static func activateOrLaunchApp(named name: String, bundleIDs: [String]) async -> Bool {
        let running = runningApp(named: name, bundleIDs: bundleIDs)
        if let running {
            // Cmd-H'd apps hide rather than miniaturize, and reopen alone does
            // not always bring those back.
            if running.isHidden { running.unhide() }
            // Belt and braces for an app that ignores reopen; a no-op when
            // Cairn has no Accessibility grant.
            unminimizeWindows(of: running)
        }

        guard let appURL = running?.bundleURL ?? installedAppURL(named: name, bundleIDs: bundleIDs) else {
            // Running from a bundle we cannot name: activation is all we have.
            running?.activate()
            return running != nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
            return true
        } catch {
            Logger.trail.error(
                """
                Could not launch \(name, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            running?.activate()
            return running != nil
        }
    }

    private static func runningApp(named name: String, bundleIDs: [String]) -> NSRunningApplication? {
        let ids = Set(bundleIDs.map { $0.lowercased() })
        return NSWorkspace.shared.runningApplications.first {
            guard $0.activationPolicy == .regular else { return false }
            if let bundleID = $0.bundleIdentifier?.lowercased(), ids.contains(bundleID) {
                return true
            }
            return $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
                || $0.bundleURL?.lastPathComponent.lowercased() == "\(name.lowercased()).app"
        }
    }

    private static func installedAppURL(named name: String, bundleIDs: [String]) -> URL? {
        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        let manager = FileManager.default
        return ConversationTrail.applicationBundleCandidates(named: name).first {
            manager.fileExists(atPath: $0.path)
        }
    }

    private static func openClawGatewayPort() -> Int {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = root["gateway"] as? [String: Any],
              let port = gateway["port"] as? Int else {
            return 18789
        }
        return port
    }

    // MARK: - Apple Terminal

    private static func shortTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "??" else { return nil }
        return tty.replacingOccurrences(of: "/dev/", with: "")
    }

    private static func selectTerminalTab(tty: String) -> Bool {
        guard isRunning(bundleID: "com.apple.Terminal"),
              automationGranted(bundleID: "com.apple.Terminal") else {
            return false
        }

        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t as text) ends with "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
        return runAppleScript(script) == "found"
    }

    // MARK: - iTerm2

    private static func itermUUID(_ sessionID: String?) -> String? {
        // ITERM_SESSION_ID looks like "w0t2p0:UUID".
        guard let sessionID, let colon = sessionID.firstIndex(of: ":") else { return nil }
        let uuid = String(sessionID[sessionID.index(after: colon)...])
        return uuid.isEmpty ? nil : uuid
    }

    private static func selectITermSession(uuid: String) -> Bool {
        guard isRunning(bundleID: "com.googlecode.iterm2"),
              automationGranted(bundleID: "com.googlecode.iterm2") else {
            return false
        }

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if id of s is "\(uuid)" then
                            select w
                            tell w to select t
                            tell t to select s
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
        return runAppleScript(script) == "found"
    }

    // MARK: - GUI hosts

    private static func hostApp(_ locator: CairnLocator?) -> NSRunningApplication? {
        guard let locator else { return nil }

        // First choice: climb the LIVE process tree from the pids we captured.
        // The innermost .app ancestor is not always a real GUI app — Claude
        // Code runs under a headless harness bundle whose parent is the Claude
        // desktop app — so keep climbing until a pid resolves to something the
        // window server will actually activate. This also rescues notes that
        // captured only the harness layer, as long as the session is alive.
        for seed in [locator.agentPID, locator.hostAppPID].compactMap({ $0 }) {
            if let app = climbToRunningApp(from: pid_t(seed)) {
                return app
            }
        }

        // The session's processes are gone: resolve captured bundle paths
        // instead, innermost first, against whatever is running now.
        var candidatePaths = (locator.hostApps ?? []).compactMap(\.path)
        if let path = locator.hostAppPath, !candidatePaths.contains(path) {
            candidatePaths.append(path)
        }
        for path in candidatePaths {
            // Same rule as the live climb above: a headless harness bundle is
            // something the window server will not activate, and returning it
            // would spend the click on nothing. Claude Code's own
            // `claude.app` is exactly that, and it is the innermost candidate
            // — so a match there must fall through to the desktop app behind
            // it rather than end the search.
            if let app = runningApp(bundlePath: path), app.activationPolicy != .prohibited {
                return app
            }
        }
        return nil
    }

    /// Walk up the parent-pid chain until a process resolves to an
    /// activatable application. Helpers and headless harness bundles resolve
    /// to nothing (or to a prohibited background app) and are skipped.
    private static func climbToRunningApp(from seed: pid_t) -> NSRunningApplication? {
        var pid = seed
        for _ in 0..<20 {
            guard pid > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy != .prohibited {
                return app
            }
            guard let parent = parentPID(of: pid) else { return nil }
            pid = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    private static func runningApp(bundlePath: String) -> NSRunningApplication? {
        if let bundleID = Bundle(url: URL(fileURLWithPath: bundlePath))?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundlePath }
    }

    /// Window titles usually carry the project folder: VS Code shows
    /// "file — folder", terminals show paths. Try the cwd leaf first, then
    /// its parents, so a turn run in a subdirectory still matches the
    /// workspace window.
    private static func workspaceHints(for completion: CodexCompletion) -> [String] {
        guard !completion.cwd.isEmpty else { return [] }
        var url = URL(fileURLWithPath: completion.cwd)
        var hints: [String] = []
        for _ in 0..<3 {
            let leaf = url.lastPathComponent
            if leaf.isEmpty || leaf == "/" { break }
            hints.append(leaf)
            url.deleteLastPathComponent()
        }
        return hints
    }

    /// Take the app's windows back out of the Dock.
    ///
    /// `NSRunningApplication.activate()` and `kAXRaiseAction` both leave a
    /// miniaturized window miniaturized, so a note whose host was minimized
    /// looked like a dead click. Clearing `AXMinimized` is the one way to undo
    /// that from outside the app.
    private static func unminimizeWindows(of app: NSRunningApplication) {
        // Permission prompts only come from Cairn's Access center. A normal
        // note click must never turn into an unexpected system interruption.
        guard AXIsProcessTrusted() else { return }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                &minimizedRef
            ) == .success,
                  let minimized = minimizedRef as? Bool, minimized else { continue }
            AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
    }

    private static func raiseBestWindow(of app: NSRunningApplication, matching hints: [String]) {
        guard !hints.isEmpty else { return }
        // Permission prompts only come from Cairn's Access center. A normal
        // note click must never turn into an unexpected system interruption.
        guard AXIsProcessTrusted() else { return }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for hint in hints {
            for window in windows {
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String,
                      title.localizedCaseInsensitiveContains(hint) else { continue }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }

    // MARK: - Browser tab reuse

    /// Opening a URL through NSWorkspace always spawns a fresh tab — macOS
    /// has no "focus the tab showing X" API. So for web surfaces we script
    /// supported running browsers, with the last successful browser and the
    /// default browser first: find a tab whose URL lives on the same origin,
    /// navigate it to the notification's exact session URL, select and raise
    /// it, and only open a new tab when none exists. Both loopback spellings
    /// (127.0.0.1 / localhost) are matched, since the user may have typed
    /// either.
    private static func reuseOrOpen(
        _ url: URL,
        preferredBrowserBundleID: String?,
        mayPrompt: inout Bool
    ) async {
        let origins = tabMatchOrigins(for: url)
        let exactURLs = tabMatchURLs(for: url)
        let rememberedBrowser = rememberedBrowserBundleID(for: origins)
        let strongPreferenceIDs = Set(
            [preferredBrowserBundleID, rememberedBrowser]
                .compactMap { $0?.lowercased() }
        )
        let browsers = runningScriptableBrowsers(
            preferredBundleIDs: [preferredBrowserBundleID, rememberedBrowser]
        )
        let preferredBrowsers = browsers.filter {
            strongPreferenceIDs.contains($0.bundleID)
        }
        let fallbackBrowsers = browsers.filter {
            !strongPreferenceIDs.contains($0.bundleID)
        }

        // Consent, at the one moment it makes sense. Tab inspection needs the
        // Automation permission, and Cairn's access center is somewhere this
        // user may never go — but they just clicked a note that leads into a
        // browser, so "Cairn wants to control Chrome" is arriving as the
        // answer to their own action. Ask for the first browser that has
        // never been asked about, and only that one: a click must not fan out
        // into a cascade of consent dialogs.
        var usableBrowsers: [ScriptableBrowser] = []
        for browser in preferredBrowsers + fallbackBrowsers {
            if await ensureAutomationConsent(for: browser, mayPrompt: &mayPrompt) {
                usableBrowsers.append(browser)
            }
        }
        let usablePreferred = usableBrowsers.filter { strongPreferenceIDs.contains($0.bundleID) }
        let usableFallback = usableBrowsers.filter { !strongPreferenceIDs.contains($0.bundleID) }

        // A producer hint or a previously successful match is strong evidence:
        // try both the exact session and another OpenClaw tab in that browser
        // before inspecting any others.
        for browser in usablePreferred {
            if focusExistingTab(in: browser, matchingExactURLs: exactURLs) {
                remember(browser: browser, for: origins)
                return
            }
            if focusExistingTab(
                in: browser,
                matchingOrigins: origins,
                navigatingTo: url.absoluteString
            ) {
                remember(browser: browser, for: origins)
                return
            }
        }

        // With no remembered browser (or after it stops containing OpenClaw),
        // search all remaining running browsers for an exact session before
        // repurposing a same-origin tab.
        for browser in usableFallback {
            if focusExistingTab(in: browser, matchingExactURLs: exactURLs) {
                remember(browser: browser, for: origins)
                return
            }
        }
        for browser in usableFallback {
            if focusExistingTab(
                in: browser,
                matchingOrigins: origins,
                navigatingTo: url.absoluteString
            ) {
                remember(browser: browser, for: origins)
                return
            }
        }

        // NSWorkspace opens the user's default browser. Remember that choice
        // so the next completion starts with the browser Cairn just used.
        if let browser = defaultScriptableBrowser() {
            remember(browser: browser, for: origins)
        }
        NSWorkspace.shared.open(url)
    }

    private static func ensureAutomationConsent(
        for browser: ScriptableBrowser,
        mayPrompt: inout Bool
    ) async -> Bool {
        await ensureAutomationConsent(
            bundleID: browser.bundleID,
            displayName: browser.scriptName,
            mayPrompt: &mayPrompt
        )
    }

    /// True when the app at `bundleID` may be scripted, asking the system once
    /// if this is the first time anyone wanted to. A recorded denial is final
    /// here — macOS will not re-ask, and the access center is the way back.
    private static func ensureAutomationConsent(
        bundleID: String,
        displayName: String,
        mayPrompt: inout Bool
    ) async -> Bool {
        if PermissionExperience.shared.canAutomate(bundleID: bundleID) {
            return true
        }
        let state = await Task.detached {
            AutomationPermissionProbe.state(bundleID: bundleID)
        }.value
        switch state {
        case .granted:
            return true
        case .notRequested:
            guard mayPrompt else { return false }
            mayPrompt = false
            let result = await Task.detached {
                AutomationPermissionProbe.requestConsent(
                    bundleID: bundleID,
                    applicationName: displayName
                )
            }.value
            PermissionExperience.shared.refresh()
            return result == .granted
        case .checking, .needsSettings, .unavailable:
            return false
        }
    }

    private static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    struct ScriptableBrowser {
        enum Dialect { case safari, chromium }
        let bundleID: String
        let scriptName: String
        let dialect: Dialect
    }

    private static let knownBrowsers: [String: (String, ScriptableBrowser.Dialect)] = [
        "com.apple.safari": ("Safari", .safari),
        "com.apple.safaritechnologypreview": ("Safari Technology Preview", .safari),
        "com.google.chrome": ("Google Chrome", .chromium),
        "com.google.chrome.canary": ("Google Chrome Canary", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "com.brave.browser": ("Brave Browser", .chromium),
        "com.vivaldi.vivaldi": ("Vivaldi", .chromium),
        "org.chromium.chromium": ("Chromium", .chromium),
    ]

    private static func scriptableBrowser(bundleID: String) -> ScriptableBrowser? {
        let normalized = bundleID.lowercased()
        guard let (name, dialect) = knownBrowsers[normalized] else { return nil }
        return ScriptableBrowser(bundleID: normalized, scriptName: name, dialect: dialect)
    }

    static func defaultScriptableBrowser() -> ScriptableBrowser? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier?.lowercased() else {
            return nil
        }
        return scriptableBrowser(bundleID: bundleID)
    }

    private static func runningScriptableBrowsers(
        preferredBundleIDs: [String?] = []
    ) -> [ScriptableBrowser] {
        var browsers: [ScriptableBrowser] = []
        var seen = Set<String>()

        func append(_ browser: ScriptableBrowser?) {
            guard let browser,
                  seen.insert(browser.bundleID).inserted else {
                return
            }
            browsers.append(browser)
        }

        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap {
                $0.bundleIdentifier?.lowercased()
            }
        )
        for bundleID in preferredBundleIDs.compactMap({ $0?.lowercased() })
        where runningBundleIDs.contains(bundleID) {
            append(scriptableBrowser(bundleID: bundleID))
        }
        if let browser = defaultScriptableBrowser(),
           runningBundleIDs.contains(browser.bundleID) {
            append(browser)
        }
        for bundleID in runningBundleIDs.sorted() {
            append(scriptableBrowser(bundleID: bundleID))
        }
        return browsers
    }

    private static let browserAffinityDefaultsKey = "cairn.browserAffinityByWebOrigin"

    private static func rememberedBrowserBundleID(for origins: [String]) -> String? {
        guard let affinities = UserDefaults.standard.dictionary(
            forKey: browserAffinityDefaultsKey
        ) as? [String: String] else {
            return nil
        }
        return origins.compactMap { affinities[$0] }.first
    }

    private static func remember(browser: ScriptableBrowser, for origins: [String]) {
        guard !origins.isEmpty else { return }
        var affinities = UserDefaults.standard.dictionary(
            forKey: browserAffinityDefaultsKey
        ) as? [String: String] ?? [:]
        for origin in origins {
            affinities[origin] = browser.bundleID
        }
        UserDefaults.standard.set(affinities, forKey: browserAffinityDefaultsKey)
    }

    nonisolated static func tabMatchOrigins(for url: URL) -> [String] {
        guard let scheme = url.scheme, let host = url.host else { return [] }
        let port = url.port.map { ":\($0)" } ?? ""
        var hosts = [host]
        if host == "127.0.0.1" {
            hosts.append("localhost")
        } else if host == "localhost" {
            hosts.append("127.0.0.1")
        }
        return hosts.map { "\(scheme)://\($0)\(port)" }
    }

    nonisolated static func tabMatchURLs(for url: URL) -> [String] {
        guard let host = url.host else { return [] }
        var hosts = [host]
        if host == "127.0.0.1" {
            hosts.append("localhost")
        } else if host == "localhost" {
            hosts.append("127.0.0.1")
        }
        return hosts.compactMap { candidateHost in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.host = candidateHost
            return components.url?.absoluteString
        }
    }

    private static func focusExistingTab(
        in browser: ScriptableBrowser,
        matchingExactURLs exactURLs: [String]
    ) -> Bool {
        guard !exactURLs.isEmpty else { return false }
        return focusTab(in: browser, navigatingTo: nil) { url in
            exactURLs.contains(url)
        }
    }

    private static func focusExistingTab(
        in browser: ScriptableBrowser,
        matchingOrigins origins: [String],
        navigatingTo targetURL: String
    ) -> Bool {
        guard !origins.isEmpty else { return false }
        // Match a complete origin boundary. A raw "starts with origin" check
        // also accepts a different port such as :187890.
        return focusTab(in: browser, navigatingTo: targetURL) { url in
            origins.contains { url == $0 || url.hasPrefix($0 + "/") }
        }
    }

    /// The GUI instances of a browser, most likely to be "the user's
    /// browser" first.
    ///
    /// `tell application "Google Chrome"` addresses a bundle id, and a
    /// developer's Mac routinely runs two processes under that id: the real
    /// browser and a headless one driven by Playwright or Puppeteer — the
    /// same binary, launched for tests. Apple Events routed by bundle id can
    /// land on the headless twin, which reports an empty window list and
    /// makes every tab search come back "missing". So instances are
    /// enumerated and addressed by pid, GUI-policy processes that own
    /// windows on screen first.
    private static func browserInstances(
        of browser: ScriptableBrowser
    ) -> [NSRunningApplication] {
        let onScreen = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var windowsByPID: [pid_t: Int] = [:]
        for window in onScreen {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            windowsByPID[pid, default: 0] += 1
        }

        return NSWorkspace.shared.runningApplications
            .filter {
                $0.bundleIdentifier?.lowercased() == browser.bundleID
                    && $0.activationPolicy == .regular
            }
            .sorted { first, second in
                let firstWindows = windowsByPID[first.processIdentifier] ?? 0
                let secondWindows = windowsByPID[second.processIdentifier] ?? 0
                if firstWindows != secondWindows { return firstWindows > secondWindows }
                let firstLaunch = first.launchDate ?? .distantFuture
                let secondLaunch = second.launchDate ?? .distantFuture
                return firstLaunch < secondLaunch
            }
    }

    /// The access center refreshes permission state asynchronously, so the
    /// cached state can lag a grant made moments ago. Fall back to a live TCC
    /// probe — it never asks and never shows a prompt.
    private static func automationGranted(bundleID: String) -> Bool {
        PermissionExperience.shared.canAutomate(bundleID: bundleID)
            || AutomationPermissionProbe.state(bundleID: bundleID) == .granted
    }

    private static func focusTab(
        in browser: ScriptableBrowser,
        navigatingTo targetURL: String?,
        matching: (String) -> Bool
    ) -> Bool {
        guard automationGranted(bundleID: browser.bundleID) else {
            Logger.trail.notice(
                """
                Browser tab reuse skipped for \(browser.scriptName, privacy: .public): \
                Automation is not granted
                """
            )
            return false
        }

        for instance in browserInstances(of: browser) {
            if focusTab(
                inInstanceWithPID: instance.processIdentifier,
                of: browser,
                navigatingTo: targetURL,
                matching: matching
            ) {
                instance.activate()
                return true
            }
        }
        return false
    }

    /// Walk one instance's windows and tabs over the ScriptingBridge — the
    /// same scripting interface AppleScript uses, but aimed at an exact pid.
    /// Everything is read through KVC because Cairn ships no generated
    /// headers for other people's apps; a browser that answers with nil
    /// simply reads as having no matching tab.
    private static func focusTab(
        inInstanceWithPID pid: pid_t,
        of browser: ScriptableBrowser,
        navigatingTo targetURL: String?,
        matching: (String) -> Bool
    ) -> Bool {
        guard let application = SBApplication(processIdentifier: pid),
              let windows = (application as AnyObject).value(forKey: "windows") as? [AnyObject]
        else {
            return false
        }

        for window in windows {
            guard let tabs = window.value(forKey: "tabs") as? [AnyObject] else { continue }
            for (index, tab) in tabs.enumerated() {
                guard let url = tab.value(forKey: "URL") as? String, matching(url) else {
                    continue
                }
                if let targetURL {
                    tab.setValue(targetURL, forKey: "URL")
                }
                switch browser.dialect {
                case .safari:
                    window.setValue(tab, forKey: "currentTab")
                case .chromium:
                    window.setValue(index + 1 as NSNumber, forKey: "activeTabIndex")
                }
                window.setValue(1 as NSNumber, forKey: "index")
                return true
            }
        }
        return false
    }

    // MARK: - Fallbacks and plumbing

    private static func revealInFinder(cwd: String) {
        guard !cwd.isEmpty else { return }
        let url = URL(fileURLWithPath: cwd)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int).map(String.init) ?? "?"
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            Logger.trail.error(
                "AppleScript failed \(code, privacy: .public) — \(message, privacy: .public)"
            )
            return nil
        }
        return result.stringValue
    }
}
