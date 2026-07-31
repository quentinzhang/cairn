import Carbon
import Foundation
import Testing
@testable import Cairn

private func completion(
    source: String? = "codex",
    event: String = "codex.turn.completed",
    sessionID: String = "019f9fe6-41d4-7d73-878c-255e57907727",
    locator: CairnLocator? = nil
) -> CodexCompletion {
    CodexCompletion(
        id: "completion",
        version: 1,
        event: event,
        sessionID: sessionID,
        turnID: nil,
        cwd: "/tmp/project",
        title: "Completed",
        result: "Done",
        status: "completed",
        timestamp: Date(timeIntervalSince1970: 0),
        source: source,
        userMessage: nil,
        model: nil,
        platform: nil,
        locator: locator
    )
}

@Test
func buildInfoFormatsVersionAndBuildNumber() {
    #expect(
        CairnBuildInfo.displayVersion(
            from: [
                "CFBundleShortVersionString": "0.6.3",
                "CFBundleVersion": "15",
            ],
            localeIdentifier: "en"
        ) == "Version 0.6.3 (15)"
    )
}

@Test
func codexCompletionBuildsConversationDeepLink() {
    let url = ConversationTrail.codexThreadURL(for: completion())
    #expect(url?.absoluteString == "codex://threads/019f9fe6-41d4-7d73-878c-255e57907727")
}

@Test
func eventProvidesSourceForOlderCompletion() {
    let url = ConversationTrail.codexThreadURL(for: completion(source: nil))
    #expect(url?.absoluteString == "codex://threads/019f9fe6-41d4-7d73-878c-255e57907727")
}

@Test
func invalidOrNonCodexSessionDoesNotBuildDeepLink() {
    #expect(ConversationTrail.codexThreadURL(for: completion(source: "claude-code")) == nil)
    #expect(ConversationTrail.codexThreadURL(for: completion(sessionID: "unknown-session")) == nil)
}

@Test
func hermesDashboardCompletionBuildsSessionRecoveryURL() {
    let locator = CairnLocator(
        termProgram: nil,
        termSessionID: nil,
        itermSessionID: nil,
        tmuxPane: nil,
        tty: nil,
        hostAppPath: nil,
        hostAppPID: nil,
        agentPID: nil,
        hostApps: nil,
        webURL: "https://hermes.example/dashboard?profile=research",
        browserBundleID: nil
    )

    let url = ConversationTrail.hermesDashboardSessionURL(
        for: completion(
            source: "hermes",
            sessionID: "20260728_123456_abcd",
            locator: locator
        )
    )
    #expect(url?.absoluteString == "https://hermes.example/dashboard/chat?profile=research&resume=20260728_123456_abcd")
}

@Test
func hermesDesktopCompletionDoesNotInventDashboardURL() {
    #expect(
        ConversationTrail.hermesDashboardSessionURL(
            for: completion(source: "hermes")
        ) == nil
    )
}

@Test
func looksForAnAgentAppWhereMacsKeepThem() {
    let candidates = ConversationTrail.applicationBundleCandidates(
        named: "Hermes",
        home: URL(fileURLWithPath: "/Users/tester")
    )

    #expect(
        candidates.map(\.path) == [
            "/Users/tester/Applications/Hermes.app",
            "/Applications/Hermes.app",
            "/Applications/Utilities/Hermes.app",
            "/System/Applications/Hermes.app",
        ]
    )
}

@Test
func recognizesBothCurrentDesktopBundleNames() {
    let chatGPT = CairnLocator(
        termProgram: nil,
        termSessionID: nil,
        itermSessionID: nil,
        tmuxPane: nil,
        tty: nil,
        hostAppPath: "/Applications/ChatGPT.app",
        hostAppPID: nil,
        agentPID: nil,
        hostApps: nil,
        webURL: nil,
        browserBundleID: nil
    )
    let codex = CairnLocator(
        termProgram: nil,
        termSessionID: nil,
        itermSessionID: nil,
        tmuxPane: nil,
        tty: nil,
        hostAppPath: "/Applications/Codex.app",
        hostAppPID: nil,
        agentPID: nil,
        hostApps: nil,
        webURL: nil,
        browserBundleID: nil
    )
    let editor = CairnLocator(
        termProgram: nil,
        termSessionID: nil,
        itermSessionID: nil,
        tmuxPane: nil,
        tty: nil,
        hostAppPath: "/Applications/Visual Studio Code.app",
        hostAppPID: nil,
        agentPID: nil,
        hostApps: nil,
        webURL: nil,
        browserBundleID: nil
    )

    #expect(ConversationTrail.wasHostedByCodexDesktop(chatGPT))
    #expect(ConversationTrail.wasHostedByCodexDesktop(codex))
    #expect(!ConversationTrail.wasHostedByCodexDesktop(editor))
}

