//
//  AgentDescriptionPolicy.swift
//  osaurus
//
//  Shared helpers for the optional agent description (upstream #157/#158,
//  current upstream/main shape). A description is free text: it is never
//  required, never blocks a save, and never gates delegation. These helpers
//  only normalize it for display/routing and quote it as data when it
//  reaches a model.
//

import Foundation

public enum AgentDescriptionPolicy {
    /// Soft cap for generated summaries so a roster row stays one line. User
    /// text is never truncated.
    public static let generatedMaximumCharacters = 160

    /// Trims and collapses the text to a single line.
    public static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isNewline }) else { return trimmed }
        return trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A JSON string literal for `text`, so user-written names and purposes
    /// reach a model as quoted data (delimiters and control characters
    /// escaped), never as prompt structure.
    public static func quoted(_ text: String) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: [normalized(text)], options: [.withoutEscapingSlashes]),
            let array = String(data: data, encoding: .utf8),
            array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
