import Testing

@testable import OsaurusCore

@Suite("Intel Router credit formatting")
struct OsaurusRouterCreditsFormattingTests {
    @Test func wholeAndResidualCredits() {
        #expect(OsaurusRouter.formatMicroAsCredits("7250000") == "72,500 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("7250037") == "72,500.37 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("100") == "1 credit")
        #expect(OsaurusRouter.formatMicroAsCredits("99") == "<1 credit")
        #expect(OsaurusRouter.formatMicroAsCredits("-99") == "-<1 credit")
        #expect(OsaurusRouter.formatMicroAsCredits("garbage") == "0 credits")
    }

    @Test func heroAndCompactValues() {
        #expect(OsaurusRouter.formatMicroAsCreditsValue("21208579") == "212,085")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("1000000") == "10K credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("21208579") == "212.1K credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("125000000") == "1.25M credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("99995000") == "1M credits")
    }

    @Test func topUpStillUsesDollars() {
        #expect(OsaurusRouter.formatMicroUSD("5000000") == "$5.00")
        #expect(OsaurusRouter.parseMicroUSD("$5") == 5_000_000)
    }
}
