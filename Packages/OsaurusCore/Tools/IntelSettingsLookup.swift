//
//  IntelSettingsLookup.swift
//  OsaurusCore
//
//  Grounded Settings lookup (upstream #49), formerly a `find_setting`
//  operation on `orchestrator_config`. The stage 4 swap to `osaurus_config`
//  keeps the lookup as `osaurus_help` action `find` only.
//

#if OSAURUS_INTEL

import Foundation

enum IntelSettingsLookup {
    /// Words a user (or the model relaying the user) wraps around a setting
    /// name that never appear in a catalog title or keyword: intent verbs,
    /// on/off state, and filler. Stripped only for the second, relaxed pass
    /// (upstream #2936).
    static let findIntentWords: Set<String> = [
        "turn", "on", "off", "the", "a", "an", "my", "setting", "settings", "option",
        "toggle", "switch", "where", "is", "are", "how", "to", "do", "i", "change",
        "set", "find", "for", "in", "of", "can", "you", "please", "enable", "disable",
        "enabled", "disabled", "stop", "start", "make", "it", "me", "up", "get",
    ]

    /// The index matcher needs every query token inside one title, section or
    /// keyword, so "turn off memory" misses the Enable Memory row. When the
    /// strict pass is empty, retry without intent/state words and report the
    /// query that matched. The Settings search field is unchanged: it matches
    /// what the user typed.
    static func findSettings(_ query: String) -> (entries: [SettingsSearchEntry], relaxedQuery: String?) {
        let strict = SettingsSearchIndex.search(query)
        if !strict.isEmpty { return (strict, nil) }
        let kept = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !findIntentWords.contains($0) }
        guard !kept.isEmpty else { return ([], nil) }
        let relaxed = kept.joined(separator: " ")
        guard relaxed != query.lowercased() else { return ([], nil) }
        let hits = SettingsSearchIndex.search(relaxed)
        return (hits, hits.isEmpty ? nil : relaxed)
    }
}

#endif
