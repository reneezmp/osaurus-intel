import Testing

@testable import OsaurusCore

@Suite("Intel DeepSeek hosted model aliases")
struct IntelDeepSeekHostedModelTests {
    @Test("Versionless Flash keeps the DSV4 reasoning profile")
    func deepSeekFlashUsesDSV4Profile() {
        for id in [
            "deepseek-flash",
            "deepseek/deepseek-flash",
            "DeepSeek-V4.1-Flash",
            "deepseek-v4-pro",
        ] {
            #expect(ModelFamilyNames.isDSV4Family(id), "expected DSV4 family for \(id)")
            #expect(
                ModelProfileRegistry.profile(for: id)?.displayName
                    == DSV4ReasoningProfile.displayName
            )
        }

        #expect(!ModelFamilyNames.isDSV4Family("deepseek-chat"))
        #expect(!ModelFamilyNames.isDSV4Family("deepseek-v3"))
    }

    @Test("DeepSeek preset advertises the current hosted API slugs")
    func deepSeekPresetUsesCurrentSlugs() {
        #expect(ProviderPreset.deepseek.description == "deepseek-flash / deepseek-v4-pro")
    }
}
