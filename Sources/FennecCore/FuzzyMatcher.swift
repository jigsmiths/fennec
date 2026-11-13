import Foundation

/// fzf-style fuzzy matching: the query's characters must appear in order, and matches that are consecutive or
/// start a word score higher. Works on UTF-16 so positions line up with NSString ranges for highlighting.
public enum FuzzyMatcher {
    public struct Candidate: Sendable {
        public let text: String
        let chars: [UInt16]
        /// Where the last path component starts.
        let nameStart: Int

        public init(_ text: String) {
            self.text = text
            chars = Array(text.utf16)
            nameStart = (chars.lastIndex(of: slash) ?? -1) + 1
        }
    }

    /// Space-separated terms; a candidate must match every one.
    public struct Query: Sendable {
        let text: String
        let terms: [[UInt16]]

        public init(_ text: String) {
            self.text = text
            terms = text.split(separator: " ").map { $0.utf16.map(fold) }
        }

        public var isEmpty: Bool { terms.isEmpty }
    }

    public struct Match: Sendable, Equatable {
        public let score: Int
        /// UTF-16 offsets of the matched characters, ascending.
        public let positions: [Int]
    }

    public struct Ranked: Sendable {
        public let index: Int
        public let match: Match
    }

    /// Part of the candidates, such as one folder's subtree in an index of a parent folder.
    public struct Scope: Sendable {
        /// The candidates to search, ascending.
        public let indices: [Int]
        /// UTF-16 units at the start of each text to ignore, e.g. the folder's path relative to the index root.
        public let skip: Int

        public init(indices: [Int], skip: Int) {
            self.indices = indices
            self.skip = skip
        }
    }

    /// What a search needs to narrow the next one when the user keeps typing.
    public struct SearchState: Sendable {
        let queryText: String
        let skip: Int
        /// Indexes of every match, ascending; nil means every candidate.
        let matched: [Int]?
        /// How many candidates existed; later ones were never looked at.
        let scanned: Int
    }

    public struct SearchResult: Sendable {
        public let top: [Ranked]
        public let matchCount: Int
        public let state: SearchState
    }

    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let delimiters: Set<UInt16> = Set("-_. ".utf16)

    private static let matchScore = 16
    private static let boundaryBonus = 10
    private static let delimiterBonus = 9
    private static let camelBonus = 8
    private static let consecutiveBonus = 5
    private static let gapStartPenalty = 3
    private static let gapExtensionPenalty = 1
    private static let filenameBonus = 20

    /// Below this, splitting the work across cores costs more than it saves.
    private static let chunkSize = 16_384

    /// Matches from UTF-16 offset `skip` on; positions are still offsets into the whole text.
    public static func match(_ query: Query, _ candidate: Candidate, skip: Int = 0) -> Match? {
        var scratch = [Int](repeating: 0, count: query.terms.map(\.count).max() ?? 0)
        var positions: [Int] = []
        let score = self.score(query, candidate, skip: skip, scratch: &scratch, positions: { positions += $0 })
        guard let score else { return nil }
        if query.terms.count > 1 { positions = Array(Set(positions)).sorted() }
        return Match(score: score, positions: positions)
    }

    /// The best `limit` matches, highest score first, shorter text breaking ties. An empty query keeps input order.
    public static func rank(_ query: Query, in candidates: [Candidate], limit: Int) -> [Ranked] {
        search(query, in: candidates, limit: limit).top
    }

