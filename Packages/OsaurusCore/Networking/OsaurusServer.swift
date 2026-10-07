//
//  OsaurusServer.swift
//  osaurus
//
//  Actor-owned NIO server lifecycle (start / stop).
//

import Foundation
import LocalAuthentication
import NIOCore
import NIOHTTP1
import NIOPosix
import os

public actor OsaurusServer: Sendable {
    private final class LazyAPIKeyValidatorSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private let build: @Sendable () -> APIKeyValidator
        private var cached: APIKeyValidator?

        init(_ build: @escaping @Sendable () -> APIKeyValidator) {
            self.build = build
        }

        func value() -> APIKeyValidator {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            let validator = build()
            cached = validator
            return validator
        }
    }

    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public var agentIndex: UInt32?
        public var trustLoopback: Bool
        public init(host: String = "127.0.0.1", port: Int = 1337, agentIndex: UInt32? = nil, trustLoopback: Bool = true)
        {
            self.host = host
            self.port = port
            self.agentIndex = agentIndex
            self.trustLoopback = trustLoopback
        }
    }

    private var channel: Channel?
    /// Live child (per-connection) channels, tracked so `stop` can close
    /// them explicitly. The event-loop group is process-shared
    /// (`SharedEventLoopGroups.server`) and never shut down (upstream #2239:
    /// per-start groups were the EMFILE crash APPLE-MACOS-19T).
    private let childChannels = ChildChannelRegistry()

    public init() {}

    public func start(
        _ config: Config = .init(),
        serverConfiguration: ServerConfiguration = .default
    ) async throws {
        guard channel == nil else { return }

        let group = SharedEventLoopGroups.server
        let childChannels = self.childChannels

        let validatorSnapshot = LazyAPIKeyValidatorSnapshot {
            Self.buildValidator(agentIndex: config.agentIndex)
        }
        let trustLoopback = config.trustLoopback

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                childChannels.track(channel)
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandlers([
                        // Connection cap (first handler, upstream): a flood of
                        // idle-held sockets can't exhaust file descriptors.
                        ConnectionLimitHandler(),
                        HTTPHandler(
                            configuration: serverConfiguration,
                            apiKeyValidatorProvider: { validatorSnapshot.value() },
                            eventLoop: channel.eventLoop,
                            trustLoopback: trustLoopback
                        ),
                    ])
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        // The shared group survives a failed bind, so the busy-port retry
        // (upstream #3018) costs no threads.
        let ch = try await bootstrap.bind(host: config.host, port: config.port).get()
        self.channel = ch
        print("[Osaurus] OsaurusServer started on http://\(config.host):\(config.port)")
    }

    /// Stop the server: close the listener, then close the per-connection
    /// child channels. The event-loop group is process-shared and is never
    /// shut down here, so this cannot leak threads/descriptors across
    /// restarts (APPLE-MACOS-19T) and cannot trip NIO's "EventLoopGroup is
    /// still running" deinit precondition at exit (issue #860).
    ///
    /// - Parameter gracefully: when `true`, in-flight connections get up to
    ///   8 seconds to finish before being force-closed; the quit path passes
    ///   `false` for a bounded 1-second drain.
    /// - Returns: `true` always (kept for call-site compatibility — with a
    ///   shared group there is no longer a "shutdown still in flight" state
    ///   that requires keeping the actor rooted).
    @discardableResult
    public func stop(gracefully: Bool = true) async -> Bool {
        if let ch = self.channel {
            _ = try? await ch.close()
            self.channel = nil
        }
        // Give in-flight connections a bounded window to complete on their
        // own (an SSE stream mid-generation, a response mid-flush), then
        // force-close whatever remains. Closing is idempotent, so racing a
        // natural close is fine.
        let budget: Double = gracefully ? 8.0 : 1.0
        let deadline = Date().addingTimeInterval(budget)
        while !childChannels.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let remaining = childChannels.drain()
        if !remaining.isEmpty {
            print(
                "[Osaurus] OsaurusServer force-closing \(remaining.count) connection(s) after \(budget)s drain budget"
            )
            for ch in remaining {
                ch.close(promise: nil)
            }
        }
        print("[Osaurus] OsaurusServer stopped")
        return true
    }

    // MARK: - Validator Construction

    /// Build a validator from the current identity, whitelist, and revocation state.
    /// Falls back to `.empty` if the account doesn't exist yet.
    private static func buildValidator(agentIndex: UInt32?) -> APIKeyValidator {
        guard MasterKey.exists() else { return .empty }

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        context.interactionNotAllowed = true

        do {
            var masterKeyData = try MasterKey.getPrivateKey(context: context)
            defer { masterKeyData.zeroOut() }

            let masterAddress = try deriveOsaurusId(from: masterKeyData)
            let agentAddress: OsaurusID =
                if let idx = agentIndex {
                    try AgentKey.deriveAddress(masterKey: masterKeyData, index: idx)
                } else {
                    masterAddress
                }
            APIKeyManager.shared.reload()

            return APIKeyValidator(
                agentAddress: agentAddress,
                masterAddress: masterAddress,
                effectiveWhitelist: WhitelistStore.shared.effectiveWhitelist(
                    forAgent: agentAddress,
                    masterAddress: masterAddress
                ),
                revocationSnapshot: RevocationStore.shared.snapshot(),
                hasKeys: !APIKeyManager.shared.listKeys().isEmpty
            )
        } catch {
            print("[Osaurus] Failed to build validator: \(error). Falling back to empty validator.")
            return .empty
        }
    }
}

/// Tracks the live child (per-connection) channels of one server instance so
/// `stop` can drain and close them explicitly. Needed because the event-loop
/// group is process-shared: `shutdownGracefully` — which used to close
/// stragglers — is never called anymore.
final class ChildChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return channels.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return channels.isEmpty
    }

    func track(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        lock.lock()
        channels[id] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.channels.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    /// Remove and return every tracked channel (they are about to be closed).
    func drain() -> [Channel] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(channels.values)
        channels.removeAll()
        return all
    }
}

/// First handler in every child pipeline. Enforces a process-wide ceiling on
/// concurrently open connections so a flood of idle-held sockets (slow-loris,
/// connection-exhaustion DoS) can't run the descriptor table / memory up.
/// Accepted connections increment a shared atomic on `channelActive` and
/// decrement on `channelInactive`; the connection that pushes the live count
/// past the ceiling is closed immediately.
final class ConnectionLimitHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    /// Default ceiling. The server is loopback-first and gated downstream by
    /// `HTTPInferenceAdmission`; this is purely a coarse socket-flood backstop,
    /// set generously so normal multi-client / multi-tab use is never affected.
    static let maxConcurrentConnections = 512

    private static let liveCount = OSAllocatedUnfairLock(initialState: 0)

    /// Current number of open connections — surfaced for `/health`.
    static var currentCount: Int { liveCount.withLock { $0 } }

    private var counted = false

    func channelActive(context: ChannelHandlerContext) {
        let admitted = Self.liveCount.withLock { count -> Bool in
            guard count < Self.maxConcurrentConnections else { return false }
            count += 1
            return true
        }
        if admitted {
            counted = true
            context.fireChannelActive()
        } else {
            NSLog(
                "[Osaurus] Refusing connection — at max concurrent connections (%d)",
                Self.maxConcurrentConnections
            )
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if counted {
            counted = false
            Self.liveCount.withLock { $0 = max(0, $0 - 1) }
        }
        context.fireChannelInactive()
    }
}
