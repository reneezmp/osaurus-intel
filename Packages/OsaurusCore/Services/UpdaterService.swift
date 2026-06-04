//
//  UpdaterService.swift
//  osaurus
//
//  Created by Terence on 8/21/25.
//

import Foundation
import Sparkle

@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    nonisolated private static let betaUpdatesKey = "betaUpdatesEnabled"

    // M13 follow-up (Renée 2026-06-04): on the Intel fork, never start the
    // automatic update cycle. The official Osaurus appcast ships Apple-Silicon
    // builds; once its version surpasses ours, an auto-check would offer to
    // download and REPLACE this hand-built Intel app. `startingUpdater: false`
    // means no background checks ever fire. (feedURLString also returns nil and
    // the check methods no-op below — belt, suspenders, and a second belt.)
    #if OSAURUS_INTEL
    lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    #else
    lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    #endif

    // MARK: - Published State for Update Availability
    @Published var updateAvailable: Bool = false
    @Published var availableVersion: String? = nil

    @Published var isBetaChannel: Bool {
        didSet {
            UserDefaults.standard.set(isBetaChannel, forKey: Self.betaUpdatesKey)
            #if !OSAURUS_INTEL
            updaterController.updater.resetUpdateCycle()
            NSLog("Sparkle: update channel changed to %@", isBetaChannel ? "beta" : "release")
            #endif
        }
    }

    override init() {
        self.isBetaChannel = UserDefaults.standard.bool(forKey: Self.betaUpdatesKey)
        super.init()
    }

    /// Opens the Sparkle update UI to check and install updates.
    ///
    /// if a background update session is already in flight (which happens
    /// when the settings window has just been opened), `SPUUpdater` reports
    /// `canCheckForUpdates == false` and silently drops user initiated
    /// checks. wait briefly for the in-flight session to settle so the
    /// click reliably surfaces the Sparkle dialog on the first try
    func checkForUpdates() {
        #if OSAURUS_INTEL
        // Pinned build: don't reach the official appcast (which serves Apple
        // Silicon releases). Tell the user instead of silently doing nothing.
        _ = ToastManager.shared.info(
            "Updates are off on the Intel fork",
            message: "This build is hand-pinned — auto-update is disabled to protect your custom Intel app."
        )
        return
        #else
        let updater = updaterController.updater
        if updater.canCheckForUpdates {
            updaterController.checkForUpdates(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if self.updaterController.updater.canCheckForUpdates {
                    self.updaterController.checkForUpdates(nil)
                    return
                }
            }
        }
        #endif
    }

    /// Silently checks for updates in the background without showing UI
    func checkForUpdatesInBackground() {
        #if OSAURUS_INTEL
        // No-op on the Intel fork (no automatic appcast checks — see above).
        return
        #else
        updaterController.updater.checkForUpdatesInBackground()
        #endif
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let beta = UserDefaults.standard.bool(forKey: Self.betaUpdatesKey)
        return beta ? Set(["release", "beta"]) : Set(["release"])
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if OSAURUS_INTEL
        // No appcast on the Intel fork: even if a check somehow fires, there's
        // no feed to pull an (Apple Silicon) release from. Hard disconnect.
        return nil
        #else
        return "https://osaurus-ai.github.io/osaurus/appcast.xml"
        #endif
    }

    // MARK: - Verbose Logging Hooks

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog(
            "Sparkle: didFindValidUpdate version=%@ short=%@",
            item.versionString,
            item.displayVersionString
        )
        let version = item.displayVersionString
        Task { @MainActor in
            self.updateAvailable = true
            self.availableVersion = version
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NSLog("Sparkle: didNotFindUpdate")
        Task { @MainActor in
            self.updateAvailable = false
            self.availableVersion = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsErr = error as NSError
        NSLog(
            "Sparkle: didAbortWithError domain=%@ code=%ld desc=%@ userInfo=%@",
            nsErr.domain,
            nsErr.code,
            nsErr.localizedDescription,
            nsErr.userInfo as NSDictionary
        )
        if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
            NSLog(
                "Sparkle: underlyingError domain=%@ code=%ld desc=%@ userInfo=%@",
                underlying.domain,
                underlying.code,
                underlying.localizedDescription,
                underlying.userInfo as NSDictionary
            )
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        NSLog(
            "Sparkle: willDownloadUpdate version=%@ url=%@",
            item.versionString,
            request.url?.absoluteString ?? "nil"
        )
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        NSLog("Sparkle: didDownloadUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        NSLog("Sparkle: willExtractUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        NSLog("Sparkle: didExtractUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("Sparkle: willInstallUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishInstallingUpdate item: SUAppcastItem) {
        NSLog("Sparkle: didFinishInstallingUpdate version=%@", item.versionString)
    }
}
