//
//  IntelNotificationService.swift
//  osaurus
//
//  Intel's macOS notification service. Upstream's `NotificationService.swift`
//  is excluded (model-download and plugin-update notifications have no Intel
//  counterpart); this carries the part Intel needs: agent notifications from
//  the self-scheduling `notify` tool (docs/INTEL_MISSING_FEATURES_BACKLOG.md,
//  `W-self-scheduling`). Clicking one opens that agent in Agents.
//
//  Unlike upstream, permission is not requested at launch: it is asked the
//  first time an agent gets self-scheduling or posts a notification.
//

import AppKit
import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()

    /// `UNUserNotificationCenter.current()` raises in processes without an app
    /// bundle (`swift test`); every entry point no-ops when this is nil.
    private lazy var center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil && !RuntimeEnvironment.isUnderTests ? .current() : nil

    private override init() { super.init() }

    /// Launch hook: become the delegate so clicks route here. Does not prompt.
    func configureOnLaunch() {
        center?.delegate = self
    }

    /// Ask for permission (shows the macOS prompt once; later calls are no-ops).
    func requestAuthorizationIfNeeded() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Post an agent notification (upstream signature, used by `notify`).
    nonisolated func postAgentEvent(
        agentId: UUID,
        agentName: String,
        title: String,
        body: String,
        viewRef: String?
    ) {
        guard let center else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "\(agentName) · \(title)"
        content.body = body
        var info: [String: Any] = ["agentId": agentId.uuidString, "source": "agent"]
        if let viewRef, !viewRef.isEmpty { info["viewRef"] = viewRef }
        content.userInfo = info
        let request = UNNotificationRequest(
            identifier: "agent-\(agentId.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { NSLog("[Osaurus] agent notification failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            (info["source"] as? String) == "agent",
            let raw = info["agentId"] as? String, let agentId = UUID(uuidString: raw)
        else { return }
        Task { @MainActor in
            AppDelegate.shared?.showManagementWindow(initialTab: .agents, deeplinkAgentId: agentId)
        }
    }
}
