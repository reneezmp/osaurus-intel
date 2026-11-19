//
//  IntelHTTPImportAdmin.swift
//  osaurus
//
//  `/admin/import/*` (W-osaurus-bundles stage 3): the running-app side of
//  `osaurus import` on upstream Classic (#3174). `POST /admin/import/plan`
//  checks a bundle against this Mac and changes nothing
//  (`{"bundle_path", "operations": [{"action", "kind", "name"}]}` ->
//  `{"issues", "warnings"}`); `POST /admin/import/apply` applies a request
//  the CLI already queued (`{"id"}` -> the request's `ImportResult`).
//
//  It keeps EXACTLY the rules of `/admin/config/*` on Intel
//  (`IntelHTTPConfigAdmin.swift`): the physical loopback address only, no
//  Secure Channel, no agent-scoped keys, browser callers refused
//  (`ConfigAdminEndpoint.browserRefusal`), a JSON Content-Type required on
//  every POST, and a request body cap. On top of the general gate (access key
//  when `LocalAPIKeyPolicy` is on).
//
//  Owner policy, where Intel differs from upstream on purpose: upstream
//  applies the queued request straight from the HTTP call. Here every apply
//  waits for the user to review the whole request in the Mac app
//  (`PendingImportProcessor.approver`, the same plan modal as
//  `/admin/config/apply`). With no chat window to show it the apply answers
//  409 and the request STAYS queued, never applied; a denial applies nothing;
//  a timeout answers 408. `--yes` / `confirm_high_risk` cannot approve for the
//  user. `plan` reads the bundle folder the caller names and validates it; it
//  never copies, installs or runs anything from it.
//

import Foundation
import NIOCore
import NIOHTTP1
import OsaurusRepository

/// The HTTP-independent core of `/admin/import/*`, so the contract is unit
/// testable without a socket.
enum ImportAdminEndpoint {
    enum Operation: Equatable {
        case plan
        case apply
    }

    typealias Response = ConfigAdminEndpoint.Response

    /// Request body cap (upstream's 256 KB).
    static let requestLimit = 256 * 1024

    /// Seconds before a deferred server restart (settings an import changed),
    /// so the apply answer reaches the caller first.
    static let deferredSettingsDelay: Duration = .milliseconds(600)

    static func handle(
        operation: Operation,
        requestBody: Data,
        processor: PendingImportProcessor? = nil
    ) async -> Response {
        guard !requestBody.isEmpty, requestBody.count <= requestLimit,
            let request = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        else {
            return ConfigAdminEndpoint.error(.badRequest, "POST a JSON object body (at most 256 KB).")
        }
        var resolved = processor
        if resolved == nil { resolved = await MainActor.run { PendingImportProcessor.shared } }
        guard let processor = resolved else {
            return ConfigAdminEndpoint.error(.internalServerError, "No import processor.")
        }

        switch operation {
        case .plan:
            guard let bundlePath = request["bundle_path"] as? String, !bundlePath.isEmpty else {
                return ConfigAdminEndpoint.error(.badRequest, "`bundle_path` is required.")
            }
            let operations = ((request["operations"] as? [[String: Any]]) ?? []).compactMap {
                raw -> ImportOperation? in
                guard let kind = (raw["kind"] as? String).flatMap(BundleItemKind.init(rawValue:)),
                    let name = raw["name"] as? String
                else { return nil }
                let action = (raw["action"] as? String).flatMap(ImportAction.init(rawValue:)) ?? .install
                return ImportOperation(action: action, kind: kind, name: name, explicit: true)
            }
            let checked = await processor.plan(
                bundleAt: URL(fileURLWithPath: bundlePath, isDirectory: true), operations: operations)
            return (.ok, ConfigAdminEndpoint.body(["issues": checked.issues, "warnings": checked.warnings]))

        case .apply:
            guard let id = request["id"] as? String, !id.isEmpty else {
                return ConfigAdminEndpoint.error(.badRequest, "`id` (the queued request id) is required.")
            }
            // A request id names a folder under the import queue: refuse anything
            // that is not a plain id so it can never point elsewhere.
            guard id.range(of: #"^[A-Za-z0-9._-]{1,80}$"#, options: .regularExpression) != nil,
                id != ".", id != ".."
            else {
                return ConfigAdminEndpoint.error(.badRequest, "`id` is not a valid request id.")
            }
            guard let outcome = await processor.process(requestId: id) else {
                return ConfigAdminEndpoint.error(
                    .unprocessableEntity,
                    "No queued import request \(id). It may have been cancelled with `osaurus import remove`.")
            }
            switch outcome {
            case .completed(let result):
                guard let data = try? ImportQueue.encoder().encode(result) else {
                    return ConfigAdminEndpoint.error(.internalServerError, "Could not encode the import result.")
                }
                return (.ok, String(decoding: data, as: UTF8.self))
            case .awaitingApproval(.timedOut):
                return (
                    .requestTimeout,
                    ConfigAdminEndpoint.body([
                        "status": "approval_timed_out",
                        "message": "The import review timed out. Nothing was applied; the request is still queued.",
                    ])
                )
            case .awaitingApproval:
                return (
                    .conflict,
                    ConfigAdminEndpoint.body([
                        "status": "approval_unavailable",
                        "message":
                            "Importing a bundle needs the user's approval in the Osaurus app. Open a chat "
                            + "window in Osaurus and run the import again, or open Agents and review the "
                            + "waiting bundle. Nothing was applied; the request is still queued.",
                    ])
                )
            }
        }
    }
}

extension HTTPHandler {
    /// Recognizes `/admin/import/*` and answers it; false for any other path.
    func routeImportAdminRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        let operation: ImportAdminEndpoint.Operation
        switch (head.method, path) {
        case (.POST, "/admin/import/plan"): operation = .plan
        case (.POST, "/admin/import/apply"): operation = .apply
        default: return false
        }

