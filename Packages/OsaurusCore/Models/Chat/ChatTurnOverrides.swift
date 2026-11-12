import Foundation

/// One composer submission. Nil fields inherit; zero and false are explicit values.
/// Never written into agent, model-option, or server-default stores.
///
/// Port of upstream Classic's `ChatTurnOverrides` (#3226) without
/// `templateKwargs` (a local-MLX chat-template control, Incompatible on Intel).
/// Upstream's Next-turn composer button that produced these was removed again
/// by #3232, so on Intel the type is the shared validator for agent defaults
/// and the carrier a future composer control would fill.
public struct ChatTurnOverrides: Codable, Equatable, Sendable {
    public var temperature: Float? = nil
    public var topP: Float? = nil
    public var topK: Int? = nil
    public var reasoningEffort: String? = nil
    public var enableThinking: Bool? = nil

    public init(
        temperature: Float? = nil, topP: Float? = nil, topK: Int? = nil,
        reasoningEffort: String? = nil, enableThinking: Bool? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.reasoningEffort = reasoningEffort
        self.enableThinking = enableThinking
    }

    var isEmpty: Bool {
        temperature == nil && topP == nil && topK == nil && reasoningEffort == nil
            && enableThinking == nil
    }

    enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    func validate() throws {
        if let temperature, !temperature.isFinite || temperature < 0 {
            throw ValidationError.invalid("Temperature must be a finite, nonnegative number.")
        }
        if let topP, !topP.isFinite || !(0...1).contains(topP) {
            throw ValidationError.invalid("Top P must be between 0 and 1.")
        }
        if let topK, topK < 0 {
            throw ValidationError.invalid("Top K must be a nonnegative integer; 0 disables it.")
        }
        if let reasoningEffort, reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.invalid("Clear reasoning effort to inherit the model default.")
        }
    }
}
