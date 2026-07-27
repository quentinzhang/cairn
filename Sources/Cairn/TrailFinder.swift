import AppKit
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

    /// Prefer a thread deep link only when the turn actually lived in Codex
    /// Desktop. CLI and editor turns should still return to their terminal or
    /// editor, even though Codex Desktop can also display the same session.
    static func wasHostedByCodexDesktop(_ locator: CairnLocator?) -> Bool {
        guard let locator else { return false }
        var paths = (locator.hostApps ?? []).compactMap(\.path)
        if let path = locator.hostAppPath, !paths.contains(path) {
            paths.append(path)
        }

        return paths.contains { path in
            let appURL = URL(fileURLWithPath: path)
            if Bundle(url: appURL)?.bundleIdentifier?.lowercased() == "com.openai.codex" {
                return true
            }
            let appName = appURL.lastPathComponent.lowercased()
            return appName == "codex.app" || appName == "chatgpt.app"
        }
    }
}

@MainActor
enum TrailFinder {

    static func follow(_ completion: CodexCompletion) {
        let locator = completion.locator

        if let tty = shortTTY(locator?.tty),
           locator?.termProgram == "Apple_Terminal",
           selectTerminalTab(tty: tty) {
            return
        }

        if let session = itermUUID(locator?.itermSessionID),
           selectITermSession(uuid: session) {
            return
        }

        if let hermesSessionURL = ConversationTrail.hermesDashboardSessionURL(for: completion) {
            openWebURLReusingTab(hermesSessionURL)
            return
        }

        // Claude Code sessions are addressable at CONVERSATION level: the
        // desktop app's `claude://resume?session=<uuid>` deep link imports and
        // opens the exact CLI session. Terminal/iTerm still win above (they
        // are the session's real home); this handles turns run inside the
        // desktop app, and gives dead terminal sessions a second life.
        if completion.source?.lowercased() == "claude-code",
           UUID(uuidString: completion.sessionID) != nil,
           let deepLink = URL(string: "claude://resume?session=\(completion.sessionID)"),
           NSWorkspace.shared.open(deepLink) {
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
            raiseBestWindow(of: app, matching: workspaceHints(for: completion))
            app.activate()
            return
        }

        // A browser-surfaced turn: return to its web UI.
        if let web = locator?.webURL, let url = URL(string: web) {
            openWebURLReusingTab(
                url,
                preferredBrowserBundleID: locator?.browserBundleID
            )
            return
        }

        // Older Codex notes may not have a locator, or their original host may
        // already be gone. The stable session id still gives them an exact
        // conversation-level recovery path in Codex Desktop.
        if let codexThreadURL, NSWorkspace.shared.open(codexThreadURL) {
            return
        }

        if followSourceFallback(completion) {
            return
        }

        revealInFinder(cwd: completion.cwd)
    }

    // MARK: - Source-level fallbacks

    /// Some turns run under processes with no reachable GUI ancestor — the
    /// Hermes gateway is parented by launchd, OpenClaw's webchat lives in a
    /// browser tab, and older notes predate the locator entirely. When the
    /// captured trail leads nowhere, fall back to what the *source* implies.
    private static func followSourceFallback(_ completion: CodexCompletion) -> Bool {
        let source = completion.source?.lowercased() ?? ""
        switch source {
        case "hermes":
            return activateAppNamed("Hermes")
        case "openclaw":
            // The gateway's web UI is where webchat conversations live.
            if let url = URL(string: "http://127.0.0.1:\(openClawGatewayPort())") {
                openWebURLReusingTab(url)
                return true
            }
            return false
        case "claude-code":
            return activateAppNamed("Claude")
        default:
            return false
        }
    }

    private static func activateAppNamed(_ name: String) -> Bool {
        let match = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && ($0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
                    || $0.bundleURL?.lastPathComponent.lowercased() == "\(name.lowercased()).app")
        }
        guard let match else { return false }
        match.activate()
        return true
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
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal"
        ).first != nil,
        PermissionExperience.shared.canAutomate(bundleID: "com.apple.Terminal") else {
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
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.googlecode.iterm2"
        ).first != nil,
        PermissionExperience.shared.canAutomate(bundleID: "com.googlecode.iterm2") else {
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
            if let app = runningApp(bundlePath: path) {
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
    private static func openWebURLReusingTab(
        _ url: URL,
        preferredBrowserBundleID: String? = nil
    ) {
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

        // A producer hint or a previously successful match is strong evidence:
        // try both the exact session and another OpenClaw tab in that browser
        // before inspecting any others.
        for browser in preferredBrowsers {
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
        for browser in fallbackBrowsers {
            if focusExistingTab(in: browser, matchingExactURLs: exactURLs) {
                remember(browser: browser, for: origins)
                return
            }
        }
        for browser in fallbackBrowsers {
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
        let condition = exactURLs
            .map { "u is \"\($0)\"" }
            .joined(separator: " or ")
        return runBrowserTabScript(
            in: browser,
            condition: condition,
            navigatingTo: nil
        )
    }

    private static func focusExistingTab(
        in browser: ScriptableBrowser,
        matchingOrigins origins: [String],
        navigatingTo targetURL: String
    ) -> Bool {
        guard !origins.isEmpty else { return false }

        // Match a complete origin boundary. A raw "starts with origin" check
        // also accepts a different port such as :187890.
        let condition = origins
            .map { "(u is \"\($0)\") or (u starts with \"\($0)/\")" }
            .joined(separator: " or ")
        return runBrowserTabScript(
            in: browser,
            condition: condition,
            navigatingTo: targetURL
        )
    }

    private static func runBrowserTabScript(
        in browser: ScriptableBrowser,
        condition: String,
        navigatingTo targetURL: String?
    ) -> Bool {

        // The access center refreshes permission state asynchronously. A note
        // can be clicked while that cached state is still `checking`, so probe
        // TCC again at the moment of use before deciding that tab inspection
        // is unavailable. The probe never asks or displays a system prompt.
        let cachedPermission = PermissionExperience.shared.canAutomate(
            bundleID: browser.bundleID
        )
        let currentPermission = cachedPermission
            ? CairnPermissionState.granted
            : AutomationPermissionProbe.state(bundleID: browser.bundleID)
        guard currentPermission == .granted else {
            Logger.trail.notice(
                """
                Browser tab reuse skipped for \(browser.scriptName, privacy: .public): \
                Automation is \(currentPermission.label, privacy: .public)
                """
            )
            return false
        }

        let navigation = targetURL.map { "set URL of t to \"\($0)\"" } ?? ""

        let script: String
        switch browser.dialect {
        case .safari:
            script = """
            tell application "\(browser.scriptName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if u is not missing value and (\(condition)) then
                            \(navigation)
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        case .chromium:
            script = """
            tell application "\(browser.scriptName)"
                repeat with w in windows
                    set tabIndex to 1
                    repeat with t in tabs of w
                        set u to URL of t
                        if u is not missing value and (\(condition)) then
                            \(navigation)
                            set active tab index of w to tabIndex
                            set index of w to 1
                            activate
                            return "found"
                        end if
                        set tabIndex to tabIndex + 1
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        }
        return runAppleScript(script) == "found"
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
