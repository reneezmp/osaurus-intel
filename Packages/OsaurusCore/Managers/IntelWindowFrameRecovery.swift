//
//  IntelWindowFrameRecovery.swift
//  osaurus
//
//  Upstream #2154 (`84271e386`, `WindowManager.showWindow`): a restored or
//  reused window frame can sit on a display that is gone (external monitor
//  unplugged or rearranged) or have collapsed to a degenerate size. AppKit
//  still reports the window as visible, so the user sees nothing ("Settings
//  won't open"). Before showing, a frame that isn't usably on any current
//  screen falls back to a known-good size, centred. Upstream's
//  `WindowManager` is excluded on Intel, so the same test lives here for
//  Intel's chat and Settings windows.
//

import AppKit

enum IntelWindowFrameRecovery {
    /// Upstream's thresholds: at least 200×200, and at least 100×50 of it
    /// inside some screen's visible frame.
    static func isUsable(_ frame: NSRect, screenFrames: [NSRect]) -> Bool {
        let hasUsableSize = frame.width >= 200 && frame.height >= 200
        let isReachable = screenFrames.contains { visible in
            let overlap = visible.intersection(frame)
            return overlap.width >= 100 && overlap.height >= 50
        }
        return hasUsableSize && isReachable
    }

    /// Reset `window` to `fallbackSize`, centred on `screen` (else the main
    /// screen), when its frame isn't usable. Returns whether it recovered.
    @MainActor
    @discardableResult
    static func recoverIfNeeded(_ window: NSWindow, fallbackSize: NSSize, screen: NSScreen? = nil, label: String) -> Bool {
        let frame = window.frame
        guard !isUsable(frame, screenFrames: NSScreen.screens.map(\.visibleFrame)) else { return false }
        print("[IntelWindowFrameRecovery] Recovering \(label) from stale frame \(frame)")
        window.setContentSize(fallbackSize)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        } else {
            window.center()
        }
        return true
    }
}
