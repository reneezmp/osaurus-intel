//
//  DocumentAdaptersBootstrap.swift
//  osaurus
//
//  Registers the in-tree document adapters with `DocumentFormatRegistry.shared`
//  exactly once, at app launch. Kept separate from `AppDelegate` so tests can
//  opt into the same registration (or opt out of it entirely) without dragging
//  in `NSApplication`.
//

import Foundation

public enum DocumentAdaptersBootstrap {
    private static let lock = NSLock()
    // Guarded by `lock`; the `nonisolated(unsafe)` matches the project pattern
    // for lock-protected process-global state (see `OsaurusPaths.overrideRoot`).
    nonisolated(unsafe) private static var didRegisterShared = false

    /// Idempotent against the shared registry: safe to call from multiple
    /// launch paths without producing duplicate adapter registrations.
    /// Non-shared registries (tests, isolated instances) are re-registered on
    /// every call so each test gets a clean baseline.
    public static func registerBuiltIns(registry: DocumentFormatRegistry = .shared) {
        lock.lock()
        defer { lock.unlock() }
        if registry === DocumentFormatRegistry.shared, didRegisterShared { return }
        registry.register(adapter: PlainTextAdapter())
        registry.register(adapter: CSVAdapter(delimiter: .comma))
        registry.register(adapter: CSVAdapter(delimiter: .tab))
        registry.register(adapter: PDFAdapter())
        registry.register(adapter: PPTXAdapter())
        registry.register(adapter: RichDocumentAdapter())
        registry.register(adapter: XLSXAdapter())
        registry.register(emitter: XLSXEmitter())
        // Upstream #91: Markdown/HTML → Word and PDF for file_write.
        // (PPTXEmitter waits for upstream's OOXML writer stack.)
        registry.register(emitter: DOCXEmitter())
        registry.register(emitter: PDFEmitter())
        if registry === DocumentFormatRegistry.shared {
            didRegisterShared = true
        }
    }
}
