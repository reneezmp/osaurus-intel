import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct IntelCodexResponsesAdapterTests {
    @Test func convertsConversationToolsAndToolResultsWithoutDroppingContext() throws {
        let request: [String: Any] = [
            "model": "gpt-5.6-codex",
            "stream": true,
            "max_tokens": 1200,
            "reasoning_effort": "medium",
            "messages": [
                ["role": "system", "content": "Be concise."],
                ["role": "user", "content": "Find the file."],
                ["role": "assistant", "tool_calls": [[
                    "id": "call_1", "type": "function",
                    "function": ["name": "files.find", "arguments": "{\"name\":\"x\"}"],
                ]]],
                ["role": "tool", "tool_call_id": "call_1", "content": "x.swift"],
            ],
            "tools": [[
                "type": "function",
                "function": ["name": "files.find", "description": "Find a file", "parameters": ["type": "object"]],
            ]],
            "tool_choice": ["type": "function", "function": ["name": "files.find"]],
        ]

        let payload = try IntelCodexResponsesAdapter.makeRequest(chatCompletions: request)
        #expect(payload["model"] as? String == "gpt-5.6-codex")
        #expect(payload["instructions"] as? String == "Be concise.")
        #expect(payload["max_output_tokens"] == nil)
        #expect(payload["store"] as? Bool == false)
        #expect(payload["include"] as? [String] == ["reasoning.encrypted_content"])
        #expect((payload["reasoning"] as? [String: Any])?["summary"] as? String == "auto")
        #expect((payload["reasoning"] as? [String: Any])?["context"] as? String == "all_turns")
        let input = try #require(payload["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["message", "function_call", "function_call_output"])
        #expect((input[1]["call_id"] as? String) == "call_1")
        #expect((payload["tools"] as? [[String: Any]])?.first?["name"] as? String == "files.find")
        #expect((payload["tool_choice"] as? [String: Any])?["name"] as? String == "files.find")
    }

    @Test func rejectsInputsThatWouldOtherwiseBeSilentlyChanged() {
        let unsupported: [String: Any] = ["model": "gpt", "messages": [], "temperature": 0.2]
        #expect(throws: IntelCodexResponsesAdapter.Error.unsupportedInput("field \"temperature\"") ) {
            try IntelCodexResponsesAdapter.makeRequest(chatCompletions: unsupported)
        }
        let reasoning: [String: Any] = [
            "model": "gpt", "messages": [["role": "assistant", "content": "x", "reasoning_content": "plain chain"]],
        ]
        #expect(throws: IntelCodexResponsesAdapter.Error.unsupportedInput("messages[0].reasoning_content; replay completed Responses output items instead")) {
            try IntelCodexResponsesAdapter.makeRequest(chatCompletions: reasoning)
        }
    }

    @Test func responsesLiteMovesToolsAndInstructionsIntoInputItems() throws {
        let payload = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: [
                "model": "gpt-5.6-luna",
                "stream": true,
                "messages": [
                    ["role": "system", "content": "Be exact."],
                    ["role": "user", "content": "Hello"],
                ],
                "tools": [[
                    "type": "function",
                    "function": ["name": "list_knowledge", "parameters": ["type": "object"]],
                ]],
            ],
            responsesLiteSessionId: "0198f2ab-7b38-7a11-88ba-123456789abc"
        )

        #expect(payload["tools"] == nil)
        #expect(payload["instructions"] == nil)
        #expect(payload["tool_choice"] as? String == "auto")
        #expect(payload["parallel_tool_calls"] as? Bool == false)
        #expect(payload["prompt_cache_key"] as? String == "0198f2ab-7b38-7a11-88ba-123456789abc")
        #expect((payload["reasoning"] as? [String: Any])?["context"] as? String == "all_turns")
        let input = try #require(payload["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["additional_tools", "message", "message"])
        #expect(input[0]["role"] as? String == "developer")
        #expect(input[1]["role"] as? String == "developer")
        #expect(input[2]["role"] as? String == "user")
        // Upstream shape (#2562 / #2565): namespace-wrapped, type-tagged tools,
        // stable ids, base-instructions metadata, turn metadata.
        let tools = try #require(input[0]["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "namespace")
        #expect(tools[0]["name"] as? String == "functions")
        let nested = try #require(tools[0]["tools"] as? [[String: Any]])
        #expect(nested.first?["type"] as? String == "function")
        #expect(nested.first?["name"] as? String == "list_knowledge")
        #expect((input[0]["id"] as? String)?.hasPrefix("at_") == true)
        #expect((input[1]["id"] as? String)?.hasPrefix("msg_") == true)
        #expect(
            (input[1]["internal_chat_message_metadata_passthrough"] as? [String: Any])?["content_item_kinds"] as? [String]
                == ["model.base_instructions"])
        let metadata = try #require((payload["client_metadata"] as? [String: Any])?["x-codex-turn-metadata"] as? String)
        let turn = try #require(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: String])
        #expect(turn == ["session_id": "0198f2ab-7b38-7a11-88ba-123456789abc",
                         "thread_id": "0198f2ab-7b38-7a11-88ba-123456789abc", "request_kind": "turn"])
    }

    @Test func liteIdsAreStableAndImageDetailIsStripped() throws {
        let body: [String: Any] = [
            "model": "gpt-5.6-luna",
            "messages": [
                ["role": "system", "content": "Be exact."],
                ["role": "user", "content": [
                    ["type": "text", "text": "look"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA==", "detail": "high"]],
                ]],
            ],
            "tools": [["type": "function", "function": ["name": "t", "parameters": ["type": "object"]]]],
        ]
        let a = try IntelCodexResponsesAdapter.makeRequest(chatCompletions: body, responsesLiteSessionId: "s1")
        let b = try IntelCodexResponsesAdapter.makeRequest(chatCompletions: body, responsesLiteSessionId: "s1")
        let ida = (a["input"] as? [[String: Any]])?.map { $0["id"] as? String }
        let idb = (b["input"] as? [[String: Any]])?.map { $0["id"] as? String }
        #expect(ida == idb)
        let other = try IntelCodexResponsesAdapter.makeRequest(chatCompletions: body, responsesLiteSessionId: "s2")
        let otherFirst = (other["input"] as? [[String: Any]])?.first?["id"] as? String
        #expect(otherFirst != nil && otherFirst != ida?.first ?? nil)
        let image = ((a["input"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.last
        #expect(image?["type"] as? String == "input_image")
        #expect(image?["detail"] == nil)
        #expect(image?["image_url"] as? String == "data:image/png;base64,AA==")
    }

    @Test func nonLiteCodexCarriesSessionCacheKeyAndMetadataButKeepsTopLevelTools() throws {
        let payload = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: [
                "model": "gpt-5.5", "max_tokens": 100,
                "messages": [["role": "user", "content": "Hi"]],
                "tools": [["type": "function", "function": ["name": "t", "parameters": ["type": "object"]]]],
            ],
            codexSessionId: "sess-1")
        #expect(payload["prompt_cache_key"] as? String == "sess-1")
        #expect((payload["client_metadata"] as? [String: Any])?["x-codex-turn-metadata"] is String)
        #expect(payload["max_output_tokens"] == nil)
        #expect((payload["tools"] as? [[String: Any]])?.first?["type"] as? String == "function")
        #expect(payload["parallel_tool_calls"] as? Bool == true)
        let none = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: ["model": "gpt-5.5", "messages": [["role": "user", "content": "Hi"]]])
        #expect(none["prompt_cache_key"] == nil && none["client_metadata"] == nil)
        #expect(none["parallel_tool_calls"] == nil)
    }

    // MARK: Stage 5d slice 3 (rows 9, 10, 12, 13)

    @Test func strictSchemaCheckMatchesUpstream() {
        let strictSchema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["a", "b"],
            "properties": [
                "a": ["type": "string"],
                "b": ["type": "object", "additionalProperties": false, "required": ["c"],
                      "properties": ["c": ["type": "integer"]]],
            ],
        ]
        #expect(IntelCodexResponsesAdapter.isStrictResponsesToolSchema(strictSchema))
        // Missing `additionalProperties: false`, an unlisted property, a nested
        // object that is not strict, a nil / non-object root: all non-strict.
        #expect(!IntelCodexResponsesAdapter.isStrictResponsesToolSchema(["type": "object", "properties": [:]]))
        var missingRequired = strictSchema
        missingRequired["required"] = ["a"]
        #expect(!IntelCodexResponsesAdapter.isStrictResponsesToolSchema(missingRequired))
        var nested = strictSchema
        nested["properties"] = ["a": ["type": "object", "properties": ["c": ["type": "string"]]]]
        nested["required"] = ["a"]
        #expect(!IntelCodexResponsesAdapter.isStrictResponsesToolSchema(nested))
        #expect(!IntelCodexResponsesAdapter.isStrictResponsesToolSchema(nil))
        #expect(!IntelCodexResponsesAdapter.isStrictResponsesToolSchema(["type": "string"]))
        // An `anyOf` alternative that is not strict breaks it; `items` too.
        var anyOf = strictSchema
        anyOf["anyOf"] = [["type": "object", "properties": [:]]]
        #expect(!IntelCodexResponsesAdapter.isStrictResponsesToolSchema(anyOf))
        var items = strictSchema
        items["properties"] = ["a": ["type": "array", "items": ["type": "object", "properties": [:]]]]
        items["required"] = ["a"]
        #expect(!IntelCodexResponsesAdapter.isStrictResponsesToolSchema(items))
    }

    @Test func toolsCarryStrictByTheSchemaCheckAndAnExplicitOptOutWins() throws {
        let strictSchema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["a"], "properties": ["a": ["type": "string"]],
        ]
        let payload = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: [
                "model": "gpt-5.5", "messages": [["role": "user", "content": "Hi"]],
                "tools": [
                    ["type": "function", "function": ["name": "strict_one", "parameters": strictSchema]],
                    ["type": "function", "function": ["name": "loose_one", "parameters": ["type": "object", "properties": [:]]]],
                    ["type": "function", "function": ["name": "opt_out", "parameters": strictSchema, "strict": false]],
                    ["type": "function", "function": ["name": "opt_in_loose", "parameters": ["type": "object"], "strict": true]],
                ],
            ])
        let tools = try #require(payload["tools"] as? [[String: Any]])
        #expect(tools.map { $0["strict"] as? Bool } == [true, false, false, false])
    }

    @Test func openAITargetSendsLimitsSamplingJSONModeAndCacheKey() throws {
        let payload = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: [
                "model": "gpt-4.1", "max_tokens": 777, "temperature": 0.3, "top_p": 0.9,
                "response_format": ["type": "json_object"],
                "messages": [["role": "user", "content": "Hi"]],
                "tools": [["type": "function", "function": ["name": "t", "parameters": ["type": "object"]]]],
            ],
            target: .openAI, promptCacheKey: "osaurus-session-abc")
        #expect(payload["max_output_tokens"] as? Int == 777)
        #expect(payload["temperature"] as? Double == 0.3)
        #expect(payload["top_p"] as? Double == 0.9)
        #expect(((payload["text"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect(payload["prompt_cache_key"] as? String == "osaurus-session-abc")
        #expect(payload["parallel_tool_calls"] as? Bool == true)
        #expect(payload["client_metadata"] == nil)
        // No limit asked: none sent. text.format only for json_object.
        let bare = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: ["model": "gpt-4.1", "response_format": ["type": "text"],
                              "messages": [["role": "user", "content": "Hi"]]],
            target: .openAI)
        #expect(bare["max_output_tokens"] == nil && bare["text"] == nil && bare["parallel_tool_calls"] == nil)
        #expect(bare["prompt_cache_key"] == nil)
    }

    @Test func refusalEventsAndContentPartsSurfaceAsAnError() throws {
        var streamed = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        _ = try streamed.append(Data("data: {\"type\":\"response.refusal.delta\",\"delta\":\"I can't \"}\n\n".utf8))
        #expect(throws: IntelCodexResponsesAdapter.Error.refusal("I can't help")) {
            try streamed.append(Data("data: {\"type\":\"response.refusal.done\",\"refusal\":\"I can't help\"}\n\n".utf8))
        }
        #expect(IntelCodexResponsesAdapter.Error.refusal("no").errorDescription == "OpenAI refused this request: no")
        #expect(IntelCodexResponsesAdapter.Error.refusal("").errorDescription?.contains("no explanation") == true)

        var completed = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let frame = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Not allowed\"}]}]}}\n\n"
        #expect(throws: IntelCodexResponsesAdapter.Error.refusal("Not allowed")) {
            try completed.append(Data(frame.utf8))
        }
    }

    @Test func unknownEventsAndContentPartsAreIgnored() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let frames = [
            "data: {\"type\":\"response.web_search_call.searching\",\"output_index\":0}\n\n",
            "data: {\"type\":\"response.some_future_event\",\"x\":1}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"web_search_call\",\"id\":\"ws_1\"},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"},{\"type\":\"annotation_blob\"}]}]}}\n\n",
        ]
        var emissions: [String] = []
        for frame in frames { emissions += try decoder.append(Data(frame.utf8)) }
        let final = try decoder.finish()
        emissions += final.emissions
        #expect(emissions == ["ok"])
        #expect(final.completion.outputItems.count == 2)
        #expect(final.completion.toolCalls.isEmpty)
    }

    @Test func replaysAssistantTextAsOutputAndNewUserTextAsInput() throws {
        let payload = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: [
                "model": "gpt-5.6-luna",
                "messages": [
                    ["role": "user", "content": "First turn"],
                    ["role": "assistant", "content": "First answer"],
                    ["role": "user", "content": "Follow-up"],
                ],
            ]
        )
        let input = try #require(payload["input"] as? [[String: Any]])
        let types = input.map { item -> String? in
            (item["content"] as? [[String: Any]])?.first?["type"] as? String
        }
        #expect(input.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(types == ["input_text", "output_text", "input_text"])
    }

    @Test func uuidV7HasExpectedVersionAndVariant() {
        let value = ChatEngine.makeUUIDv7(
            now: Date(timeIntervalSince1970: 1_750_000_000),
            randomUUID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )
        let uuid = UUID(uuidString: value)
        #expect(uuid != nil)
        #expect(value.split(separator: "-")[2].first == "7")
        #expect(["8", "9", "a", "b"].contains(String(value.split(separator: "-")[3].first!)))
    }

    @Test func decodesPartialTextReasoningAndToolMarkersThenPreservesReplayItems() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: ["files.find"])
        let frames = [
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}\n\n",
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Inspecting\"}\n\n",
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_7\",\"name\":\"files.find\",\"arguments\":\"\"}}\n\n",
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{}\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque\"},{\"type\":\"function_call\",\"call_id\":\"call_7\",\"name\":\"files.find\",\"arguments\":\"{}\"}]}}\n\n",
        ]
        var emissions: [String] = []
        for frame in frames { emissions += try decoder.append(Data(frame.utf8)) }
        let final = try decoder.finish()
        emissions += final.emissions

        #expect(emissions[0] == "Hello")
        #expect(StreamingReasoningHint.decode(emissions[1]) == "Inspecting")
        #expect(StreamingToolHint.decode(emissions[2]) == "files.find")
        #expect(StreamingToolHint.decodeArgs(emissions[3]) == "{}")
        #expect(final.completion.toolCalls == [IntelCodexResponsesToolCall(callID: "call_7", name: "files.find", arguments: "{}")])
        let replay = try final.completion.replayInputItems(toolResults: [.init(callID: "call_7", output: "found")])
        #expect(replay.count == 3)
        #expect(replay[0]["encrypted_content"] as? String == "opaque")
        #expect(replay[2]["type"] as? String == "function_call_output")
    }

    @Test func rejectsUnknownToolAndNonCompletedTerminalsBeforeCompletionIsAvailable() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: ["safe.tool"])
        let unknown = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_x\",\"name\":\"rm.everything\",\"arguments\":\"{}\"}}\n\n"
        #expect(throws: IntelCodexResponsesAdapter.Error.unknownTool("rm.everything")) {
            try decoder.append(Data(unknown.utf8))
        }

        var failed = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let failure = "data: {\"type\":\"response.failed\",\"error\":{\"message\":\"quota\"}}\n\n"
        #expect(throws: IntelCodexResponsesAdapter.Error.terminalFailure("quota")) {
            try failed.append(Data(failure.utf8))
        }
    }

    @Test func requiresCompletedTerminalAndRejectsUnknownOutputKinds() throws {
        var noTerminal = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        _ = try noTerminal.append(Data("data: {\"type\":\"response.created\"}\n\n".utf8))
        #expect(throws: IntelCodexResponsesAdapter.Error.incompleteStream) { try noTerminal.finish() }

        // Upstream ignores event and item kinds it does not know (stage 5d row 10);
        // an unknown item is kept for replay and never executed.
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let unknown = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\"}}\n\n"
        #expect(try decoder.append(Data(unknown.utf8)).isEmpty)
    }

    @Test func emitsAuthoritativeCompletedTextWhenNoDeltaArrived() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"late text\"}]}]}}\n\n"
        let emissions = try decoder.append(Data(completed.utf8))
        let final = try decoder.finish()
        #expect(emissions + final.emissions == ["late text"])
    }

    @Test func acceptsNormalContentAndReasoningLifecycleEvents() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let frames = [
            "data: {\"type\":\"response.reasoning_summary_part.added\",\"output_index\":0,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n",
            "data: {\"type\":\"response.reasoning_summary_part.done\",\"output_index\":0,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"brief\"}}\n\n",
            "data: {\"type\":\"response.content_part.added\",\"output_index\":1,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":1,\"content_index\":0,\"delta\":\"Hello\"}\n\n",
            "data: {\"type\":\"response.output_text.done\",\"output_index\":1,\"content_index\":0,\"text\":\"Hello\"}\n\n",
            "data: {\"type\":\"response.content_part.done\",\"output_index\":1,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"Hello\"}}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"summary\":[]},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}]}}\n\n",
        ]
        var emissions: [String] = []
        for frame in frames { emissions += try decoder.append(Data(frame.utf8)) }
        emissions += try decoder.finish().emissions
        #expect(emissions == ["Hello"])
    }
}