@Test
func recognizesBothLayersOfAClaudeDesktopTurn() {
    // What the desktop app's ancestry actually looks like: a background-only
    // harness bundle inside Application Support, then the app itself.
    let desktop = CairnLocator(
        termProgram: nil,
        termSessionID: nil,
        itermSessionID: nil,
        tmuxPane: nil,
        tty: nil,
        hostAppPath: "/Users/tester/Library/Application Support/Claude/claude-code/2.1.219/claude.app",
        hostAppPID: 21418,
        agentPID: 21418,
        hostApps: [
            CairnHostApp(
                path: "/Users/tester/Library/Application Support/Claude/claude-code/2.1.219/claude.app",
                pid: 21418
            ),
            CairnHostApp(path: "/Applications/Claude.app", pid: 5665),
        ],
        webURL: nil,
        browserBundleID: nil
    )
    // A turn from a terminal: the standalone CLI is a bare executable, so no
    // Claude bundle appears anywhere in the ancestry.
    let terminal = CairnLocator(
        termProgram: "iTerm.app",
        termSessionID: nil,
        itermSessionID: nil,
        tmuxPane: nil,
        tty: "ttys004",
        hostAppPath: "/Applications/iTerm.app",
        hostAppPID: nil,
        agentPID: nil,
        hostApps: nil,
        webURL: nil,
        browserBundleID: nil
    )

    #expect(ConversationTrail.wasHostedByClaudeDesktop(desktop))
    #expect(!ConversationTrail.wasHostedByClaudeDesktop(terminal))
    #expect(!ConversationTrail.wasHostedByClaudeDesktop(nil))
}

@Test
func aHarnessRecordedAloneStillCountsAsTheDesktopApp() {
    // Older notes captured only the innermost bundle. The harness is proof
    // enough on its own — it exists only underneath the desktop app.
    let harnessOnly = CairnLocator(
        termProgram: nil,
        termSessionID: nil,
        itermSessionID: nil,
        tmuxPane: nil,
        tty: nil,
        hostAppPath: "/Users/tester/Library/Application Support/Claude/claude-code/2.1.219/claude.app",
        hostAppPID: nil,
        agentPID: nil,
        hostApps: nil,
        webURL: nil,
        browserBundleID: nil
    )

    #expect(ConversationTrail.wasHostedByClaudeDesktop(harnessOnly))
}

/// A stand-in for `~/Library/Application Support/Claude/claude-code-sessions`:
/// one directory per install, one per account inside it, records within.
private func claudeSessionStore(_ records: [[String: Any]]) throws -> URL {
    let store = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cairn-claude-store-\(UUID().uuidString)")
    let account = store
        .appendingPathComponent("install-a3f")
        .appendingPathComponent("account-91c")
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
    for record in records {
        let name = (record["sessionId"] as? String) ?? UUID().uuidString
        try JSONSerialization.data(withJSONObject: record).write(
            to: account.appendingPathComponent("\(name).json")
        )
    }
    return store
}

