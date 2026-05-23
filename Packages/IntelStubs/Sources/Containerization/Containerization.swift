import Foundation
@_exported import MLXLMCommon

public final class ContainerManager: @unchecked Sendable {
    public init() {}
    public static let shared = ContainerManager()
}
public struct LinuxProcessConfiguration: Codable, Sendable { public init() {} }
public struct UnixSocketConfiguration { public init() {} }
public struct Mount { public init() {} }
public enum ExitStatus {}
public struct VmnetNetwork { public init() {} }
public struct LinuxProcess { 
    public init() {}
    public func kill() throws {}
    public func delete() throws {}
}
public struct LinuxContainer {
    public struct Configuration { public init() {} }
    public init() {}
}
public struct VadManager { public init() {} }
public protocol Writer: AnyObject {}
public struct Kernel {
    public let path: URL
    public let platform: Platform
    public enum Platform {
        case linuxArm
    }
    public init(path: URL, platform: Platform) {
        self.path = path
        self.platform = platform
    }
}
