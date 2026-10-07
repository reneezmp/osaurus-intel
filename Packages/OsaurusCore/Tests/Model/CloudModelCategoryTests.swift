//  Intel: upstream's media-model cases need media generation
//  (`W-media-generation`) and are left out.

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct CloudModelCategoryTests {
    private let providerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    private func chat(_ name: String, vision: Bool = false, context: Int? = nil) -> ModelPickerItem {
        ModelPickerItem(
            id: name, displayName: name,
            source: .remote(providerName: "Osaurus Cloud", providerId: providerID),
            isVLM: vision, contextLength: context
        )
    }

    @Test func visionChatSupportsBothTextAndImageInputTasks() {
        let model = chat("Multimodal", vision: true)
        #expect(CloudModelCategory.textToText.includes(model))
        #expect(CloudModelCategory.imageToText.includes(model))
        #expect(!CloudModelCategory.image.includes(model))
        #expect(!CloudModelCategory.imageToText.includes(chat("Text only")))
    }

    @Test func categoryChoicesReflectTheCatalogAndRetainAllForEmptyCatalogs() {
        #expect(CloudModelCategory.available(in: []) == [.all])
        // Intel: no media models, so image/video categories never appear.
        #expect(CloudModelCategory.available(in: [chat("Vision", vision: true)])
            == [.all, .textToText, .imageToText])
    }

    @Test func categoryCombinesWithSearchAndContextWithoutChangingOrder() {
        let short = chat("Atlas small", vision: true, context: 32_000)
        let long = chat("Atlas large", vision: true, context: 128_000)
        let other = chat("Other", vision: true, context: 256_000)
        let items = [short, long, other]
        let result = items
            .filter { $0.matches(searchQuery: "Atlas") }
            .filteredByContext(.min128K)
            .filter(CloudModelCategory.imageToText.includes)
        #expect(result == [long])
        #expect(items.filter(CloudModelCategory.all.includes) == items)
    }

    @Test func modelNamesDoNotInventImageInputCapability() {
        let text = chat("Vision Image-to-text")
        #expect(!CloudModelCategory.imageToText.includes(text))
        #expect(CloudModelCategory.available(in: [text]) == [.all, .textToText])
    }
}
