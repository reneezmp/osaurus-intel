//
//  MemoryPressureResponder.swift
//  osaurus
//
//  Responds to macOS memory-pressure events by proactively freeing app-side
//  caches, instead of relying solely on NSCache's passive eviction (upstream).
//
//  Intel: upstream's critical tier also unloads idle local model weights and
//  trims MLX's buffer pool; Intel runs no local models, so both tiers free the
//  same reconstructible UI caches. Intel's `ThreadCache` is a no-op stub and
//  has nothing to clear.
//

import Foundation
import os

public final class MemoryPressureResponder: @unchecked Sendable {
    public static let shared = MemoryPressureResponder()

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "MemoryPressure")
    private let queue = DispatchQueue(label: "com.dinoki.osaurus.memory-pressure", qos: .utility)
    private var source: DispatchSourceMemoryPressure?

    private init() {}

    /// Install the memory-pressure handler. Idempotent; called once at launch.
    public func start() {
        queue.sync {
            guard source == nil else { return }
            let src = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self, let source = self.source else { return }
                let event = source.data
                if event.contains(.critical) || event.contains(.warning) {
                    Self.log.info("memory pressure — freeing app caches")
                    self.freeCaches()
                }
            }
            src.activate()
            source = src
        }
    }

    /// Drop reconstructible UI caches. Everything here is re-derived lazily
    /// on next use; nothing user-visible is lost.
    func freeCaches() {
        ChatImageCache.shared.removeAll()
        LaTeXRenderer.shared.clearCache()
        SymbolImageCache.clear()
        AvatarBitmapRenderer.shared.removeAll()
    }
}
