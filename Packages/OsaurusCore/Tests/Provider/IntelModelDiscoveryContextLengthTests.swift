//
//  IntelModelDiscoveryContextLengthTests.swift
//  osaurusTests
//
//  Intel: upstream #3068's DeepInfra cases against Intel's own `/models`
//  discovery (`RemoteProviderManager.advertisedContextLength`), which
//  replaces upstream's `decodeOpenAICompatibleModelsDiscovery`.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelModelDiscoveryContextLengthTests {

    private func lengths(_ json: String) throws -> [String: Int] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let entries = try #require(object?["data"] as? [[String: Any]])
        var result: [String: Int] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            if let n = RemoteProviderManager.advertisedContextLength(in: entry) { result[id] = n }
        }
        return result
    }

    @Test func deepInfraNestedMetadataContextLength() throws {
        let found = try lengths(
            """
            {
              "object": "list",
              "data": [
                {
                  "id": "deepseek-ai/DeepSeek-V4.1-Flash",
                  "object": "model",
                  "owned_by": "deepinfra",
                  "metadata": {
                    "context_length": 1048576,
                    "max_tokens": 163840,
                    "pricing": {"input_tokens": 0.5},
                    "tags": ["chat", "reasoning"]
                  }
                },
                {"id": "top-level-wins", "context_length": 131072, "metadata": {"context_length": 8192}},
                {"id": "string-nested", "metadata": {"context_length": "163840"}},
                {"id": "null-nested", "metadata": {"context_length": null, "max_tokens": null}},
                {"id": "zero-nested", "metadata": {"context_length": 0}},
                {"id": "max-tokens-only", "metadata": {"max_tokens": 4096}}
              ]
            }
            """)
        #expect(
            found == [
                "deepseek-ai/DeepSeek-V4.1-Flash": 1_048_576,
                "top-level-wins": 131072,
                "string-nested": 163840,
            ])
    }

    @Test func nonObjectMetadataMeansNoWindow() throws {
        let found = try lengths(
            """
            {
              "data": [
                {"id": "null-metadata", "metadata": null},
                {"id": "string-metadata", "metadata": "chat"},
                {"id": "array-metadata", "metadata": ["chat"]},
                {"id": "number-metadata", "metadata": 7},
                {"id": "empty-metadata", "metadata": {}},
                {"id": "metadata-beside-window", "metadata": "chat", "max_model_len": 32768}
              ]
            }
            """)
        #expect(found == ["metadata-beside-window": 32768])
    }

    @Test func gatewayContextWindowAndEarlierKeysKeepPrecedence() throws {
        let found = try lengths(
            """
            {
              "data": [
                {"id": "gateway", "context_window": 200000},
                {"id": "vllm-first", "max_model_len": 32768, "context_window": 65536},
                {"id": "llama-cpp", "max_context_length": 8192, "metadata": {"context_length": 4096}}
              ]
            }
            """)
        #expect(found == ["gateway": 200_000, "vllm-first": 32768, "llama-cpp": 8192])
    }
}
