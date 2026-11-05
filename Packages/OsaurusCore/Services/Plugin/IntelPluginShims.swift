//
//  IntelPluginShims.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2e: the two upstream names that
//  `ExternalPlugin.swift` (upstream's, verbatim) uses and Intel doesn't
//  compile yet. Delete each one when its upstream file is ported.
//

#if OSAURUS_INTEL

import Foundation

/// Upstream's `AccessibilityManager` is the Computer Use driver
/// (`ComputerUse/Driver/Mac/Accessibility.swift`, `W-computer-use`).
/// `ExternalPlugin` runs accessibility / automation plugin calls one at a
/// time on its `serialQueue`; this is that queue, with upstream's label.
/// Remove when `W-computer-use` brings the real type.
enum AccessibilityManager {
    static let serialQueue = DispatchQueue(
        label: "com.osaurus.computeruse.driver",
        qos: .userInitiated
    )
}

/// Upstream's `CrashReportingService` sends breadcrumbs to Sentry, which
/// the Intel build doesn't ship. Breadcrumbs are dropped.
enum CrashReportingService {
    static func recordBreadcrumb(category: String, message: String) {}
}

#endif
