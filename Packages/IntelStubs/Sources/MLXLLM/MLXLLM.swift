import Foundation

public final class LLMModelFactory: @unchecked Sendable {
    public static let shared = LLMModelFactory()
}
public struct ModelConfiguration: Sendable { public init() {} }
public enum ModelNames {}
public struct ModelRegistry {}
public struct ModelContainer {
    public init() {}
    public mutating func perform<Context>(_ context: Context) async throws {}
}
public protocol LanguageModel: AnyObject {}
public struct LMInput {}
public struct GenerateCompletionInfo {}
public enum GenerateStopReason {}
public protocol TokenizerLoader {}
public struct AutoTokenizer {}
public struct LLMRegistry {}
public struct GenerateContext {}
public struct GenerateParameters: Codable, Sendable { public init() {} }
public struct TokenIterator {}
public struct ProgressEvent {}
