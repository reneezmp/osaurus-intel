import Foundation

public struct VecturaKitType {
    public init() {}
}
public typealias VecturaKit = VecturaKitType

public struct SwiftEmbedder {
    public init(modelSource: ModelSource) { fatalError() }
}
public struct VecturaConfig {
    public init() {}
}
public protocol VecturaEmbedder {}

public enum ModelSource {
    case `default`
    case custom(String)
}
