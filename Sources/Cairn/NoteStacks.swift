import Foundation

/// One run of notes that belong together: the same agent, working in the same
/// place.
///
/// The newest note is held apart from the rest because it is the one the stack
/// is made of — it draws the card, it carries the trail a click follows, and
/// separating it is what makes "the top of the stack" a fact rather than a
/// subscript that could be out of range.
struct NoteStack: Identifiable, Equatable, Sendable {
    let key: String
    let newest: CodexCompletion
    /// Everything under the top card, newest first.
    let older: [CodexCompletion]

    var id: String { key }
    var count: Int { older.count + 1 }
    /// A stack of one is just a note, and draws like one.
    var isStacked: Bool { !older.isEmpty }
    var notes: [CodexCompletion] { [newest] + older }
    var sessionKeys: Set<String> { Set(notes.map(\.sessionKey)) }
}

extension CodexCompletion {
    /// What makes two notes the same pile: one agent, in one place.
    ///
    /// The place is the working directory for the agents that have one, and the
    /// platform for the ones that do not — the same choice `contextName` makes,
    /// so a stack is always named after the thing that gathered it.
    var stackKey: String {
        let source = normalizedSource
        let scope: String
        if ["hermes", "openclaw"].contains(source), let platform, !platform.isEmpty {
            scope = "platform:\(platform.lowercased())"
        } else {
            scope = "cwd:\(cwd)"
        }
        return "\(source)\u{1}\(scope)"
    }
}

/// The queue's layout, decided away from the view that draws it.
///
/// The panel is an `NSPanel` sized by AppKit and filled by SwiftUI, so its
/// height has to be known before the cards exist. Everything here is a pure
/// function of the notes and of which stack is open, which is also what makes
/// it testable.
enum NoteQueue {
    /// How far back the queue remembers. Older notes are dropped by the store;
    /// this is the second guard, at the surface that has to draw them.
    static let maximumSize = 50
    /// How many shoulders peek out from under a collapsed stack. Two is what
    /// says "there is more here" — a third only makes the pile taller.
    static let maximumShoulders = 2
    /// The padding the stack of cards sits in.
    static let verticalPadding = Cairn.Space.lg * 2
    /// Clearing the queue in one gesture is only worth its own control once
    /// dismissing row by row is real work. At two rows the per-row × is faster
    /// than reading a new affordance, so the pill starts at three.
    static let clearAllThreshold = 3
    /// The pill sits below the scroll view, so it costs the panel its own
    /// height plus the bottom padding the stack used to own.
    static let clearAllRowHeight = Cairn.Metrics.noteClearAllHeight + Cairn.Space.lg

    static let minimumHeight: CGFloat = 130
    static let maximumHeight: CGFloat = 710

    static func showsClearAll(for rowCount: Int) -> Bool {
        rowCount >= clearAllThreshold
    }

    /// The queue as rows, newest first.
    ///
    /// A stack takes the position of its newest member, which is the only
    /// ordering that keeps the arrival at the top where the eye is already
    /// looking. With stacking off every note is its own row, so the rest of the
    /// queue never has to ask which mode it is in.
    static func stacks(
        for completions: [CodexCompletion],
        stacking: Bool
    ) -> [NoteStack] {
        let queued = completions.prefix(maximumSize)
        guard stacking else {
            return queued.map { NoteStack(key: $0.sessionKey, newest: $0, older: []) }
        }

        var order: [String] = []
        var grouped: [String: [CodexCompletion]] = [:]
        for completion in queued {
            let key = completion.stackKey
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(completion)
        }

        return order.compactMap { key in
            guard let notes = grouped[key], let newest = notes.first else { return nil }
            return NoteStack(key: key, newest: newest, older: Array(notes.dropFirst()))
        }
    }

    /// One row's height: a card, a card with shoulders under it, or the whole
    /// pile laid out.
    static func height(of stack: NoteStack, isExpanded: Bool) -> CGFloat {
        guard stack.isStacked else { return Cairn.Metrics.noteCardHeight }

        if isExpanded {
            return CGFloat(stack.count) * Cairn.Metrics.noteCardHeight
                + CGFloat(stack.count - 1) * Cairn.Metrics.noteCardSpacing
        }
        return Cairn.Metrics.noteCardHeight
            + CGFloat(min(stack.count - 1, maximumShoulders))
            * Cairn.Metrics.noteStackShoulder
    }

    static func contentHeight(for stacks: [NoteStack], expandedKey: String? = nil) -> CGFloat {
        guard !stacks.isEmpty else { return 0 }

        let rows = stacks.reduce(CGFloat.zero) { total, stack in
            total + height(of: stack, isExpanded: stack.key == expandedKey)
        }
        return rows
            + CGFloat(stacks.count - 1) * Cairn.Metrics.noteCardSpacing
            + verticalPadding
            + (showsClearAll(for: stacks.count) ? clearAllRowHeight : 0)
    }
}
