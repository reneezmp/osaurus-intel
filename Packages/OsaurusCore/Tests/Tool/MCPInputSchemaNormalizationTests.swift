//
//  MCPInputSchemaNormalizationTests.swift
//  osaurusTests
//
//  MCP no-arg tools may advertise `{"type":"object"}` without `properties`.
//  OpenAI-style validators reject that, so ingest and wire encoding fill in
//  `properties: {}` while leaving every other schema untouched.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

struct MCPInputSchemaNormalizationTests {

    @Test func missingPropertiesIsFilledAtIngest() {
        let schema: MCP.Value = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ])
        let converted = MCPProviderTool.convertInputSchema(schema)
        #expect(
            converted
                == .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([:]),
                ])
        )
    }

    @Test func nilSchemaFallbackIncludesProperties() {
        let converted = MCPProviderTool.convertInputSchema(nil)
        #expect(converted == .object(["type": .string("object"), "properties": .object([:])]))
    }

    @Test func existingPropertiesAreUnchanged() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["q": .object(["type": .string("string")])]),
        ])
        #expect(schema.withEmptyPropertiesIfMissing == schema)
    }

    @Test func nonObjectSchemaIsUnchanged() {
        let schema: JSONValue = .object(["type": .string("string")])
        #expect(schema.withEmptyPropertiesIfMissing == schema)
    }

    /// Intel sends tool specs through `ChatEngine.encodeTools` (the
    /// upstream `ToolFunction` wire encoder is excluded from this target).
    @Test func wireEncodingFillsMissingProperties() throws {
        let tool = OsaurusCore.Tool(
            function: ToolFunction(
                name: "get_accounts",
                parameters: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                ])
            )
        )
        let specs = try #require(ChatEngine.encodeTools([tool]))
        let function = try #require(specs.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect((parameters["properties"] as? [String: Any])?.isEmpty == true)
        #expect(parameters["additionalProperties"] as? Bool == false)
    }

    @Test func wireEncodingSuppliesSchemaWhenParametersAreMissing() throws {
        let specs = try #require(ChatEngine.encodeTools([OsaurusCore.Tool(function: ToolFunction(name: "ping"))]))
        let function = try #require(specs.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect((parameters["properties"] as? [String: Any])?.isEmpty == true)
    }
}
