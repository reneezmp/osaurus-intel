//
//  ImportSettings.swift
//  osaurus
//
//  Where `PendingImportProcessor` reads and writes the settings a bundle
//  may change (`BundleSetting.all`), through the same stores the Settings
//  controls use. Intel (upstream Classic #3178): the toggle is
//  `LocalAPIKeyPolicy`, the origins are `ServerConfiguration.allowedOrigins`
//  (Intel has no `VMLXServerRuntimeSettings.network` to edit). Both only
//  run after the user approved the import in the app.
//

import Foundation
import OsaurusRepository

@MainActor
protocol ImportSettingsAccess: AnyObject {
    func value(of setting: BundleSetting) -> BundleSettingValue
    func set(_ value: BundleSettingValue, for setting: BundleSetting)
    func hasAccessKeys() -> Bool
    /// Runs the parts of `set` that restart the server. Called once the
    /// import has answered, so a live `/admin/import/apply` is not cut off
    /// by its own restart.
    func applyDeferredChanges() async
}

@MainActor
final class LiveImportSettings: ImportSettingsAccess {
    static let shared = LiveImportSettings()

    private var needsServerRestart = false

    func value(of setting: BundleSetting) -> BundleSettingValue {
        switch setting.id {
        case .requireLocalAccessKey:
            return .bool(LocalAPIKeyPolicy.isEnabled())
        case .allowedOrigins:
            // Intel's empty list means "no CORS"; a "*" entry means any origin and
            // is never a bundle origin, so it is not reported as one.
            return .strings(ServerController.shared.configuration.allowedOrigins.filter { $0 != "*" })
        }
    }

    func set(_ value: BundleSettingValue, for setting: BundleSetting) {
        switch (setting.id, value) {
        case (.requireLocalAccessKey, .bool(let enabled)):
            LocalAPIKeyPolicy.setEnabled(enabled)
        case (.allowedOrigins, .strings(let origins)):
            let controller = ServerController.shared
            var configuration = controller.configuration
            // `BundleSetting.applying` already merged the bundle's origins with
            // the current list; keep a "*" the user set themselves.
            let keepsWildcard = configuration.allowedOrigins.contains("*")
            configuration.allowedOrigins = origins + (keepsWildcard ? ["*"] : [])
            controller.configuration = configuration
            ServerConfigurationStore.save(configuration)
            needsServerRestart = true
        default:
            assertionFailure("\(setting.key) does not take \(value)")
        }
    }

    func hasAccessKeys() -> Bool {
        !APIKeyManager.shared.listKeys().isEmpty
    }

    func applyDeferredChanges() async {
        guard needsServerRestart else { return }
        needsServerRestart = false
        await ServerController.shared.restartServer()
    }
}
