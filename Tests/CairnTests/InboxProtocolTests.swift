import Foundation
import Testing
@testable import Cairn

/// Locks the consumer end of `docs/inbox-protocol.md`.
///
/// Producers live outside this repository — anything that can write a JSON file
/// is one — so a change to `CodexCompletion` that tightens decoding is a silent
/// breaking change for code Cairn cannot see. These tests fail when that
/// happens. `Tests/protocol_roundtrip.py` covers the producer end.

private func decode(_ json: String) throws -> CodexCompletion {
    try CairnJSON.decoder().decode(CodexCompletion.self, from: Data(json.utf8))
}

/// Exactly the required fields from §3, and nothing else.
private let minimalPayload = """
{
  "id": "01H8XYZ:turn-42",
  "version": 1,
  "event": "ci.build.completed",
  "session_id": "build:myproject",
  "cwd": "",
  "title": "Build finished · myproject",
  "result": "All 214 tests passed.",
  "status": "completed",
  "timestamp": "2026-07-27T16:45:12Z"
}
"""

@Test
func requiredFieldsAloneDecode() throws {
    let completion = try decode(minimalPayload)
    #expect(completion.id == "01H8XYZ:turn-42")
    #expect(completion.sessionID == "build:myproject")
    #expect(completion.turnID == nil)
    #expect(completion.locator == nil)
    #expect(completion.cwd.isEmpty)
}

@Test
func everyOptionalFieldDecodes() throws {
    let completion = try decode("""
    {
      "id": "a:b",
      "version": 1,
      "event": "codex.turn.completed",
      "session_id": "s",
      "turn_id": "t",
      "cwd": "/tmp/project",
      "title": "Codex completed · project",
      "result": "done",
      "status": "completed",
      "source": "codex",
      "timestamp": "2026-07-27T16:45:12.338410Z",
      "user_message": "make the trail-back work",
      "model": "gpt-5-codex",
      "platform": "cli",
      "locator": {
        "term_program": "iTerm.app",
        "iterm_session_id": "w0t1p0:UUID",
        "tty": "ttys004",
        "agent_pid": 4242,
        "host_app_path": "/Applications/iTerm.app",
        "host_app_pid": 4200,
        "host_apps": [{"path": "/Applications/iTerm.app", "pid": 4200}],
        "web_url": "http://127.0.0.1:18789/chat?session=agent%3Amain%3Amain",
        "browser_bundle_id": "com.google.Chrome"
      }
    }
    """)
    #expect(completion.userMessage == "make the trail-back work")
    #expect(completion.model == "gpt-5-codex")
    #expect(completion.platform == "cli")
    #expect(completion.locator?.tty == "ttys004")
    #expect(completion.locator?.hostApps?.first?.pid == 4200)
    #expect(
        completion.locator?.webURL
            == "http://127.0.0.1:18789/chat?session=agent%3Amain%3Amain"
    )
    #expect(completion.locator?.browserBundleID == "com.google.Chrome")
}

@Test
func unknownFieldsAreIgnoredRatherThanRejected() throws {
    // §3: extra keys are the protocol's extension point. A future producer must
    // be able to send a field this build has never heard of.
    let completion = try decode("""
    {
      "id": "a:b", "version": 1, "event": "x.turn.completed", "session_id": "s",
      "cwd": "", "title": "t", "result": "r", "status": "completed",
      "timestamp": "2026-07-27T16:45:12Z",
      "cost_usd": 0.42,
      "tags": ["experimental"],
      "locator": { "unheard_of": "value" }
    }
    """)
    #expect(completion.result == "r")
    #expect(completion.locator != nil)
}

@Test
func everyTimestampFormThisDocumentPromisesDecodes() throws {
    // §3 promises: fractional seconds optional, Z or +00:00 both accepted.
    for stamp in [
        "2026-07-27T16:45:12Z",
        "2026-07-27T16:45:12.338410Z",
        "2026-07-27T16:45:12.338Z",
        "2026-07-27T16:45:12+00:00",
    ] {
        let completion = try decode(
            minimalPayload.replacingOccurrences(of: "2026-07-27T16:45:12Z", with: stamp)
        )
        // Fractional forms keep their sub-second part, so compare within the second.
        let elapsed = completion.timestamp.timeIntervalSince1970 - 1_785_170_712
        #expect(elapsed >= 0 && elapsed < 1, "\(stamp) decoded to \(completion.timestamp)")
    }
}

@Test
func aMissingRequiredFieldIsRejected() {
    // The other half of the contract: what the doctor's validator must also
    // reject, so its diagnosis matches what actually happened.
    for field in ["id", "version", "event", "session_id", "cwd", "title", "result", "status", "timestamp"] {
        var payload = try! JSONSerialization.jsonObject(
            with: Data(minimalPayload.utf8)
        ) as! [String: Any]
        payload.removeValue(forKey: field)
        let data = try! JSONSerialization.data(withJSONObject: payload)
        #expect(
            (try? CairnJSON.decoder().decode(CodexCompletion.self, from: data)) == nil,
            "decoding should fail without '\(field)'"
        )
    }
}

@Test
func sourceFallsBackToTheEventPrefix() throws {
    // §4: an omitted source is recoverable from the event name, which keeps
    // pre-`source` payloads and terse producers working.
    let completion = try decode(minimalPayload)
    #expect(completion.source == nil)
    #expect(Cairn.Agent.identity(for: "ci").name == "Ci")
}

@Test
func anUnregisteredSourceRendersGenericallyRatherThanFailing() {
    // §4: shipping a producer must never require a change to this app.
    let unknown = Cairn.Agent.identity(for: "aider")
    #expect(unknown.name == "Aider")

    #expect(Cairn.Agent.identity(for: "codex").name == "Codex")
    #expect(Cairn.Agent.identity(for: "claude-code").name == "Claude Code")
    #expect(Cairn.Agent.identity(for: "hermes").name == "Hermes")
    #expect(Cairn.Agent.identity(for: "openclaw").name == "OpenClaw")
}
