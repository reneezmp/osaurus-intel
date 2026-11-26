//
//  PrivacyDetectorSupport.swift
//  osaurus / PrivacyFilter
//
//  Intel-only (`W-privacy-filter`, `docs/W_PRIVACY_FILTER_PLAN.md`).
//  Upstream's two on-device detectors, the 2.8 GB OpenAI privacy-filter
//  MoE (`PrivacyFilterKit`) and the 37 MB Rampart BERT (`RampartPII`), are
//  both MLX models: they need Apple Silicon unified memory and Metal
//  kernels, and upstream's own package targets macOS 15. Neither runs on
//  macOS 13 x86_64, so they are marked Incompatible here. The rule-based
//  layer (built-in patterns, presets, custom rules, spoken numbers) is
//  the whole filter on Intel.
//
//  Owner policy: the filter only removes or masks data before it leaves
//  the Mac. It never sends text anywhere new to decide what to mask, so
//  there is no cloud detector fallback either.
//

import Foundation

public enum PrivacyDetectorSupport {
    /// False on this build: no model detector can run on macOS 13 x86_64.
    public static let modelDetectorsRunnable = false
}
