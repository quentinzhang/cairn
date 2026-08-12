import Foundation

/// Finding a note again, in a queue that never holds more than fifty of them.
///
/// The whole corpus is what the producers already wrote down: `result` is the
/// final assistant message in full — the five bridges cap it at 50,000
/// characters and nothing else trims it — and `user_message` is the prompt as
/// typed. The card shows two lines of that; the search reads all of it. So the
/// question a query answers is "which of these fifty", not "what exists
/// somewhere", and substring matching is the whole of what that question
/// needs.
///
/// Everything here is a pure function of a string and a query, which is what
/// lets the panel's arithmetic and the panel's drawing agree without either
/// one asking the other.
enum NoteSearch {
    /// One comparison, used by every part of this file.
    ///
    /// Matching and highlighting have to be the same predicate or a note
    /// surfaces with nothing lit up in it — the failure that makes a search box
    /// feel broken even when it is right. Case, accents and CJK width all fold
    /// here, which is also why a query typed on a full-width keyboard finds a
    /// half-width result.
    static let matchOptions: String.CompareOptions = [
        .caseInsensitive,
        .diacriticInsensitive,
        .widthInsensitive,
    ]

    /// A query is its words, in any order. Whitespace is a separator rather
    /// than a character to match: someone typing "codex cairn" is naming two
    /// things they remember, not a phrase they expect to find intact.
    static func tokens(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether a query is asking for anything at all. Spaces alone are not.
    static func isFiltering(_ query: String) -> Bool {
        !tokens(in: query).isEmpty
    }

    static func filter(
        _ completions: [CodexCompletion],
        query: String
    ) -> [CodexCompletion] {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty else { return completions }
        return completions.filter { matches($0, tokens: tokens) }
    }

    static func matches(_ completion: CodexCompletion, query: String) -> Bool {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty else { return true }
        return matches(completion, tokens: tokens)
    }

    /// Every word has to land somewhere in the note — not necessarily in the
    /// same field. "codex cairn" is one word about who and one about where, and
    /// requiring them to meet in one sentence would fail the query it was most
    /// obviously written for.
    private static func matches(
        _ completion: CodexCompletion,
        tokens: [String]
    ) -> Bool {
        let haystack = completion.searchHaystack
        return tokens.allSatisfy { contains(haystack, $0) }
    }

    static func contains(_ text: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return text.range(of: token, options: matchOptions, locale: .current) != nil
    }

    /// The line of the answer the query actually landed on.
    ///
    /// A card that always shows the first two lines of a note is no help once a
    /// search has narrowed it: three results all opening with "Done." tell you
    /// nothing about which one you meant. Lifting the matched line answers
    /// "why am I seeing this" without opening anything.
    ///
    /// A line carrying the whole query beats a line carrying part of it, and
    /// `nil` means the match came from somewhere else — the prompt, the
    /// project, the agent's name — so the card should go on showing what it
    /// always shows.
    static func excerpt(from body: String, query: String) -> String? {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty else { return nil }

        let lines = body
            .split(whereSeparator: \.isNewline)
            .map { String($0).singleLine }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        if let whole = lines.first(where: { line in
            tokens.allSatisfy { contains(line, $0) }
        }) {
            return whole
        }
        return lines.first { line in
            tokens.contains { contains(line, $0) }
        }
    }

    /// Where to light the text up, as ranges into the string handed in.
    ///
    /// Overlapping hits are merged so two tokens that share a character cannot
    /// paint the same run twice — an attributed background applied twice is a
    /// darker patch, which reads as a third kind of match.
    static func highlightRanges(in text: String, query: String) -> [Range<String.Index>] {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty, !text.isEmpty else { return [] }

        var found: [Range<String.Index>] = []
        for token in tokens where !token.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let hit = text.range(
                      of: token,
                      options: matchOptions,
                      range: searchStart..<text.endIndex,
                      locale: .current
                  ) {
                found.append(hit)
                // A width- or diacritic-folded comparison can report an empty
                // range; stepping one character keeps this a loop rather than a
                // hang.
                searchStart = hit.upperBound > hit.lowerBound
                    ? hit.upperBound
                    : text.index(after: hit.lowerBound)
            }
        }

        return merged(found)
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in sorted {
            guard let last = merged.last, range.lowerBound <= last.upperBound else {
                merged.append(range)
                continue
            }
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        }
        return merged
    }
}

extension CodexCompletion {
    /// Everything a query is allowed to land on.
    ///
    /// The card's own text first — the answer, the prompt, the agent, the
    /// project, the surface — because those are the words someone is actually
    /// trying to remember. `cwd` follows for the case the card cannot show: a
    /// project whose name is ambiguous until you see the path above it.
    var searchHaystack: String {
        [
            result,
            userMessage ?? "",
            identity.name,
            contextName,
            executionSurfaceName,
            cwd,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