@Test
func claudeConversationResolvesToTheIdTheDesktopAppFiledItUnder() throws {
    let store = try claudeSessionStore([
        [
            "sessionId": "local_53f55097-48c1-4827-a172-06c630ce21bc",
            "cliSessionId": "350d9639-0f7e-4dd4-b56b-2797482b0e28",
            "lastActivityAt": 1_785_225_005_995,
            "title": "生活美满",
        ],
        [
            "sessionId": "local_004615af-0b68-4500-bbc3-e67e610ba48b",
            "cliSessionId": "4dd4a2b5-f58f-4d8c-ba2c-2bdc6c5f5e36",
            "lastActivityAt": 1_785_223_750_704,
        ],
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    let url = ConversationTrail.claudeDesktopConversationURL(
        for: completion(
            source: "claude-code",
            sessionID: "350d9639-0f7e-4dd4-b56b-2797482b0e28"
        ),
        in: store
    )

    #expect(
        url?.absoluteString
            == "claude://claude.ai/claude-code-desktop/local_53f55097-48c1-4827-a172-06c630ce21bc"
    )
}

@Test
func aConversationTheDesktopAppNeverSawHasNoRouteIntoIt() throws {
    let store = try claudeSessionStore([
        [
            "sessionId": "local_53f55097-48c1-4827-a172-06c630ce21bc",
            "cliSessionId": "350d9639-0f7e-4dd4-b56b-2797482b0e28",
            "lastActivityAt": 1_785_225_005_995,
        ]
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    // A CLI session the app does not hold — the trail has to import it or
    // fall back, and must not invent a session id.
    #expect(
        ConversationTrail.claudeDesktopConversationURL(
            for: completion(
                source: "claude-code",
                sessionID: "8d3bdf70-d663-453d-9029-fc9785bf7f52"
            ),
            in: store
        ) == nil
    )
    // A missing store answers the same way rather than failing the click.
    #expect(
        ConversationTrail.claudeDesktopConversationURL(
            for: completion(source: "claude-code"),
            in: store.appendingPathComponent("gone")
        ) == nil
    )
    // Another agent's note never takes this route.
    #expect(
        ConversationTrail.claudeDesktopConversationURL(
            for: completion(
                source: "codex",
                sessionID: "350d9639-0f7e-4dd4-b56b-2797482b0e28"
            ),
            in: store
        ) == nil
    )
}

