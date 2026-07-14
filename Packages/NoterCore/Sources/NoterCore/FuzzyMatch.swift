import Foundation

public enum FuzzyMatch {
    /// Indices of matching candidates, best first. Empty query matches all
    /// in original order. Scoring favors prefix matches, then contiguity.
    public static func rank(query: String, candidates: [String]) -> [Int] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(candidates.indices) }
        var scored: [(index: Int, score: Int)] = []
        for (i, candidate) in candidates.enumerated() {
            guard let score = score(query: q, candidate: candidate.lowercased()) else { continue }
            scored.append((i, score))
        }
        return scored.sorted { $0.score > $1.score }.map(\.index)
    }

    /// nil = no subsequence match. Higher is better.
    private static func score(query: String, candidate: String) -> Int? {
        var score = 0
        var previousMatchIndex: String.Index? = nil
        var searchFrom = candidate.startIndex
        for ch in query {
            guard let found = candidate[searchFrom...].firstIndex(of: ch) else { return nil }
            if let prev = previousMatchIndex, candidate.index(after: prev) == found {
                score += 3                    // contiguous run
            } else {
                score += 1
            }
            previousMatchIndex = found
            searchFrom = candidate.index(after: found)
        }
        if candidate.hasPrefix(query) { score += 100 }
        return score
    }
}
