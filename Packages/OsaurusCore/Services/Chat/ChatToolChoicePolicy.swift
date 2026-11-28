//
//  ChatToolChoicePolicy.swift
//

import Foundation

enum ChatToolChoicePolicy {
    static func resolve(
        tools: [Tool],
        userText: String,
        attempt: Int
    ) -> ToolChoiceOption? {
        guard !tools.isEmpty else { return nil }
        guard attempt == 1 else { return .auto }

        // Deterministic redaction routing (upstream #2474): prose steering alone
        // does not reliably move small models off the read-then-script reflex
        // (observed live upstream: a 9B model ignored `redact_file` twice and
        // hand-rolled a catastrophic name regex). When the request pairs a
        // redaction verb with a PII noun and `redact_file` is offered, force it
        // for the first call; the loop returns to `.auto` on the next attempt.
        // `redact_file` is offered only to an agent with Redaction Tools on.
        if containsRedactionIntent(text: userText.lowercased()),
            !containsNegatedToolIntent(userText.lowercased()),
            tools.contains(where: { $0.function.name == "redact_file" })
        {
            return .function(
                .init(type: "function", function: .init(name: "redact_file"))
            )
        }

        return requiresToolCall(tools: tools, userText: userText) ? .required : .auto
    }

    /// A redaction-shaped request, two-tier to keep false positives from
    /// mutating files (a forced `redact_file` WRITES on a wrong guess; upstream
    /// observed "replace the column names ... with lowercase" forcing the tool):
    ///  - strong verbs (redact / mask / anonymize / scrub) pair with any
    ///    PII noun,
    ///  - weak verbs (replace / remove) need an unambiguous PII noun, or
    ///    an ambiguous one ("names", "addresses": also everyday
    ///    code/data vocabulary) PLUS an explicit redaction signal such as
    ///    a "[redacted..." placeholder or the word "placeholder".
    static func containsRedactionIntent(text: String) -> Bool {
        let strongVerbs = ["redact", "mask", "anonymize", "anonymise", "scrub"]
        let weakVerbs = ["replace", "remove"]
        let strongNouns = [
            "emails", "e-mails", "email address", "email addresses", "phone number",
            "phone numbers", "pii", "personal information", "personal info", "personal data",
            "account number", "account numbers", "sensitive data", "sensitive information",
            "sensitive values",
        ]
        let ambiguousNouns = ["names", "addresses"]
        let redactionSignals = ["[redacted", "placeholder"]

        let hasStrongNoun = strongNouns.contains(where: { text.contains($0) })
        let hasAmbiguousNoun = ambiguousNouns.contains(where: { text.contains($0) })
        guard hasStrongNoun || hasAmbiguousNoun else { return false }

        if strongVerbs.contains(where: { text.contains($0) }) {
            return true
        }
        guard weakVerbs.contains(where: { text.contains($0) }) else { return false }
        if hasStrongNoun { return true }
        return redactionSignals.contains(where: { text.contains($0) })
    }

    private static func requiresToolCall(tools: [Tool], userText: String) -> Bool {
        let text = userText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !containsNegatedToolIntent(text) else { return false }

        let names = Set(tools.map { $0.function.name.lowercased() })
        if names.contains(where: { containsCallableName($0, in: text) }) {
            return true
        }

        guard names.contains(where: isFileLikeToolName) else { return false }
        return containsGenericFileToolIntent(text)
    }

    private static func containsCallableName(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        return text.contains(name)
    }

    private static func containsNegatedToolIntent(_ text: String) -> Bool {
        [
            "do not use",
            "don't use",
            "dont use",
            "without using",
            "no tool",
            "no tools",
            "do not call",
            "don't call",
            "dont call",
            "without calling",
            "do not run",
            "don't run",
            "dont run",
            "without running",
            "do not invoke",
            "don't invoke",
            "dont invoke",
            "without invoking",
        ].contains { text.contains($0) }
    }

    private static func isFileLikeToolName(_ name: String) -> Bool {
        [
            "file_read",
            "file_tree",
            "file_write",
            "file_edit",
            "file_search",
            "sandbox_read_file",
            "sandbox_write_file",
            "sandbox_edit_file",
            "sandbox_search_files",
        ].contains(name)
    }

    private static func containsGenericFileToolIntent(_ text: String) -> Bool {
        let directPhrases = [
            "available file tool",
            "using the available file tool",
            "use the available file tool",
            "call the file tool",
            "use the file tool",
            "invoke the file tool",
            "read the file",
            "read file",
            "open the file",
            "inspect the file",
            "look at the file",
            "look at files",
            "look at the files",
            "list files",
            "list the files",
        ]
        if directPhrases.contains(where: { text.contains($0) }) {
            return true
        }

        let hasFileTarget =
            text.contains(".swift")
            || text.contains(".py")
            || text.contains(".json")
            || text.contains(".md")
            || text.contains(".txt")
            || containsPathLikeTarget(text)

        let hasFileAction =
            text.contains(" read ")
            || text.hasPrefix("read ")
            || text.contains(" open ")
            || text.hasPrefix("open ")
            || text.contains(" inspect ")
            || text.hasPrefix("inspect ")
            || text.contains(" search ")
            || text.hasPrefix("search ")

        return hasFileTarget && hasFileAction
    }

    private static func containsPathLikeTarget(_ text: String) -> Bool {
        text.range(
            of: #"(^|\s)(~?/|\.{1,2}/|/[^\s]+)"#,
            options: .regularExpression
        ) != nil
    }
}