@Test
func aTwinnedConversationReturnsToTheSessionTheAppNamed() throws {
    // Both records claim one CLI session: the desktop app's own, and the twin
    // an earlier Cairn imported beside it — more recently touched, because
    // importing it is what touched it last. They resume the same transcript,
    // so the titled one the user recognizes is where a click should land.
    let store = try claudeSessionStore([
        [
            "sessionId": "local_40863fc1-290d-44a5-8d9e-87bba54950de",
            "cliSessionId": "8c9d4f59-29f8-46f9-b947-c468a5f0855c",
            "lastActivityAt": 1_785_220_887_403,
            "title": "设置窗口和标签滚动修复",
        ],
        [
            "sessionId": "local_8c9d4f59-29f8-46f9-b947-c468a5f0855c",
            "cliSessionId": "8c9d4f59-29f8-46f9-b947-c468a5f0855c",
            "lastActivityAt": 1_785_224_741_040,
        ],
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    #expect(
        ClaudeDesktopSessions.sessionID(
            forCLISession: "8c9d4f59-29f8-46f9-b947-c468a5f0855c",
            in: store
        ) == "local_40863fc1-290d-44a5-8d9e-87bba54950de"
    )
}

@Test
func anImportedSessionIsStillTheWayBackWhenItIsAllThereIs() throws {
    // A turn that really did run in a terminal, imported once by an older
    // Cairn: the import-shaped id is the only record, and dropping it would
    // trade a duplicate for a dead click.
    let store = try claudeSessionStore([
        [
            "sessionId": "local_e39dd28a-3004-44c5-a546-1ef61aa64e53",
            "cliSessionId": "e39dd28a-3004-44c5-a546-1ef61aa64e53",
            "lastActivityAt": 1_785_152_680_722,
        ]
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    #expect(
        ClaudeDesktopSessions.sessionID(
            forCLISession: "e39dd28a-3004-44c5-a546-1ef61aa64e53",
            in: store
        ) == "local_e39dd28a-3004-44c5-a546-1ef61aa64e53"
    )
}

@Test
func theConversationOnScreenIsTheOneFocusedLast() throws {
    let store = try claudeSessionStore([
        [
            "sessionId": "local_53f55097-48c1-4827-a172-06c630ce21bc",
            "cliSessionId": "350d9639-0f7e-4dd4-b56b-2797482b0e28",
            "lastActivityAt": 1_785_225_005_995,
            "lastFocusedAt": 1_785_225_100_000,
        ],
        [
            "sessionId": "local_004615af-0b68-4500-bbc3-e67e610ba48b",
            "cliSessionId": "4dd4a2b5-f58f-4d8c-ba2c-2bdc6c5f5e36",
            "lastActivityAt": 1_785_223_750_704,
            // Touched more recently, but read in the app before the other one.
            "lastFocusedAt": 1_785_224_000_000,
        ],
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    let appLaunched = Date(timeIntervalSince1970: 1_785_220_000)
    #expect(
        ClaudeDesktopSessions.frontmostSessionID(in: store, focusedSince: appLaunched)
            == "local_53f55097-48c1-4827-a172-06c630ce21bc"
    )
    // No launch date to check against: the freshest stamp still names it.
    #expect(
        ClaudeDesktopSessions.frontmostSessionID(in: store, focusedSince: nil)
            == "local_53f55097-48c1-4827-a172-06c630ce21bc"
    )
}

@Test
func aFocusFromBeforeTheAppStartedSaysNothingAboutWhatIsOnScreen() throws {
    // The app was quit reading this conversation and launched again since.
    // The stamp survived; what it described did not.
    let store = try claudeSessionStore([
        [
            "sessionId": "local_53f55097-48c1-4827-a172-06c630ce21bc",
            "cliSessionId": "350d9639-0f7e-4dd4-b56b-2797482b0e28",
            "lastActivityAt": 1_785_225_005_995,
            "lastFocusedAt": 1_785_225_100_000,
        ]
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    #expect(
        ClaudeDesktopSessions.frontmostSessionID(
            in: store,
            focusedSince: Date(timeIntervalSince1970: 1_785_226_000)
        ) == nil
    )
}

@Test
func anArchivedOrNeverFocusedConversationIsNotOnScreen() throws {
    let store = try claudeSessionStore([
        [
            "sessionId": "local_53f55097-48c1-4827-a172-06c630ce21bc",
            "cliSessionId": "350d9639-0f7e-4dd4-b56b-2797482b0e28",
            "lastActivityAt": 1_785_225_005_995,
            "lastFocusedAt": 1_785_225_100_000,
            "isArchived": true,
        ],
        [
            "sessionId": "local_004615af-0b68-4500-bbc3-e67e610ba48b",
            "cliSessionId": "4dd4a2b5-f58f-4d8c-ba2c-2bdc6c5f5e36",
            "lastActivityAt": 1_785_223_750_704,
            "lastFocusedAt": 1_785_224_000_000,
        ],
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    #expect(
        ClaudeDesktopSessions.frontmostSessionID(in: store, focusedSince: nil)
            == "local_004615af-0b68-4500-bbc3-e67e610ba48b"
    )

    // A store where nothing carries a focus stamp — an older app, or one that
    // has never put a conversation on screen — answers plainly.
    let unfocused = try claudeSessionStore([
        [
            "sessionId": "local_53f55097-48c1-4827-a172-06c630ce21bc",
            "cliSessionId": "350d9639-0f7e-4dd4-b56b-2797482b0e28",
            "lastActivityAt": 1_785_225_005_995,
        ]
    ])
    defer { try? FileManager.default.removeItem(at: unfocused) }
    #expect(ClaudeDesktopSessions.frontmostSessionID(in: unfocused, focusedSince: nil) == nil)
}

@Test
func aDesktopSessionIdBecomesTheSameConversationLink() throws {
    let store = try claudeSessionStore([
        [
            "sessionId": "local_53f55097-48c1-4827-a172-06c630ce21bc",
            "cliSessionId": "350d9639-0f7e-4dd4-b56b-2797482b0e28",
            "lastActivityAt": 1_785_225_005_995,
        ]
    ])
    defer { try? FileManager.default.removeItem(at: store) }

    let note = completion(
        source: "claude-code",
        sessionID: "350d9639-0f7e-4dd4-b56b-2797482b0e28"
    )
    let desktopID = try #require(
        ConversationTrail.claudeDesktopSessionID(for: note, in: store)
    )
    #expect(desktopID == "local_53f55097-48c1-4827-a172-06c630ce21bc")
    #expect(
        ConversationTrail.claudeDesktopConversationURL(forDesktopSession: desktopID)
            == ConversationTrail.claudeDesktopConversationURL(for: note, in: store)
    )
    // Another agent's note never resolves to a Claude conversation.
    #expect(
        ConversationTrail.claudeDesktopSessionID(
            for: completion(sessionID: "350d9639-0f7e-4dd4-b56b-2797482b0e28"),
            in: store
        ) == nil
    )
}

@Test
func browserTabOriginsIncludeBothLoopbackSpellings() throws {
    let url = try #require(URL(string: "http://127.0.0.1:18789/chat?session=abc"))
    #expect(
        TrailFinder.tabMatchOrigins(for: url)
            == [
                "http://127.0.0.1:18789",
                "http://localhost:18789",
            ]
    )
}

