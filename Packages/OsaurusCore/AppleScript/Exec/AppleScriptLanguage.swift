//
//  AppleScriptLanguage.swift
//  osaurus
//
//  Upstream enum from AppleScript/Model/AppleScriptAction.swift, the only
//  piece AppleScriptExecutor needs for the Intel Apple app tools.
//

import Foundation

public enum AppleScriptLanguage: String, Sendable, Equatable, CaseIterable {
    case appleScript = "applescript"
    case javascript = "javascript"

    /// Lenient parse of the model-provided `language` string: common JXA
    /// spellings map to `.javascript`; anything else (absent, blank, or
    /// unrecognized) defaults to AppleScript rather than failing the call.
    public init(callValue raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "javascript", "jxa", "js", "javascript for automation":
            self = .javascript
        default:
            self = .appleScript
        }
    }

    /// The OSA component name `OSALanguage(forName:)` resolves.
    public var osaLanguageName: String {
        switch self {
        case .appleScript: return "AppleScript"
        case .javascript: return "JavaScript"
        }
    }

    /// Short human label for feed / confirm surfaces.
    public var displayLabel: String {
        switch self {
        case .appleScript: return "AppleScript"
        case .javascript: return "JXA (JavaScript)"
        }
    }
}
