//
//  InputRoute.swift
//  OsaurusCore — Computer Use
//
//  Intel (docs/W_COMPUTER_USE_PLAN.md, stage 1): upstream declares this enum in
//  `Mac/BackgroundDriver.swift`, which arrives with the native driver in stage 3;
//  the driver contract (`CUActionResult.routeUsed`) needs it now. Stage 3 removes
//  the duplicate from the ported file.
//

import Foundation

/// Tells the caller (and tests) which transport the driver actually used.
/// A synthesized event must never be submitted to a second transport after the
/// first call: SkyLight's return value is not a reliable delivery
/// acknowledgement, and retrying can deliver the event twice.
public enum InputRoute: String, Codable, Sendable {
    /// `SLEventPostToPid`. No cursor warp; trusted by Chromium renderers.
    case skyLight
    /// `CGEvent.postToPid`. No cursor warp; works for most Cocoa apps but
    /// rejected by Chromium web content.
    case perPid
    /// `CGEvent.post(tap: .cghidEventTap)`. **Warps the user's cursor.**
    /// Only used as a last resort for canvas/Blender/Unity-style apps that
    /// filter per-pid event routes entirely.
    case hidFallback
}