@Test
func browserTabOriginsPreserveSchemeHostAndPortOnly() throws {
    let url = try #require(URL(string: "https://openclaw.example:8443/chat/thread"))
    #expect(
        TrailFinder.tabMatchOrigins(for: url)
            == ["https://openclaw.example:8443"]
    )
}

@Test
func browserExactSessionURLsIncludeBothLoopbackSpellings() throws {
    let url = try #require(
        URL(string: "http://127.0.0.1:18789/chat?session=agent%3Amain%3Amain")
    )
    #expect(
        TrailFinder.tabMatchURLs(for: url)
            == [
                "http://127.0.0.1:18789/chat?session=agent%3Amain%3Amain",
                "http://localhost:18789/chat?session=agent%3Amain%3Amain",
            ]
    )
}

@Test
func automationPermissionStatusesMapToUserFacingStates() {
    #expect(AutomationPermissionProbe.eventClass == AEEventClass(kAECoreSuite))
    #expect(AutomationPermissionProbe.eventID == AEEventID(kAEGetData))
    #expect(AutomationPermissionProbe.classify(noErr) == .granted)
    #expect(
        AutomationPermissionProbe.classify(OSStatus(errAEEventWouldRequireUserConsent))
            == .notRequested
    )
    #expect(
        AutomationPermissionProbe.classify(OSStatus(errAEEventNotPermitted))
            == .needsSettings
    )
    #expect(AutomationPermissionProbe.classify(OSStatus(procNotFound)) == .unavailable)
    #expect(AutomationPermissionProbe.classify(-9999) == .unavailable)
}

@Test
func recordedAutomationDenialWinsOverAnAmbiguousPreflight() {
    #expect(
        AutomationPermissionProbe.reconcile(observed: .notRequested, knownDenied: true)
            == .needsSettings
    )
    #expect(
        AutomationPermissionProbe.reconcile(observed: .granted, knownDenied: true)
            == .granted
    )
}

@Test
func accessPresentationSeparatesApplicationAndPermissionState() {
    let notInstalled = CairnAccessPresentation.automation(
        application: .notInstalled,
        permission: .checking
    )
    #expect(notInstalled.label == "Not installed")
    #expect(notInstalled.action == nil)

    let installedButClosed = CairnAccessPresentation.automation(
        application: .notRunning,
        permission: .granted
    )
    #expect(installedButClosed.label == "Not needed yet")
    #expect(installedButClosed.action == .open)

    let optional = CairnAccessPresentation.automation(
        application: .running,
        permission: .notRequested
    )
    #expect(optional.label == "Optional")
    #expect(optional.action == .enable)

    let granted = CairnAccessPresentation.automation(
        application: .running,
        permission: .granted
    )
    #expect(granted.label == "On")
    #expect(granted.action == .settings)

    let denied = CairnAccessPresentation.automation(
        application: .running,
        permission: .needsSettings
    )
    #expect(denied.label == "Off")
    #expect(denied.action == .settings)
}

@Test
func offMeansSomethingDifferentForAccessibilityThanForAutomation() {
    // Automation's Off is a denial macOS recorded and will never re-ask about,
    // so Settings is the only way back. Accessibility's Off only means Cairn
    // asked once — the system may never have registered it, leaving Settings
    // with no row to switch on, so the button must ask again instead.
    #expect(
        CairnAccessPresentation.automation(application: .running, permission: .needsSettings)
            .action == .settings
    )
    #expect(CairnAccessPresentation.accessibility(.needsSettings).action == .enable)
    #expect(CairnAccessPresentation.accessibility(.needsSettings).label == "Off")

    // Granted is the one state where Accessibility does send you to Settings,
    // because there is nothing left to ask for — only something to revoke.
    #expect(CairnAccessPresentation.accessibility(.granted).action == .settings)
    #expect(CairnAccessPresentation.accessibility(.notRequested).action == .enable)
}
