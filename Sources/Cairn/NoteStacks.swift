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
    /// Acting on the queue as a whole — clearing it, searching it — is only
    /// worth a control once doing it by hand is real work. At two rows the
    /// per-row × is faster than reading a new affordance, and two notes are
    /// read faster than a query is typed. Both start at three.
    static let chromeThreshold = 3
    /// The controls sit in one row pinned above the scroll view, so they cost
    /// the panel their own height plus the top padding the stack used to own.
    static let chromeRowHeight = Cairn.Metrics.noteChromeHeight + Cairn.Space.lg

    static let minimumHeight: CGFloat = 130
    static let maximumHeight: CGFloat = 710

    /// Which of the queue's own controls are on screen — asked once, by the
    /// presenter, and handed to both the arithmetic below and the view that
    /// draws it. The panel is sized before a single card exists, so a second
    /// opinion about whether a row is showing is a panel cut off at the bottom.
    struct QueueChrome: Equatable, Sendable {
        var showsHeader = false
        var showsClearAll = false
        var showsEmptyResult = false

        static let none = QueueChrome()
    }

    /// - Parameters:
    ///   - noteCount: every note in the queue, filtered or not.
    ///   - rowCount: the rows actually on screen.
    static func chrome(
        noteCount: Int,
        rowCount: Int,
        isFiltering: Bool
    ) -> QueueChrome {
        QueueChrome(
            // Priced against notes rather than rows: stacking can fold ten
            // notes from one project into a single row, and ten notes is
            // exactly when a search stops being a novelty. The filter keeps
            // the row alive on its own, so narrowing a search down to nothing
            // cannot take away the field you are typing into.
            showsHeader: noteCount >= chromeThreshold || isFiltering,
            // Priced against rows, because rows are what it clears — and
            // never offered mid-search, where "all" would have to mean either
            // the matches or the queue behind them. A control with two
            // readings and one irreversible outcome does not get to ship.
            showsClearAll: !isFiltering && rowCount >= chromeThreshold,
            showsEmptyResult: isFiltering && rowCount == 0
        )
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

    static func contentHeight(
        for stacks: [NoteStack],
        expandedKey: String? = nil,
        chrome: QueueChrome = .none
    ) -> CGFloat {
        let header = chrome.showsHeader ? chromeRowHeight : 0

        guard !stacks.isEmpty else {
            // A search that found nothing still has to stand somewhere: the
            // field is open, and a panel that vanished under the cursor would
            // take it with it.
            guard chrome.showsEmptyResult else { return header }
            return header + Cairn.Metrics.noteEmptyResultHeight + verticalPadding
        }

        let rows = stacks.reduce(CGFloat.zero) { total, stack in
            total + height(of: stack, isExpanded: stack.key == expandedKey)
        }
        return header
            + rows
            + CGFloat(stacks.count - 1) * Cairn.Metrics.noteCardSpacing
            + verticalPadding
    }
}
