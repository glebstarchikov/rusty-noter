import Testing
@testable import NoterCore

@Suite struct FuzzyMatchTests {
    let titles = ["API pricing ideas", "Standup with Anna", "Pricing page copy", "Groceries"]

    @Test func subsequenceMatches() {
        let ranked = FuzzyMatch.rank(query: "prici", candidates: titles)
        #expect(ranked.count == 2)
        #expect(Set(ranked) == [0, 2])
    }

    @Test func prefixBeatsMidwordMatch() {
        let ranked = FuzzyMatch.rank(query: "pricing", candidates: titles)
        // "Pricing page copy" starts with the query; it must outrank "API pricing ideas".
        #expect(ranked.first == 2)
    }

    @Test func caseInsensitive() {
        #expect(FuzzyMatch.rank(query: "STANDUP", candidates: titles) == [1])
    }

    @Test func nonMatchingAndEmpty() {
        #expect(FuzzyMatch.rank(query: "zzz", candidates: titles) == [])
        #expect(FuzzyMatch.rank(query: "", candidates: titles) == [0, 1, 2, 3])
    }

    @Test func scatteredSubsequenceStillMatches() {
        #expect(FuzzyMatch.rank(query: "swa", candidates: titles).contains(1)) // Standup With Anna
    }
}
