import AppKit
import Foundation
import Testing
@testable import Cairn

/// A shipped mark that stops loading is invisible, not broken — the surfaces
/// just quietly fall back to a lettermark. So the test is that every file named
/// in `AgentIconAsset` is actually in the bundle and actually decodes.
@Test @MainActor
func everyShippedAgentIconLoadsAsATemplate() throws {
    for source in AgentIconAsset.shippedSources.sorted() {
        let image = try #require(
            AgentIconAsset.image(for: source),
            "no icon loaded for \(source)"
        )
        #expect(image.isTemplate, "\(source) must render as a template image")
        #expect(image.size.width > 0 && image.size.height > 0)
    }
}

/// The marks are addressed by note source, so a typo in either list shows up as
/// an agent that silently loses its icon.
@Test
func shippedIconsNameAgentsCairnKnows() {
    for source in AgentIconAsset.shippedSources {
        #expect(
            Cairn.Agent.identity(for: source).tone.hue != Cairn.Tone.unknown.hue,
            "\(source) has a mark but falls through to the unknown tone"
        )
    }
}

/// Hermes has no vector mark, so it must resolve to no image rather than to
/// some other agent's. This is the case that keeps the fallback path live.
@Test @MainActor
func agentsWithoutAMarkResolveToNothing() {
    #expect(AgentIconAsset.image(for: "hermes") == nil)
    #expect(AgentIconAsset.image(for: "not-an-agent") == nil)
}

/// Everything outside the notes addresses agents by runtime id, and the marks
/// and colours are keyed on the note source. Claude Code is the one place those
/// two disagree, and getting it wrong is a missing icon, not a crash.
@Test
func everyRuntimeReachesTheAgentItNames() {
    #expect(AgentRuntimeIdentity.identity(for: "claude").toneSource == "claude-code")

    for identity in AgentRuntimeIdentity.all {
        #expect(
            Cairn.Agent.identity(for: identity.toneSource).name == identity.name,
            "\(identity.id) falls through to the unknown tone"
        )
    }
}
