//
//  IntelPluginShims.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2e: the upstream name that
//  `ExternalPlugin.swift` (upstream's, verbatim) uses and Intel doesn't
//  compile yet (`AccessibilityManager` moved to the real driver in
//  `W-computer-use` stage 3). Delete each one when its upstream file is ported.
//

#if OSAURUS_INTEL

import Foundation

/// Upstream's `CrashReportingService` sends breadcrumbs to Sentry, which
/// the Intel build doesn't ship. Breadcrumbs are dropped.
enum CrashReportingService {
    static func recordBreadcrumb(category: String, message: String) {}
}

#endif
