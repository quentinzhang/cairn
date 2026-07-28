import AppKit
import SwiftUI

// MARK: - Asset

/// The agent marks Cairn ships, and the one rule for drawing them.
///
/// Every file in `Resources/AgentIcons` is a silhouette, loaded as a template
/// image so only its alpha survives. That is what lets one mark sit in a light
/// menu and a dark one without a second file, and what keeps a foreign brand
/// from bringing its own colour into a palette that already means something —
/// the tint comes from `Cairn.Tone`, so the glyph says *which* agent for the
/// same reason a note's rail does.
///
/// Not every agent has a mark. Hermes ships only a raster banner, so it — and
/// any agent Cairn meets later — falls back to a lettermark rather than to a
/// borrowed or invented logo.
enum AgentIconAsset {
    /// Resource base names, by note source — the same key `Cairn.Agent` uses.
    /// A source missing here is not an error; it draws as a lettermark.
    private static let names: [String: String] = [
        "codex": "AgentIcon-codex",
        "claude-code": "AgentIcon-claude",
        "openclaw": "AgentIcon-openclaw"
    ]

    @MainActor private static var cache: [String: NSImage] = [:]

    /// The mark for an agent, or nil when Cairn ships none for it.
    ///
    /// Cached because a menu redraws on every hover and `NSImage` re-reads the
    /// file each time it is created.
    @MainActor
    static func image(for source: String) -> NSImage? {
        if let cached = cache[source] { return cached }
        guard let name = names[source],
              let url = CairnResources.bundle.url(
                forResource: name,
                withExtension: "svg"
              ),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        cache[source] = image
        return image
    }

    /// Sources Cairn ships a mark for — what the tests check against the
    /// agents `Cairn.Agent` knows.
    static var shippedSources: Set<String> { Set(names.keys) }
}

// MARK: - Glyph

/// One agent's mark at a fixed size, tinted with that agent's colour.
///
/// Falls back to the first letter of the agent's name when no mark is shipped.
/// The lettermark is a filled tile rather than bare text: next to three logos,
/// a floating glyph reads as a rendering failure, and a tile reads as an icon.
struct AgentGlyph: View {
    let agent: Cairn.Agent
    var size: CGFloat = 13

    @Environment(\.colorScheme) private var scheme

    private var tint: Color { agent.tone.rail(scheme) }

    var body: some View {
        Group {
            if let image = AgentIconAsset.image(for: agent.id) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
            } else {
                lettermark
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.name)
    }

    /// A washed tile rather than a solid one: beside line-art logos, a solid
    /// chip is the heaviest thing in the row, and the agent without a mark is
    /// the last one that should shout.
    private var lettermark: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.opacity(0.18))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(tint.opacity(0.55), lineWidth: Cairn.Stroke.width)
            }
            .overlay {
                Text(agent.name.prefix(1))
                    .font(.system(size: size * 0.60, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

/// The connected agents, in the order the connect window lists them.
///
/// Deliberately not a count: the number is already next to it, and repeating
/// it in dots would spend the same pixels saying less.
struct AgentGlyphStrip: View {
    let agents: [Cairn.Agent]
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: Cairn.Space.xs) {
            ForEach(agents, id: \.id) { agent in
                AgentGlyph(agent: agent, size: size)
            }
        }
    }
}
