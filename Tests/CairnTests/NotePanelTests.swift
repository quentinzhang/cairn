import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cairn

/// macOS hands the pointer straight through any pixel a borderless window
/// leaves fully clear, so the gaps between note cards used to swallow the
/// scroll wheel. The veil is what makes the whole panel part of the window —
/// it has to stay above one 8-bit alpha step, and stay invisible.
@Test
@MainActor
func theNotePanelIsOpaqueToTheMouseEverywhere() {
    let alpha = NSColor(Cairn.Surface.eventVeil).alphaComponent
    #expect(alpha >= 1.0 / 255.0)
    #expect(alpha <= 0.02)
}

private func note(
    id: String = UUID().uuidString,
    source: String = "codex",
    sessionID: String = UUID().uuidString,
    cwd: String = "/Users/someone/Cairn",
    platform: String? = nil,
    locator: CairnLocator? = nil,
    minutesAgo: Int = 0
) -> CodexCompletion {
    CodexCompletion(
        id: id,
        version: 1,
        event: "\(source).turn.completed",
        sessionID: sessionID,
        turnID: nil,
        cwd: cwd,
        title: "Completed",
        result: "Done",
        status: "completed",
        timestamp: Date(timeIntervalSince1970: 10_000 - Double(minutesAgo) * 60),
        source: source,
        userMessage: nil,
        model: nil,
        platform: platform,
        locator: locator
    )
}

/// A project name says where the work belongs; the adjacent tag says which
/// surface it came from. The locator wins because a CLI payload can still have
/// originated inside VS Code or a specific terminal app.
@Test
func noteHeadersNameTheirExecutionSurface() {
    #expect(note(platform: "cli").executionSurfaceName == "Terminal")
    #expect(note(platform: "desktop").executionSurfaceName == "App")
    #expect(
        note(
            platform: "cli",
            locator: CairnLocator(
                termProgram: "vscode",
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
        ).executionSurfaceName == "VS Code"
    )
    #expect(
        note(
            locator: CairnLocator(
                termProgram: "iTerm.app",
                termSessionID: nil,
                itermSessionID: nil,
                tmuxPane: nil,
                tty: nil,
                hostAppPath: nil,
                hostAppPID: nil,
                agentPID: nil,
                hostApps: nil,
                webURL: nil,
                browserBundleID: nil
            )
        ).executionSurfaceName == "iTerm"
    )
}

/// The whole point of the feature: one agent, one project, one row — and the
/// pile keeps the place its newest note had, so an arrival still lands where
/// the eye is already looking.
@Test
func notesFromOneAgentInOneProjectGatherIntoOneStack() {
    let queue = [
        note(source: "codex", cwd: "/Users/someone/Cairn", minutesAgo: 0),
        note(source: "claude-code", cwd: "/Users/someone/Cairn", minutesAgo: 1),
        note(source: "codex", cwd: "/Users/someone/Cairn", minutesAgo: 2),
        note(source: "codex", cwd: "/Users/someone/Other", minutesAgo: 3),
    ]

    let stacks = NoteQueue.stacks(for: queue, stacking: true)
    #expect(stacks.count == 3)
    #expect(stacks[0].count == 2)
    #expect(stacks[0].newest.id == queue[0].id)
    #expect(stacks[0].older.map(\.id) == [queue[2].id])
    // A different agent in the same project is a different pile, and so is the
    // same agent in a different one.
    #expect(!stacks[1].isStacked)
    #expect(!stacks[2].isStacked)

    // Off, the queue is what it always was: one note, one row.
    let flat = NoteQueue.stacks(for: queue, stacking: false)
    #expect(flat.count == queue.count)
    #expect(flat.allSatisfy { !$0.isStacked })
    #expect(flat.map(\.key) == queue.map(\.sessionKey))
}

/// The agents whose work has no working directory are grouped by the surface
/// they ran on — the same thing their notes are labelled with.
@Test
func agentsWithoutAProjectStackByPlatform() {
    let queue = [
        note(source: "openclaw", cwd: "/", platform: "Slack"),
        note(source: "openclaw", cwd: "/tmp", platform: "Slack"),
        note(source: "openclaw", cwd: "/", platform: "Discord"),
    ]

    let stacks = NoteQueue.stacks(for: queue, stacking: true)
    #expect(stacks.count == 2)
    #expect(stacks[0].count == 2)
}

/// The panel is sized by AppKit before SwiftUI draws a card, so the arithmetic
/// has to agree with the layout: a collapsed pile costs its shoulders, an open
/// one costs every card in it.
@Test
func aStackCostsItsShouldersClosedAndEveryCardOpen() {
    let single = NoteQueue.stacks(for: [note()], stacking: true)[0]
    #expect(NoteQueue.height(of: single, isExpanded: false) == Cairn.Metrics.noteCardHeight)
    // Nothing peeks out from under a note that is alone, open or not.
    #expect(NoteQueue.height(of: single, isExpanded: true) == Cairn.Metrics.noteCardHeight)

    let session = "shared-project"
    let pile = NoteQueue.stacks(
        for: (0..<4).map { note(sessionID: "\(session)-\($0)", minutesAgo: $0) },
        stacking: true
    )[0]
    #expect(pile.count == 4)
    // Two shoulders, not three: past two, a deeper pile only gets taller.
    #expect(
        NoteQueue.height(of: pile, isExpanded: false)
            == Cairn.Metrics.noteCardHeight + Cairn.Metrics.noteStackShoulder * 2
    )
    #expect(
        NoteQueue.height(of: pile, isExpanded: true)
            == Cairn.Metrics.noteCardHeight * 4 + Cairn.Metrics.noteCardSpacing * 3
    )

    // Opening a pile is the one thing that makes the panel grow.
    let stacks = NoteQueue.stacks(
        for: (0..<4).map { note(sessionID: "\(session)-\($0)", minutesAgo: $0) },
        stacking: true
    )
    let closed = NoteQueue.contentHeight(for: stacks, expandedKey: nil)
    let open = NoteQueue.contentHeight(for: stacks, expandedKey: stacks[0].key)
    #expect(open > closed)
    #expect(NoteQueue.contentHeight(for: []) == 0)
}

/// The pill that clears everything is priced against rows, not notes: five
/// notes gathered into one stack are one × away, and that is not work worth a
/// second control.
@Test
func clearingAllIsOfferedOnceThereAreRowsToClear() {
    #expect(!NoteQueue.showsClearAll(for: 2))
    #expect(NoteQueue.showsClearAll(for: 3))

    let pile = NoteQueue.stacks(
        for: (0..<5).map { note(sessionID: "one-project-\($0)", minutesAgo: $0) },
        stacking: true
    )
    #expect(pile.count == 1)
    #expect(!NoteQueue.showsClearAll(for: pile.count))
}

/// Two sizes, one multiplier: every part of the desktop control is derived
/// from the resting metrics, so nothing can grow out of proportion with the
/// panel that has to hold it.
@Test
func theDesktopControlScalesAsOnePiece() {
    for size in CairnControlSize.allCases {
        let panel = Cairn.Metrics.controlPanel.scaled(by: size.scale)
        let body = Cairn.Metrics.controlBody.scaled(by: size.scale)
        let mark = Cairn.Metrics.controlMark.scaled(by: size.scale)

        #expect(body.width <= panel.width)
        #expect(body.height <= panel.height)
        #expect(mark.width <= body.width)
        #expect(mark.height <= body.height)
    }
}
