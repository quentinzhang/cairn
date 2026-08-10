import Foundation
import Testing
@testable import Cairn

private func note(
    source: String = "codex",
    sessionID: String = UUID().uuidString,
    cwd: String = "/Users/someone/Cairn",
    platform: String? = nil,
    result: String = "Done",
    userMessage: String? = nil,
    minutesAgo: Int = 0
) -> CodexCompletion {
    CodexCompletion(
        id: UUID().uuidString,
        version: 1,
        event: "\(source).turn.completed",
        sessionID: sessionID,
        turnID: nil,
        cwd: cwd,
        title: "Completed",
        result: result,
        status: "completed",
        timestamp: Date(timeIntervalSince1970: 10_000 - Double(minutesAgo) * 60),
        source: source,
        userMessage: userMessage,
        model: nil,
        platform: platform,
        locator: nil
    )
}

/// A query with nothing in it is not a filter. Whitespace alone is nothing in
/// it — the field is a text field, and a held space bar must not empty the
/// queue.
@Test
func anEmptyQueryLeavesTheQueueExactlyAsItWas() {
    let queue = (0..<3).map { note(minutesAgo: $0) }

    #expect(NoteSearch.filter(queue, query: "").map(\.id) == queue.map(\.id))
    #expect(NoteSearch.filter(queue, query: "   ").map(\.id) == queue.map(\.id))
    #expect(!NoteSearch.isFiltering(""))
    #expect(!NoteSearch.isFiltering(" \t "))
    #expect(NoteSearch.isFiltering("a"))
}

/// The card shows two lines; the note is the whole answer. Producers cap
/// `result` at 50,000 characters and trim nothing else, so what a query reads
/// is the full text — the point of searching rather than scrolling.
@Test
func aQueryReachesPastTheTwoLinesTheCardShows() {
    let buried = note(
        result: """
        Done.
        Renamed the hook and reinstalled it.
        The notarization step now reads the key from the shell profile.
        """
    )
    let other = note(result: "Done.")

    let found = NoteSearch.filter([buried, other], query: "notarization")
    #expect(found.map(\.id) == [buried.id])
}

/// Everything the card is made of is fair game, plus the path behind the
/// project name — two projects can share a last path component, and the query
/// that tells them apart is the part the card cannot show.
@Test
func everyPartOfANoteIsSearchable() {
    let subject = note(
        cwd: "/Users/someone/work/Cairn",
        platform: "cli",
        result: "Rebuilt the panel.",
        userMessage: "make the queue searchable"
    )

    for query in ["rebuilt", "searchable", "codex", "Cairn", "work/Cairn", "Terminal"] {
        #expect(NoteSearch.matches(subject, query: query), "\(query) should match")
    }
    #expect(!NoteSearch.matches(subject, query: "notarization"))
}

/// Words, not a phrase, and not in order: someone typing "cairn codex" is
/// naming two things they remember about one note, and requiring them to be
/// adjacent fails the query it was most obviously written for.
@Test
func everyWordHasToLandButNotTogether() {
    let subject = note(cwd: "/Users/someone/Cairn", result: "Rebuilt the panel.")

    #expect(NoteSearch.matches(subject, query: "codex cairn"))
    #expect(NoteSearch.matches(subject, query: "panel   rebuilt"))
    // One word missing is a miss, however good the rest of them are.
    #expect(!NoteSearch.matches(subject, query: "codex cairn notarization"))
}

/// Case, accents and CJK width all fold. The last one is not a nicety: Cairn
/// ships in three languages, and a query typed with a full-width keyboard
/// still has to find the half-width text an agent wrote.
@Test
func matchingFoldsCaseAccentsAndWidth() {
    let latin = note(result: "Café rebuilt the PANEL")
    #expect(NoteSearch.matches(latin, query: "panel"))
    #expect(NoteSearch.matches(latin, query: "cafe"))

    let wide = note(result: "Rebuilt the ＰＡＮＥＬ")
    #expect(NoteSearch.matches(wide, query: "panel"))

    // CJK needs no tokenizer here: a substring is the query.
    let chinese = note(result: "已经重建了便签面板", userMessage: "把便签队列改成可搜索的")
    #expect(NoteSearch.matches(chinese, query: "便签"))
    #expect(NoteSearch.matches(chinese, query: "面板 队列"))
    #expect(!NoteSearch.matches(chinese, query: "通知"))
}

/// Why this note. Three results that all open with "Done." are three identical
/// cards until the matched line is lifted onto them.
@Test
func theExcerptIsTheLineTheQueryLandedOn() {
    let body = """
    Done.
    Renamed the hook and reinstalled it.
    The notarization step reads the key from the shell profile.
    """

    #expect(
        NoteSearch.excerpt(from: body, query: "notarization")
            == "The notarization step reads the key from the shell profile."
    )
    // A line carrying the whole query beats one carrying part of it, wherever
    // in the note it sits.
    #expect(
        NoteSearch.excerpt(from: body, query: "notarization hook")
            == "Renamed the hook and reinstalled it."
    )
    // Nothing to lift: the match came from the prompt, the project or the
    // agent, so the card goes on showing what it always shows.
    #expect(NoteSearch.excerpt(from: body, query: "codex") == nil)
    #expect(NoteSearch.excerpt(from: body, query: "") == nil)
}

/// Highlighting has to be the same predicate as filtering. A note that
/// surfaces with nothing lit up in it is what makes a search feel broken while
/// it is in fact correct.
@Test
func everythingThatMatchesCanBeLitUp() {
    let text = "Rebuilt the PANEL and the panel again"
    let ranges = NoteSearch.highlightRanges(in: text, query: "panel")
    #expect(ranges.count == 2)
    #expect(ranges.map { text[$0].lowercased() } == ["panel", "panel"])

    // Whatever the filter accepted, the highlighter can find — including the
    // folded forms, which is the pair most likely to drift apart.
    let wide = "Rebuilt the ＰＡＮＥＬ"
    #expect(NoteSearch.contains(wide, "panel"))
    #expect(!NoteSearch.highlightRanges(in: wide, query: "panel").isEmpty)
}

/// Two tokens that overlap paint one run, not two. An attributed background
/// applied twice is a darker patch, which reads as a third kind of match.
@Test
func overlappingHitsAreMergedIntoOneRun() {
    let text = "searchable"
    let ranges = NoteSearch.highlightRanges(in: text, query: "search searchab able")

    #expect(ranges.count == 1)
    #expect(text[ranges[0]] == "searchable")
    // Ranges come back in reading order, so a renderer can walk them once.
    for (earlier, later) in zip(ranges, ranges.dropFirst()) {
        #expect(earlier.upperBound <= later.lowerBound)
    }
}

/// Searching is over a fixed corpus — the store keeps fifty notes and drops the
/// rest — so the whole thing runs synchronously on the main actor between two
/// keystrokes. This is the guard on that assumption, not a benchmark.
@Test
func aFullQueueIsFilteredWellInsideAKeystroke() {
    let queue = (0..<NoteQueue.maximumSize).map { index in
        note(
            result: String(repeating: "The notarization step reads the key. ", count: 400),
            userMessage: "note \(index)",
            minutesAgo: index
        )
    }

    let started = Date()
    let found = NoteSearch.filter(queue, query: "notarization key")
    let elapsed = Date().timeIntervalSince(started)

    #expect(found.count == queue.count)
    #expect(elapsed < 0.1)
}
