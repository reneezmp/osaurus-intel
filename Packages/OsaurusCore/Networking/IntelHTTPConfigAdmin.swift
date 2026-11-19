//
//  IntelHTTPConfigAdmin.swift
//  osaurus
//
//  `/admin/config/*` (W-declarative-config stage 5): the automation companion
//  of `osaurus_config` on upstream Classic. `GET /admin/config/export`,
//  `GET /admin/config/schema`, `POST /admin/config/plan` and
//  `POST /admin/config/apply` run the same engine as the chat tool
//  (`ConfigYAML` -> `ConfigPlanner` -> `ConfigApplier`).
//
//  Who may call (upstream's rules, kept): the PHYSICAL loopback address only
//  (`isPhysicalLoopbackConnection`), so a key that leaked to the LAN, the
//  relay tunnel or a paired peer can never rewrite this Mac. On top of the
//  general gate (access key when `LocalAPIKeyPolicy` is on, agent-scoped keys
//  never reach `/admin/*`). Intel refuses Secure Channel calls too: they are
//  remote by definition. Browser callers are refused as well (`browserRefusal`):
//  a web page also connects over loopback.
//
//  Where Intel differs from upstream, on purpose (owner policy, 2026-11-18:
//  nothing reconfigures this Mac without the user's approval): upstream's
//  `apply` applies low-risk changes straight from the HTTP call and only asks
//  the caller to resend `confirm_high_risk` for risky ones. Here EVERY apply
//  waits for the user's approval of the plan in the Mac app
//  (`ConfigApprovalService`, the same review modal the chat tool uses). With
//  no chat window to show it in the apply is refused (409), never applied, and
//  a denial, timeout or cancel applies nothing. `confirm_high_risk` is
//  accepted and ignored: a caller cannot approve on the user's behalf. The
//  request log never records bodies on Intel, so a document is never logged.
//  `template` names a whole-config YAML template saved in `~/.osaurus/templates`
//  (`ConfigTemplateStore`, path-confined, W-agent-templates stage 2); it only
//  supplies the document, so the same plan and approval apply.
//

import Foundation
import NIOCore
import NIOHTTP1

/// The HTTP-independent core of `/admin/config/*`, so the contract is unit
/// testable without a socket.
enum ConfigAdminEndpoint {
    enum Operation: Equatable {
        case export
        case schema
        case plan
        case apply
    }

    typealias Response = (status: HTTPResponseStatus, body: String)
    typealias Approver = @Sendable (ConfigPlan, Bool) async -> ConfigApprovalOutcome

    /// The user's review of an apply: the Mac app's plan modal. Fails closed
    /// when no chat window can show it.
    static let macApprover: Approver = { plan, prune in
        await ConfigApprovalService.requestApproval(plan: plan, prune: prune)
    }

    /// Request envelope cap: the document itself is capped at
    /// `OsaurusConfigTool.maxDocumentBytes`; allow JSON overhead beyond it.
    static var envelopeLimit: Int { OsaurusConfigTool.maxDocumentBytes + 64 * 1024 }

    /// Why a request that looks like it came from a web page is refused, or
    /// nil for a local tool. `Host` must name this Mac (DNS rebinding sends the
    /// attacker's name, with no `Origin` on a same-origin GET); a browser
    /// `Origin` must be listed by name in Allowed Origins (`*` does not count);
    /// `Sec-Fetch-Site: cross-site` / `same-site` is refused unless so listed.
    static func browserRefusal(
        host: String?,
        origin: String?,
        secFetchSite: String?,
        allowedOrigins: [String],
        route: String = "/admin/config/*"
    ) -> String? {
        let message = "Browser requests to \(route) are refused."
        guard let host, isLoopbackHost(host) else { return message }
        if let origin {
            return LocalAPIKeyPolicy.isExplicitlyAllowedOrigin(origin, allowedOrigins: allowedOrigins)
                ? nil : message
        }
        if let site = secFetchSite?.lowercased(), site == "cross-site" || site == "same-site" {
            return message
        }
        return nil
    }