        let eventLoop = context.eventLoop
        func refuse(_ status: HTTPResponseStatus, _ message: String) {
            let response = ConfigAdminEndpoint.error(status, message)
            sendResponse(context: context, status: response.status, headers: jsonHeaders(), body: response.body)
        }

        // Local only, on the physical address; never Secure Channel; an
        // agent-scoped key never reaches `/admin/*`. Same guard as `/admin/config/*`.
        guard isPhysicalLoopbackConnection(context), !requestIsSecureChannel,
            stateRef.value.authedAudience == nil || stateRef.value.authedScopeIsMaster
        else {
            refuse(
                .forbidden,
                "/admin/import/* is restricted to local (loopback) callers. Run `osaurus import` on this Mac.")
            return true
        }

        if let refusal = ConfigAdminEndpoint.browserRefusal(
            host: head.headers.first(name: "Host"),
            origin: head.headers.first(name: "Origin"),
            secFetchSite: head.headers.first(name: "Sec-Fetch-Site"),
            allowedOrigins: configuration.allowedOrigins,
            route: "/admin/import/*"
        ) {
            refuse(.forbidden, refusal)
            return true
        }

        if requestBodyData().count > ImportAdminEndpoint.requestLimit {
            refuse(.payloadTooLarge, "Request body too large (max \(ImportAdminEndpoint.requestLimit / 1024) KB).")
            return true
        }
        guard
            let contentType = head.headers.first(name: "Content-Type"),
            contentType.lowercased().contains("application/json")
        else {
            refuse(.unsupportedMediaType, "POST /admin/import/* expects Content-Type: application/json.")
            return true
        }

        let requestBody = requestBodyData()
        runRequestTask {
            let response = await ImportAdminEndpoint.handle(operation: operation, requestBody: requestBody)
            self.respondOnLoop(
                eventLoop, status: response.status, headers: self.jsonHeaders(), body: response.body)
            if operation == .apply, response.status == .ok {
                // A settings change that restarts the server (Allowed Origins)
                // runs after the answer is on its way.
                Task { @MainActor in
                    try? await Task.sleep(for: ImportAdminEndpoint.deferredSettingsDelay)
                    await PendingImportProcessor.shared.applyDeferredSettings()
                }
            }
        }
        return true
    }
}