    /// Like `rank`, plus a match count and state for narrowing. When the query extends the previous one, only the
    /// previous matches (and candidates added since) can still match, so only they are scored. A `scope` limits
    /// the search to some candidates and ignores a shared leading part of their text.
    public static func search(
        _ query: Query, in candidates: [Candidate], limit: Int, after previous: SearchState? = nil,
        scope: Scope? = nil
    ) -> SearchResult {
        let skip = scope?.skip ?? 0
        let inScope = scope?.indices ?? Array(candidates.indices)
        if query.isEmpty {
            let top = inScope.prefix(limit).map { Ranked(index: $0, match: Match(score: 0, positions: [])) }
            return SearchResult(
                top: top, matchCount: inScope.count,
                state: SearchState(queryText: query.text, skip: skip, matched: nil, scanned: candidates.count))
        }

        let scan: [Int]
        if let previous, let matched = previous.matched, query.text.hasPrefix(previous.queryText),
           previous.skip == skip, previous.scanned <= candidates.count {
            // Scope indices are ascending, so the ones added since are a suffix.
            var low = 0, high = inScope.count
            while low < high {
                let mid = (low + high) / 2
                if inScope[mid] < previous.scanned { low = mid + 1 } else { high = mid }
            }
            scan = matched + inScope[low...]
        } else {
            scan = inScope
        }

        let chunkCount = max(1, (scan.count + chunkSize - 1) / chunkSize)
        var chunks = [Chunk](repeating: Chunk(), count: chunkCount)
        let maxTerm = query.terms.map(\.count).max() ?? 0
        chunks.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes only its own slot.
            nonisolated(unsafe) let results = buffer
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                var scratch = [Int](repeating: 0, count: maxTerm)
                var result = Chunk()
                let start = chunk * chunkSize
                for index in scan[start..<min(start + chunkSize, scan.count)] {
                    let candidate = candidates[index]
                    guard let score = score(query, candidate, skip: skip, scratch: &scratch, positions: nil)
                    else { continue }
                    result.matched.append(index)
                    result.offer(Scored(score: score, length: candidate.chars.count, index: index), limit: limit)
                }
                results[chunk] = result
            }
        }

        var matched: [Int] = []
        matched.reserveCapacity(chunks.reduce(0) { $0 + $1.matched.count })
        var best: [Scored] = []
        for chunk in chunks {
            matched += chunk.matched
            best += chunk.top
        }
        best.sort(by: Scored.ranksBefore)
        let top = best.prefix(limit).compactMap { scored in
            match(query, candidates[scored.index], skip: skip).map { Ranked(index: scored.index, match: $0) }
        }
        return SearchResult(
            top: top, matchCount: matched.count,
            state: SearchState(queryText: query.text, skip: skip, matched: matched, scanned: candidates.count))
    }

    private struct Scored {
        let score: Int
        let length: Int
        let index: Int

        static func ranksBefore(_ a: Scored, _ b: Scored) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.index < b.index
        }
    }

    /// One core's share of a search: its matches and its best `limit` of them, best first.
    private struct Chunk {
        var matched: [Int] = []
        var top: [Scored] = []

        mutating func offer(_ scored: Scored, limit: Int) {
            if top.count == limit {
                guard let worst = top.last, Scored.ranksBefore(scored, worst) else { return }
                top.removeLast()
            }
            var low = 0, high = top.count
            while low < high {
                let mid = (low + high) / 2
                if Scored.ranksBefore(top[mid], scored) { low = mid + 1 } else { high = mid }
            }
            top.insert(scored, at: low)
        }
    }

    /// Scores every term without allocating; `positions` receives each term's matched offsets when given.
    private static func score(
        _ query: Query, _ candidate: Candidate, skip: Int, scratch: inout [Int], positions: (([Int]) -> Void)?
    ) -> Int? {
        var total = 0
        for term in query.terms {
            // A term that fits inside the filename beats one spread over the directories.
            if candidate.nameStart > skip, align(term, candidate.chars, from: candidate.nameStart, into: &scratch) {
                total += score(scratch, term.count, candidate.chars) + filenameBonus
            } else if align(term, candidate.chars, from: skip, into: &scratch) {
                total += score(scratch, term.count, candidate.chars)
                    + (scratch[0] >= candidate.nameStart ? filenameBonus : 0)
            } else {
                return nil
            }
            positions?(Array(scratch[0..<term.count]))
        }
        return total
    }

    /// fzf's v1 alignment: scan forward to the first place the term ends, then back to the latest start before it,
    /// which gives the shortest window ending there. Writes the positions into `positions[0..<term.count]`.
    private static func align(_ term: [UInt16], _ chars: [UInt16], from start: Int, into positions: inout [Int]) -> Bool {
        guard !term.isEmpty, start < chars.count else { return false }
        var j = 0
        var end = -1
        for i in start..<chars.count where fold(chars[i]) == term[j] {
            j += 1
            if j == term.count {
                end = i
                break
            }
        }
        guard end >= 0 else { return false }
        j = term.count - 1
        var i = end
        while j >= 0 {
            if fold(chars[i]) == term[j] {
                positions[j] = i
                j -= 1
            }
            i -= 1
        }
        return true
    }

    private static func score(_ positions: [Int], _ count: Int, _ chars: [UInt16]) -> Int {
        var score = 0
        var previous = -2
        var runBonus = 0
        for position in positions[0..<count] {
            let bonus = self.bonus(at: position, chars)
            if position == previous + 1 {
                // A run keeps the bonus of the word start it began on, like fzf.
                runBonus = max(runBonus, bonus)
                score += matchScore + max(bonus, runBonus, consecutiveBonus)
            } else {
                if previous >= 0 {
                    score -= gapStartPenalty + gapExtensionPenalty * (position - previous - 2)
                }
                runBonus = bonus
                score += matchScore + bonus
            }
            previous = position
        }
        return score
    }

    private static func bonus(at position: Int, _ chars: [UInt16]) -> Int {
        guard position > 0 else { return boundaryBonus }
        let before = chars[position - 1], current = chars[position]
        if before == slash { return boundaryBonus }
        if delimiters.contains(before) { return delimiterBonus }
        if isLower(before), isUpper(current) { return camelBonus }
        return 0
    }

    private static func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    private static func isLower(_ c: UInt16) -> Bool { c >= 97 && c <= 122 }

    /// ASCII-only case folding: cheap, and keeps one UTF-16 unit per character so positions stay valid.
    static func fold(_ c: UInt16) -> UInt16 { isUpper(c) ? c + 32 : c }
}
