//
//  CloudModelCategory.swift
//  osaurus
//
//  Catalog-backed tasks for the Cloud browser. A model can support more than
//  one task, so vision chat models belong to both text and image input groups.
//
//  Intel: no media-generation models yet (`W-media-generation`), so the image
//  and video categories never match and `available(in:)` hides them.
//

import Foundation

enum CloudModelCategory: CaseIterable, Identifiable, Hashable {
    case all
    case textToText
    case imageToText
    case image
    case textToVideo
    case imageToVideo

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All"
        case .textToText: return "Text-to-text"
        case .imageToText: return "Image-to-text"
        case .image: return "Image"
        case .textToVideo: return "Text-to-video"
        case .imageToVideo: return "Image-to-video"
        }
    }

    func includes(_ model: ModelPickerItem) -> Bool {
        switch self {
        case .all:
            return true
        case .textToText:
            return model.isLikelyChatCapable
        case .imageToText:
            return model.isLikelyChatCapable && model.isVLM
        case .image:
            // Cloud image metadata does not distinguish generation from
            // editing. Keep its broad category instead of guessing by name.
            return false  // Intel: no media models
        case .textToVideo:
            return false
        case .imageToVideo:
            return false  // Intel: no media modelsToVideo
        }
    }

    /// The row shows the most specific task; multimodal chat remains available
    /// through both input categories when filtering.
    static func displayCategory(for model: ModelPickerItem) -> Self? {
        guard model.isLikelyChatCapable else { return nil }
        return model.isVLM ? .imageToText : .textToText
    }

    static func available(in models: [ModelPickerItem]) -> [Self] {
        allCases.filter { category in
            category == .all || models.contains(where: category.includes)
        }
    }
}
