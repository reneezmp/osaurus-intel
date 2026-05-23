import Foundation
@_exported import MLX
@_exported import MLXLLM
@_exported import MLXVLM
@_exported import VMLXTokenizers

public struct VMLXServerRuntimeSettings: Codable, Sendable, Equatable {
    public var cache: VMLXServerCacheSettings = .init()
    public var generation: VMLXServerGenerationDefaults = .init()
    public var concurrency: VMLXServerConcurrencySettings = .init()
    public var network: VMLXServerNetworkSettings = .init()
    public var power: VMLXServerPowerSettings = .init()
    public var multimodal: VMLXServerMultimodalSettings = .init()
    public var tools: VMLXServerToolSettings = .init()
    public var mtp: VMLXServerMTPSettings = .init()
    public var smeltMode: VMLXServerSmeltMode = .off
    public var logLevel: VMLXServerLogLevel = .info
    public var issues: [VMLXServerSettingsIssue] = []
    public init() {}
}

public struct InferenceFeatureFlags: Codable, Sendable, Equatable {
    public init() {}
}

public struct RuntimeConfig: Codable, Sendable, Equatable {
    public init() {}
}

public enum Memory {}
public enum DraftStrategy {}

public struct MTPBundleInspector { public init() {} }
public struct MTPBundleStatus { public init() {} }
public struct JangLoader { public init() {} }
public struct BatchEngineConfigurationError: Error { public init() {} }
public struct BatchEngine { public init() {} }
public struct Generation { public init() {} }
public struct LoadConfiguration { public init() {} }
public struct MLXPressStatus { public init() {} }
public struct NemotronHOmni { public init() {} }

public struct UserInput {
    public struct Audio { public init() {} }
    public struct Image { public init() {} }
    public struct Video { public init() {} }
    public init() {}
}

public typealias ProgressHandler = @Sendable (ProgressEvent) async -> Void
public struct ModelRuntimeCapabilityRequest { public init() {} }
public enum ModelRuntimeRequestModality: Hashable {}
public struct CacheCoordinatorConfig: Codable, Sendable { public init() {} }
public struct CacheCoordinatorStatsSnapshot { public init() {} }
public struct ModelCacheTopologySnapshot { public init() {} }
public protocol ReaderStream: AnyObject {}

public enum Chat {
    public struct Message { public init() {} }
}

public struct DeepseekV4ChatEncoder {
    public struct Message { public init() {} }
    public enum MessageRole {}
    public struct ToolCall { public init() {} }
    public init() {}
}

public enum DeepseekV4ReasoningEffort {}
public enum DeepseekV4ThinkingMode {}
public protocol GenerationPromptControllableTokenizer {}
public struct ModelContext {
    public var model: Any? { nil }
    public init() {}
}
public struct JSONValue { public init() {} }
public protocol Tokenizer {}
public struct ToolCall { public init() {} }
public struct GenerateParameters: Codable, Sendable { public init() {} }

public struct VMLXBlockDiskCacheSettings: Codable, Sendable { public init() {} }
public struct VMLXDiskCacheSettings: Codable, Sendable { public init() {} }
public struct VMLXKVCacheCodec: Codable, Sendable { public init() {} }
public struct VMLXMTPServerMode: RawRepresentable, Codable, Sendable {
    public var rawValue: String
    public init?(rawValue: String) { self.rawValue = rawValue }
}
public struct VMLXPagedKVCacheSettings: Codable, Sendable { public init() {} }
public struct VMLXPrefixCacheSettings: Codable, Sendable { public init() {} }
public struct VMLXServerCacheSettings: Codable, Sendable, Equatable { public init() {} }
public struct VMLXServerConcurrencySettings: Codable, Sendable, Equatable { public init() {} }
public struct VMLXServerGenerationDefaults: Codable, Sendable, Equatable {
    public var temperature: Double = 0.7
    public var maxTokens: Int = 4096
    public var repetitionPenalty: Double = 1.0
    public init() {}
}
public enum VMLXServerLogLevel: String, Codable, Sendable, Equatable { case info }
public struct VMLXServerMTPSettings: Codable, Sendable, Equatable { public init() {} }
public struct VMLXServerMultimodalSettings: Codable, Sendable, Equatable { public init() {} }
public struct VMLXServerNetworkSettings: Codable, Sendable, Equatable { public init() {} }
public struct VMLXServerPowerSettings: Codable, Sendable, Equatable { public init() {} }
public enum VMLXServerSettingsIssue: String, Codable, Sendable, Equatable { case placeholder }
public enum VMLXServerSmeltMode: String, Codable, Sendable, Equatable { case off, engineSelected }
public struct VMLXServerToolSettings: Codable, Sendable, Equatable { public init() {} }
public struct VMLXStoredKVCacheCodec: Codable, Sendable { public init() {} }
public enum VMLXVLMServerMode: String, Codable, Sendable { case disabled }

public func nemotronOmniLoadAudioFile(_: URL) throws -> Any { fatalError() }
public func loadModelContainer(configuration: Any, progressHandler: ((Any) -> Void)? = nil) throws -> Any { fatalError() }
public func linearResamplePCM(_: Any, _: Any, _: Any) throws -> Any { fatalError() }
