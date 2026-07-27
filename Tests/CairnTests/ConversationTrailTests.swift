import Carbon
import Foundation
import Testing
@testable import Cairn

private func completion(
    source: String? = "codex",
    event: String = "codex.turn.completed",
    sessionID: String = "019f9fe6-41d4-7d73-878c-255e57907727"
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
        locator: nil
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
        webURL: nil
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
        webURL: nil
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
        webURL: nil
    )

    #expect(ConversationTrail.wasHostedByCodexDesktop(chatGPT))
    #expect(ConversationTrail.wasHostedByCodexDesktop(codex))
    #expect(!ConversationTrail.wasHostedByCodexDesktop(editor))
}

@Test
func automationPermissionStatusesMapToUserFacingStates() {
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
