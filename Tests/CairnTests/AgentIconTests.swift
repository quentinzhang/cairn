import AppKit
import Foundation
import Testing
@testable import Cairn

/// A shipped mark that stops loading is invisible, not broken — the menu just
/// quietly falls back to a lettermark. So the test is that every file named in
/// `AgentIconAsset` is actually in the bundle and actually decodes.
@Test @MainActor
func everyShippedAgentIconLoadsAsATemplate() throws {
    for id in AgentIconAsset.shippedRuntimeIDs.sorted() {
        let image = try #require(
            AgentIconAsset.image(for: id),
            "no icon loaded for \(id)"
        )
        #expect(image.isTemplate, "\(id) must render as a template image")
        #expect(image.size.width > 0 && image.size.height > 0)
    }
}

/// The marks are only ever addressed by runtime id, so a typo in either list
/// shows up as an agent that silently loses its icon.
@Test
func shippedIconsNameRealRuntimes() {
    let known = Set(AgentRuntimeIdentity.all.map(\.id))
    #expect(AgentIconAsset.shippedRuntimeIDs.isSubset(of: known))
}

/// Hermes has no vector mark, so it must resolve to no image rather than to
/// some other agent's. This is the case that keeps the fallback path live.
@Test @MainActor
func agentsWithoutAMarkResolveToNothing() {
    #expect(AgentIconAsset.image(for: "hermes") == nil)
    #expect(AgentIconAsset.image(for: "not-an-agent") == nil)
}

/// `AgentGlyph` colours itself through `Cairn.Agent`, which keys on the note
/// source rather than the runtime id. Claude Code is the one place those two
/// disagree, and getting it wrong is a wrong-coloured glyph, not a crash.
@Test
func toneSourcesMatchTheColoursCairnDefines() {
    #expect(AgentRuntimeIdentity.identity(for: "claude").toneSource == "claude-code")

    for identity in AgentRuntimeIdentity.all {
        #expect(
            Cairn.Agent.identity(for: identity.toneSource).name == identity.name,
            "\(identity.id) falls through to the unknown tone"
        )
    }
}
