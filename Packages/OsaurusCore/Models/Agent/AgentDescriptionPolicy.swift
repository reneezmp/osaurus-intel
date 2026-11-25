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

import CryptoKit
import Foundation

public enum AgentDescriptionPolicy {
    /// Soft cap for generated summaries so a roster row stays one line. User
    /// text is never truncated.
    public static let generatedMaximumCharacters = 160

    /// Trims and collapses the text to a single line.
    /// Stable identity of the system prompt a generated description came from
    /// (upstream). A prompt edit changes the hash and invalidates the summary.
    public static func promptHash(_ systemPrompt: String) -> String {
        let data = Data(normalized(systemPrompt).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .newlines) != nil else { return trimmed }
        return trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A JSON string literal for `text`, so user-written names and purposes
    /// reach a model as quoted data (delimiters and control characters
    /// escaped), never as prompt structure.
    /// Upstream's `routingJSON` (W-subagents stage 3): one agent as a JSON
    /// object `{id, name, description?}` with user text quoted as data. Names
    /// and descriptions never change authorization or execution policy.
    public static func routingJSON(id: String, name: String, description: String) -> String {
        var object: [String: String] = ["id": id, "name": name]
        let text = normalized(description)
        if !text.isEmpty { object["description"] = text }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"id\":\"\(id)\",\"name\":\"\(name)\"}" }
        return json
    }

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