    /// `localhost`, `127.0.0.1` or `[::1]`, with or without a port.
    static func isLoopbackHost(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: .whitespaces).lowercased()
        let name: String
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return false }
            name = String(value[value.startIndex ... end])
            let rest = value[value.index(after: end)...]
            guard rest.isEmpty || isPortSuffix(rest) else { return false }
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, let first = parts.first else { return false }
            if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isNumber) { return false }
            name = String(first)
        }
        return name == "localhost" || name == "127.0.0.1" || name == "[::1]"
    }

    private static func isPortSuffix(_ text: Substring) -> Bool {
        text.count > 1 && text.first == ":" && text.dropFirst().allSatisfy(\.isNumber)
    }

    static func queryParameter(_ name: String, in uri: String) -> String? {
        guard let q = uri.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == name { return kv[1].removingPercentEncoding ?? kv[1] }
        }
        return nil
    }

    static func body(_ object: [String: Any]) -> String { HTTPHandler.jsonObjectString(object) }

    static func error(_ status: HTTPResponseStatus, _ message: String, code: String? = nil) -> Response {
        var inner: [String: Any] = ["message": message, "type": "invalid_request_error"]
        if let code { inner["code"] = code }
        return (status, body(["error": inner]))
    }

    static func handle(
        operation: Operation,
        uri: String,
        requestBody: Data,
        approve: Approver = macApprover
    ) async -> Response {
        switch operation {
        case .export:
            guard let format = ConfigDocumentFormat.parse(queryParameter("format", in: uri)) else {
                return error(.badRequest, "`format` must be yaml or json.")
            }
            let document = await MainActor.run { ConfigExporter.export(sections: nil) }
            do {
                switch format {
                case .yaml: return (.ok, body(["yaml": try ConfigYAML.encode(document)]))
                case .json: return (.ok, body(["json": try ConfigJSON.encode(document)]))
                }
            } catch {
                return Self.error(
                    .internalServerError, "Failed to render the document: \(error.localizedDescription)")
            }

        case .schema:
            guard let format = ConfigDocumentFormat.parse(queryParameter("format", in: uri)) else {
                return error(.badRequest, "`format` must be yaml or json.")
            }
            switch format {
            case .yaml:
                return (
                    .ok,
                    body([
                        "schema": ConfigSchemaReference.text(sections: nil),
                        "sections": ConfigSectionID.allNames,
                    ])
                )
            case .json:
                return (
                    .ok,
                    body([
                        "json_schema": ConfigManifest.jsonSchema(),
                        "sections": ConfigSectionID.allNames,
                    ])
                )
            }

        case .plan, .apply:
            return await planOrApply(operation: operation, requestBody: requestBody, approve: approve)
        }
    }

    private static func planOrApply(
        operation: Operation, requestBody: Data, approve: Approver
    ) async -> Response {
        guard !requestBody.isEmpty,
            let request = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        else {
            return error(
                .badRequest,
                "POST a JSON body: {\"yaml\": \"<document>\"} (the document may be YAML or JSON text) "
                    + "or {\"template\": \"<saved name>\"}, plus an optional \"prune\" boolean.")
        }
        let prune = ArgumentCoercion.bool(request["prune"]) ?? false

        let yaml: String
        let inline = (request["yaml"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let templateName = (request["template"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inline, !OsaurusConfigTool.isEmptyDocument(inline) {
            guard templateName == nil || templateName?.isEmpty == true else {
                return error(.badRequest, "Pass `yaml` OR `template`, not both.")
            }
            yaml = inline
        } else if let templateName, !templateName.isEmpty {
            switch ConfigTemplateStore.load(name: templateName) {
            case .success(let contents): yaml = contents
            case .failure(let message): return error(.badRequest, message)
            }
        } else {
            return error(.badRequest, "Provide the document as `yaml` (inline) or `template` (saved name).")
        }
        guard yaml.utf8.count <= OsaurusConfigTool.maxDocumentBytes else {
            return error(
                .badRequest, "Document too large (max \(OsaurusConfigTool.maxDocumentBytes / 1024) KB).")
        }

        let document: OsaurusConfigDocument
        do {
            document = try ConfigYAML.decode(yaml)
        } catch let failure as ConfigYAMLError {
            return invalid(issues: failure.messages)
        } catch {
            return Self.error(.badRequest, "Could not parse YAML: \(error.localizedDescription)")
        }

        let plan: ConfigPlan
        do {
            plan = try await MainActor.run { [document] in
                try ConfigPlanner.plan(document: document, prune: prune)
            }
        } catch let issues as ConfigPlanIssues {
            return invalid(issues: issues.issues)
        } catch {
            return Self.error(.internalServerError, error.localizedDescription)
        }

        if operation == .plan {
            var payload = plan.payload()
            payload["summary"] = plan.summaryText()
            payload["prune"] = prune
            return (.ok, body(payload))
        }

        if plan.isEmpty {
            return (.ok, body(["status": "no_changes", "summary": plan.summaryText()]))
        }

        // Owner policy: the user approves EVERY apply in the Mac app. An HTTP
        // caller cannot approve for them (`confirm_high_risk` is ignored).
        switch await approve(plan, prune) {
        case .approved:
            break
        case .denied:
            return (
                .forbidden,
                body([
                    "status": "declined",
                    "message": "The user declined the configuration changes. Nothing was applied.",
                    "summary": plan.summaryText(),
                ])
            )
        case .timedOut:
            return (
                .requestTimeout,
                body([
                    "status": "approval_timed_out",
                    "message": "The configuration review timed out. Nothing was applied.",
                ])
            )
        case .cancelled:
            return (
                .conflict,
                body([
                    "status": "approval_unavailable",
                    "message":
                        "Configuration changes need the user's approval in the Osaurus app. Open a chat "
                        + "window in Osaurus and send the request again, or the review was cancelled. "
                        + "Nothing was applied.",
                    "risks": plan.risks,
                    "summary": plan.summaryText(),
                ])
            )
        }

        let results = await ConfigApplier.apply(document: document, prune: prune)
        let failed = results.filter { $0.status == .failed }
        let cancelled = results.filter { $0.status == .cancelled }
        let started = results.filter { $0.status == .started }
        let needsAction = results.filter { $0.status == .needsUserAction }
        // "applied" means everything landed; fire-and-forget downloads report
        // as still running and a user-cancelled step is partial, not clean.
        let status: String
        if !failed.isEmpty || !cancelled.isEmpty {
            status = "partial"
        } else if !started.isEmpty {
            status = "applied_downloads_running"
        } else {
            status = "applied"
        }
        var payload: [String: Any] = ["status": status, "results": results.map { $0.payload }]
        var notes: [String] = []
        if !cancelled.isEmpty {
            notes.append("\(cancelled.count) change(s) were cancelled by the user and did not land.")
        }
        if !needsAction.isEmpty {
            notes.append(
                "\(needsAction.count) change(s) need a step finished in the Osaurus app "
                    + "(credentials never travel through this endpoint).")
        }
        if !started.isEmpty {
            notes.append("\(started.count) download(s) started; check the app for completion.")
        }
        if !notes.isEmpty { payload["note"] = notes.joined(separator: " ") }
        return (.ok, body(payload))
    }

    private static func invalid(issues: [String]) -> Response {
        (
            .badRequest,
            body([
                "error": [
                    "message": "Document is invalid — nothing was changed.",
                    "type": "invalid_request_error",
                    "issues": issues,
                ] as [String: Any]
            ])
        )
    }
}

extension HTTPHandler {
    /// Recognizes `/admin/config/*` and answers it; false for any other path.
    func routeConfigAdminRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        let operation: ConfigAdminEndpoint.Operation
        switch (head.method, path) {
        case (.GET, "/admin/config/export"): operation = .export
        case (.GET, "/admin/config/schema"): operation = .schema
        case (.POST, "/admin/config/plan"): operation = .plan
        case (.POST, "/admin/config/apply"): operation = .apply
        default: return false
        }

        let eventLoop = context.eventLoop
        func refuse(_ status: HTTPResponseStatus, _ message: String) {
            let response = ConfigAdminEndpoint.error(status, message)
            sendResponse(context: context, status: response.status, headers: jsonHeaders(), body: response.body)
        }

        // Local only, on the physical address (not the `trustLoopback` flag,
        // which a relay-tunnelled or remote caller must never satisfy). A
        // Secure Channel call is remote by definition; an agent-scoped key
        // never reaches `/admin/*` (the gate), refused here again.
        guard isPhysicalLoopbackConnection(context), !requestIsSecureChannel,
            stateRef.value.authedAudience == nil || stateRef.value.authedScopeIsMaster
        else {
            refuse(
                .forbidden,
                "/admin/config/* is restricted to local (loopback) callers. "
                    + "Use the Osaurus app on this Mac.")
            return true
        }

        // A web page open in the user's browser also connects over loopback,
        // and without `LocalAPIKeyPolicy` the general gate lets it through with
        // `Access-Control-Allow-Origin: *`. Refuse browser callers here,
        // whatever that policy says (Intel, 2026-11-18).
        if let refusal = ConfigAdminEndpoint.browserRefusal(
            host: head.headers.first(name: "Host"),
            origin: head.headers.first(name: "Origin"),
            secFetchSite: head.headers.first(name: "Sec-Fetch-Site"),
            allowedOrigins: configuration.allowedOrigins
        ) {
            refuse(.forbidden, refusal)
            return true
        }

        if head.method == .POST {
            if requestBodyData().count > ConfigAdminEndpoint.envelopeLimit {
                refuse(
                    .payloadTooLarge,
                    "Request body too large (max \(ConfigAdminEndpoint.envelopeLimit / 1024) KB).")
                return true
            }
            // Required, not just checked when present: a page can POST a body
            // with no Content-Type without triggering a CORS preflight.
            guard
                let contentType = head.headers.first(name: "Content-Type"),
                contentType.lowercased().contains("application/json")
            else {
                refuse(.unsupportedMediaType, "POST /admin/config/* expects Content-Type: application/json.")
                return true
            }
        }

        let uri = head.uri
        let requestBody = head.method == .POST ? requestBodyData() : Data()
        runRequestTask {
            let response = await ConfigAdminEndpoint.handle(
                operation: operation, uri: uri, requestBody: requestBody)
            self.respondOnLoop(
                eventLoop, status: response.status, headers: self.jsonHeaders(), body: response.body)
        }
        return true
    }
}
