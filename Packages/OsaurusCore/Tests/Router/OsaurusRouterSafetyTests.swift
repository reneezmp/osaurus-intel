import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Router safety contract", .serialized)
struct OsaurusRouterSafetyTests {
    @Test("Router defaults on but preserves an explicit opt-out")
    func routerPreference() throws {
        let suiteName = "ai.osaurus.tests.router.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(OsaurusRouter.isEnabled(in: defaults))
        OsaurusRouter.setEnabled(false, in: defaults)
        #expect(!OsaurusRouter.isEnabled(in: defaults))
        OsaurusRouter.setEnabled(true, in: defaults)
        #expect(OsaurusRouter.isEnabled(in: defaults))
    }

    @Test("Top-up parser accepts ordinary amounts and rejects unsafe input")
    func topUpParsing() {
        #expect(OsaurusRouter.parseMicroUSD("5") == 5_000_000)
        #expect(OsaurusRouter.parseMicroUSD("$20.25") == 20_250_000)
        #expect(OsaurusRouter.parseMicroUSD("0") == nil)
        #expect(OsaurusRouter.parseMicroUSD("-1") == nil)
        #expect(OsaurusRouter.parseMicroUSD("nan") == nil)
        #expect(OsaurusRouter.parseMicroUSD("1e100") == nil)
    }
}
