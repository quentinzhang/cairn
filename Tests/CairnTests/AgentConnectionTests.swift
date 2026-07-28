import Foundation
import Testing
@testable import Cairn

private func decodeReport(_ json: String) throws -> [AgentConnectionStatus] {
    let data = try #require(json.data(using: .utf8))
    return try JSONDecoder().decode(AgentConnectionReport.self, from: data).runtimes
}

@Test
func bridgeReportDecodesEveryState() throws {
    let runtimes = try decodeReport(
        """
        {"schema": 1, "runtimes": [
          {"id": "codex", "state": "connected", "issue": null, "message": null,
           "consent": false, "follow_up": "codex_trust"},
          {"id": "claude", "state": "available", "issue": null, "message": null,
           "consent": false, "follow_up": null},
          {"id": "openclaw", "state": "attention", "issue": "disabled", "message": null,
           "consent": true, "follow_up": null},
          {"id": "hermes", "state": "not_installed", "issue": null, "message": null,
           "consent": false, "follow_up": null}
        ]}
        """
    )

    #expect(runtimes.map(\.id) == ["codex", "claude", "openclaw", "hermes"])
    #expect(runtimes[0].state == .connected)
    #expect(runtimes[0].isConnected)
    #expect(runtimes[0].followUp == "codex_trust")
    #expect(runtimes[1].state == .available)
    #expect(runtimes[2].state == .attention)
    #expect(runtimes[2].issue == "disabled")
    #expect(runtimes[2].consent)
    #expect(runtimes[3].state == .notInstalled)
    #expect(!runtimes[3].isConnected)
}

/// A newer bridge beside an older app must stay legible: an unrecognised state
/// is something to look at, never a decoding failure that blanks the window.
@Test
func unknownStateDegradesToAttention() throws {
    let runtimes = try decodeReport(
        """
        {"schema": 2, "runtimes": [
          {"id": "future", "state": "quantum", "issue": null, "message": "hello",
           "consent": false, "follow_up": null}
        ]}
        """
    )
    #expect(runtimes.count == 1)
    #expect(runtimes[0].state == .attention)
    #expect(runtimes[0].message == "hello")
}

@Test
func connectOutcomeCarriesTheRefreshedState() throws {
    let data = try #require(
        """
        {"id": "claude", "ok": true, "message": "Stop hook written", "follow_up": null,
         "state": {"id": "claude", "state": "connected", "issue": "other_source",
                   "message": "~/elsewhere/cairn_claude_hook.py", "consent": false,
                   "follow_up": null}}
        """.data(using: .utf8)
    )
    let outcome = try JSONDecoder().decode(AgentConnectionOutcome.self, from: data)

    #expect(outcome.ok)
    #expect(outcome.state.state == .connected)
    #expect(outcome.state.issue == "other_source")
}

@Test
func consentRefusalIsReportedAsAnIssueRatherThanACrash() throws {
    let data = try #require(
        """
        {"id": "openclaw", "ok": false, "message": "", "follow_up": null,
         "issue": "needs_consent",
         "state": {"id": "openclaw", "state": "available", "issue": null,
                   "message": null, "consent": true, "follow_up": null}}
        """.data(using: .utf8)
    )
    let outcome = try JSONDecoder().decode(AgentConnectionOutcome.self, from: data)

    #expect(!outcome.ok)
    #expect(outcome.issue == "needs_consent")
    #expect(outcome.state.consent)
}

@Test
func everyRuntimeHasAnIdentityAndAnUnknownOneStillRenders() {
    #expect(AgentRuntimeIdentity.identity(for: "codex").name == "Codex")
    #expect(AgentRuntimeIdentity.identity(for: "claude").name == "Claude Code")
    #expect(AgentRuntimeIdentity.identity(for: "openclaw").name == "OpenClaw")
    #expect(AgentRuntimeIdentity.identity(for: "hermes").name == "Hermes")

    let unknown = AgentRuntimeIdentity.identity(for: "newthing")
    #expect(unknown.name == "Newthing")
}

/// The window and the count are about agents. The bridge also knows how to
/// install the `cairn-save` skill, but that is a Cairn feature rather than an
/// agent to connect, so it never becomes a row — and never inflates the count.
@Test
func theWindowShowsAgentsAndNothingElse() {
    #expect(AgentRuntimeIdentity.all.map(\.id) == ["codex", "claude", "openclaw", "hermes"])
}

/// Every code the bridge can emit needs a sentence in every language, or the
/// window shows a raw identifier to someone who cannot act on it.
@Test
func everyBridgeCodeIsTranslatedEverywhere() throws {
    let issues = [
        "config_invalid", "script_missing", "duplicate", "other_source", "disabled",
        "cli_missing", "foreign_plugin", "broken_link", "partial", "no_consent",
        "plugin_missing",
    ]
    let followUps = ["codex_trust", "openclaw_restart", "hermes_enable", "hermes_restart"]
    var keys = issues.map { "connect.issue.\($0)" }
    keys += followUps.map { "connect.followup.\($0)" }
    keys += [
        "connect.state.connected", "connect.state.available",
        "connect.state.not_installed", "connect.state.attention",
        "connect.state.working", "connect.action.connect",
        "connect.action.disconnect", "connect.action.reconnect",
        "connect.action.repair", "connect.consent.title", "connect.consent.body",
        "connect.consent.allow", "connect.consent.cancel", "connect.window.title",
        "connect.title", "connect.subtitle", "connect.footer", "connect.empty",
        "connect.failure.script_missing", "connect.failure.timed_out",
        "connect.failure.unreadable", "menu.connect", "menu.connect_count",
        "connect.onboarding.requirement", "connect.onboarding.start",
        "control.intro.drag", "control.intro.notes", "control.intro.dismiss",
    ]

    for locale in L10n.supportedLocales {
        for key in keys {
            #expect(
                L10n.string(key, localeIdentifier: locale) != key,
                "\(locale) is missing \(key)"
            )
        }
    }
}

/// The one test that would have caught the original complaint: the bridge has
/// to be reachable and answer for every runtime Cairn claims to support. It
/// runs the real `cairn_connect.py`, which only reads.
@Test
func theBridgeAnswersForEveryRuntime() throws {
    let scripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts")
    setenv("CAIRN_SCRIPTS_DIR", scripts.path, 1)
    defer { unsetenv("CAIRN_SCRIPTS_DIR") }

    #expect(AgentConnectionBridge.scriptURL() != nil)

    let runtimes = try AgentConnectionBridge.status()
    #expect(
        runtimes.map(\.id).sorted() == ["claude", "codex", "hermes", "openclaw", "skills"]
    )
    // Every agent the window lists has an answer from the bridge.
    for identity in AgentRuntimeIdentity.all {
        #expect(runtimes.contains { $0.id == identity.id }, "no bridge answer for \(identity.id)")
    }
}
