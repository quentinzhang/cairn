import SwiftUI
import Testing
@testable import Cairn

/// Cairn draws into transparent panel windows fitted tightly around their
/// content, and a window does not fade a blur that runs past its frame — it
/// cuts it. A radius wider than the room it has therefore stops being a soft
/// shadow and becomes a grey band with a hard outer edge: invisible on a dark
/// desktop, an obvious ring on a white one.
///
/// Nothing in the type system says a shadow has to fit, and nothing on a dark
/// screen says it doesn't, so the budget is asserted here instead.
private func extent(
    _ layer: Cairn.Shadow.Layer
) -> (down: CGFloat, up: CGFloat, side: CGFloat) {
    // A blur reaches roughly twice its radius before it is gone.
    let reach = layer.radius * 2
    return (down: reach + layer.y, up: reach - layer.y, side: reach)
}

private func expectFits(
    _ shadow: Cairn.Shadow,
    horizontal: CGFloat,
    vertical: CGFloat,
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for (pass, layer) in [("ambient", shadow.ambient), ("contact", shadow.contact)].compactMap({
        name, layer in layer.map { (name, $0) }
    }) {
        let reach = extent(layer)
        #expect(
            reach.side <= horizontal,
            "\(label) \(pass) reaches \(reach.side)pt sideways into \(horizontal)pt of room",
            sourceLocation: sourceLocation
        )
        #expect(
            reach.down <= vertical,
            "\(label) \(pass) reaches \(reach.down)pt below into \(vertical)pt of room",
            sourceLocation: sourceLocation
        )
        #expect(
            reach.up <= vertical,
            "\(label) \(pass) reaches \(reach.up)pt above into \(vertical)pt of room",
            sourceLocation: sourceLocation
        )
    }
}

@Test
func everyControlShadowFadesOutBeforeTheWindowEndsIt() {
    let room = Cairn.Metrics.controlShadowRoom

    for scheme in [ColorScheme.light, .dark] {
        expectFits(
            .controlResting(scheme),
            horizontal: room.width,
            vertical: room.height,
            "controlResting(\(scheme))"
        )
        expectFits(
            .controlHover(scheme),
            horizontal: room.width,
            vertical: room.height,
            "controlHover(\(scheme))"
        )
    }

    // The arrival glow lives in the same window as the shadow it replaces.
    expectFits(
        .controlAttention,
        horizontal: room.width,
        vertical: room.height,
        "controlAttention"
    )
}

@Test
func everyNoteShadowFadesOutBeforeThePanelEdgeCutsIt() {
    let room = Cairn.Metrics.noteShadowRoom

    for scheme in [ColorScheme.light, .dark] {
        expectFits(.note(scheme), horizontal: room, vertical: room, "note(\(scheme))")
    }
}

/// The room itself is arithmetic on two metrics that are free to move. If the
/// panel is ever fitted tighter around the body, the budget above has to move
/// with it rather than quietly go negative.
@Test
func theControlLeavesRoomForAShadowAtAll() {
    #expect(Cairn.Metrics.controlShadowRoom.width > 0)
    #expect(Cairn.Metrics.controlShadowRoom.height > 0)
    #expect(Cairn.Metrics.controlPanel.width > Cairn.Metrics.controlBody.width)
    #expect(Cairn.Metrics.controlPanel.height > Cairn.Metrics.controlBody.height)
}
