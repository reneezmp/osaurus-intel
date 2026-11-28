//
//  IntelImageTool.swift
//  osaurus
//
//  Intel's `image` tool (`W-media-generation`). Upstream's `ImageTool`
//  (NativeImageTools.swift) generates or edits with local MLX bundles and
//  with cloud models through `ImageSubagentKind`; Intel runs the cloud
//  branch of that kind (`Subagent/Kinds/ImageSubagentKind.swift`, stage 6
//  of W-subagents), so this tool generates (no editing: remote editing is not
//  supported upstream either) with the agent's Osaurus Cloud or Venice image
//  model. Upstream's generation-only schema minus the local controls
//  (sampler, adapters, batches, previews), which upstream rejects for remote
//  models anyway.
//

import Foundation

final class ImageTool: OsaurusTool, @unchecked Sendable {
    let name = "image"

    static let toolDescription =
        "Create an image with the user's configured image model: call with a `prompt`. The result is "
        + "shown to the user automatically; do NOT call share_artifact on it."

    var description: String { Self.toolDescription }
    var bypassRegistryTimeout: Bool { true }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "prompt": .object([
                "type": .string("string"),
                "description": .string("What to create."),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional configured image model id. Omit to use the default."),
            ]),
            "negative_prompt": .object([
                "type": .string("string"),
                "description": .string("Optional negative prompt."),
            ]),
            "width": .object(["type": .string("integer"), "description": .string("Optional width in pixels.")]),
            "height": .object(["type": .string("integer"), "description": .string("Optional height in pixels.")]),
            "steps": .object(["type": .string("integer"), "description": .string("Optional denoise step count.")]),
            "guidance": .object(["type": .string("number"), "description": .string("Optional guidance scale.")]),
            "seed": .object(["type": .string("integer"), "description": .string("Optional deterministic seed.")]),
        ]),
        "required": .array([.string("prompt")]),
    ])

    init() {}

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let promptReq = requireString(args, "prompt", expected: "non-empty image prompt", tool: name)
        guard case .value(let prompt) = promptReq else { return promptReq.failureEnvelope ?? "" }

        // The switch, model, billing approval and the coordinator call run in
        // `ImageSubagentKind` on the shared subagent host (W-subagents stage 6).
        let params = ImageJobParams(
            prompt: prompt,
            model: IntelMediaToolSupport.optionalString(args["model"]),
            negativePrompt: IntelMediaToolSupport.optionalString(args["negative_prompt"]),
            width: ArgumentCoercion.int(args["width"]),
            height: ArgumentCoercion.int(args["height"]),
            steps: ArgumentCoercion.int(args["steps"]),
            guidance: IntelMediaToolSupport.optionalDouble(args["guidance"]),
            seed: ArgumentCoercion.int(args["seed"])
        )
        return await SubagentSession.run(
            ImageSubagentKind(params: params, argumentsJSON: argumentsJSON), tool: name)
    }
}
