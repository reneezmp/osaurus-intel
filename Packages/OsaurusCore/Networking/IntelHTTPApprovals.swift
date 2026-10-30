//
//  IntelHTTPApprovals.swift
//  osaurus
//
//  The cards a run from the owner's paired phone waits on, and the phone's
//  answers (`W-server-api` stage 4d, docs/SERVER_API_INTEL.md; upstream
//  docs/MOBILE_PROTOCOL.md §16):
//
//  - `GET /approvals`, `POST /approvals/{id}`: tool approval cards
//    (`ToolPermissionPromptService.remotePrompts`).
//  - `GET /config/approvals`, `POST /config/approvals/{id}`: configuration
//    plans (Intel's `IntelConfigApprovalQueue`).
//  - `GET /computer-use/prompts`, `POST /computer-use/prompts/{id}`: computer
//    use confirm and cloud-vision consent cards (`ComputerUsePromptQueue`).
//  - `GET /secrets/prompts`, `POST /secrets/prompts/{id}`: secret requests
//    (`RemoteSecretPromptQueue`).
//
//  All owner-only. A card reaches these lists only from a run with a remote
//  reviewer (`ChatExecutionContext.hasRemoteReviewer`): the owner's key over
//  the Secure Channel, which Intel gains with `W-identity-mobile`. Until then
//  the lists are empty and every answer is "not pending".
//
//  Intel's request log never records request or response bodies, so a
//  secret sent to `POST /secrets/prompts/{id}` is never logged (upstream
//  logs no request body here either).
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    /// The approval and prompt routes, in upstream's routing order.
    func routeApprovalsRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        if head.method == .GET, path == "/config/approvals" {
            serveListConfigApprovals(context: context)
        } else if head.method == .POST, path.hasPrefix("/config/approvals/") {
            serveAnswerConfigApproval(context: context, head: head, path: path)
        } else if head.method == .GET, path == "/computer-use/prompts" || path == "/secrets/prompts" {
            serveListPhonePrompts(context: context, path: path)
        } else if head.method == .POST,
            path.hasPrefix("/computer-use/prompts/") || path.hasPrefix("/secrets/prompts/")
        {
            serveAnswerPhonePrompt(context: context, head: head, path: path)
        } else if head.method == .GET, path == "/approvals" {
            serveListApprovals(context: context)
        } else if head.method == .POST, path.hasPrefix("/approvals/") {
            serveAnswerApproval(context: context, head: head, path: path)
        } else {
            return false
        }
        return true
    }

    // MARK: - /config/approvals

    private struct ConfigApprovalDecisionRequest: Decodable {
        let decision: String
    }

    /// GET /config/approvals — configuration plans a run from the paired
    /// phone is waiting on (§16.3). Owner-only: approving one reconfigures
    /// this Mac.
    private func serveListConfigApprovals(context: ChannelHandlerContext) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let data = await MainActor.run { IntelConfigApprovalQueue.shared.pairedPhoneListJSON() }
            self.respondOnLoop(
                eventLoop, status: .ok, headers: self.jsonHeaders(), body: String(decoding: data, as: UTF8.self))
        }
    }

    /// POST /config/approvals/{id} — `{"decision":"apply" | "cancel"}` (§16.3).
    /// Owner-only.
    private func serveAnswerConfigApproval(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 3, let approvalId = UUID(uuidString: String(components[2])) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_approval_id"}"#)
            return
        }
        guard let request = try? JSONDecoder().decode(ConfigApprovalDecisionRequest.self, from: requestBodyData()),
            request.decision == "apply" || request.decision == "cancel"
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {decision: apply | cancel}"}"#)
            return
        }
        let apply = request.decision == "apply"
        let eventLoop = context.eventLoop
        runRequestTask {
            let answered = await MainActor.run {
                IntelConfigApprovalQueue.shared.resolveFromPairedPhone(id: approvalId, apply: apply)
            }
            self.respondOnLoop(
                eventLoop, status: answered ? .ok : .notFound, headers: self.jsonHeaders(),
                body: answered ? #"{"ok":true}"# : #"{"error":"approval_not_pending"}"#)
        }
    }

    // MARK: - /computer-use/prompts, /secrets/prompts

    private struct PhonePromptAnswerRequest: Decodable {
        /// Computer use: `approve | deny | approve_rest`; cloud-vision consent:
        /// `allow_once | allow_always | deny`; secrets: `cancel` or absent.
        let decision: String?
        /// Secrets only: the value to store.
        let value: String?
    }

    /// GET /computer-use/prompts and GET /secrets/prompts — the confirm,
    /// cloud-vision consent and secret cards a run from the paired phone is
    /// waiting on (§16.4, §16.5). Owner-only.
    private func serveListPhonePrompts(context: ChannelHandlerContext, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        let isSecrets = path == "/secrets/prompts"
        let eventLoop = context.eventLoop
        runRequestTask {
            let data = await MainActor.run {
                isSecrets
                    ? RemoteSecretPromptQueue.shared.listJSON()
                    : ComputerUsePromptQueue.shared.pairedPhoneListJSON()
            }
            self.respondOnLoop(
                eventLoop, status: .ok, headers: self.jsonHeaders(), body: String(decoding: data, as: UTF8.self))
        }
    }

    /// POST /computer-use/prompts/{id} and POST /secrets/prompts/{id} (§16.4,
    /// §16.5). Owner-only. The request body is never logged: for a secret it
    /// is the secret.
    private func serveAnswerPhonePrompt(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 3, let promptId = UUID(uuidString: String(components[2])) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_prompt_id"}"#)
            return
        }
        let isSecrets = components[0] == "secrets"
        guard let request = try? JSONDecoder().decode(PhonePromptAnswerRequest.self, from: requestBodyData()) else {
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"bad_request"}"#)
            return
        }
        // A secret is stored only when one is sent and the phone did not
        // cancel; anything else cancels the prompt.
        let secretValue: String? =
            request.decision == "cancel" ? nil : request.value.flatMap { $0.isEmpty ? nil : $0 }
        if !isSecrets && request.decision == nil {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {decision}"}"#)
            return
        }
        let decision = request.decision ?? ""
        let eventLoop = context.eventLoop
        runRequestTask {
            let outcome: ComputerUsePromptQueue.PairedPhoneAnswer = await MainActor.run {
                if isSecrets {
                    return RemoteSecretPromptQueue.shared.resolve(id: promptId, value: secretValue)
                        ? .answered : .notPending
                }
                return ComputerUsePromptQueue.shared.resolveFromPairedPhone(id: promptId, decision: decision)
            }
            // A decision that doesn't fit the card is the phone's mistake, not
            // a gone card: 400 keeps it from dropping a card still waiting.
            let status: HTTPResponseStatus
            let json: String
            switch outcome {
            case .answered:
                status = .ok
                json = #"{"ok":true}"#
            case .notPending:
                status = .notFound
                json = #"{"error":"prompt_not_pending"}"#
            case .invalidDecision:
                status = .badRequest
                json = #"{"error":"invalid_decision"}"#
            }
            self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: json)
        }
    }

    // MARK: - /approvals

    /// One pending approval card of `GET /approvals`.
    private struct ApprovalDTO: Encodable {
        let id: String
        let tool: String
        let description: String
        /// The call's arguments, as the Mac's own card shows them.
        let arguments: String
        /// `sandboxVM | nativeHost | remoteServer`, or null when the card is
        /// not about running a tool somewhere.
        let surface: String?
        /// Whether `allow_for_run` is one of the answers.
        let offers_run_lease: Bool
        /// True for the card on screen; the rest are queued behind it.
        let presented: Bool
    }

    private struct ApprovalsResponse: Encodable {
        let approvals: [ApprovalDTO]
    }

    private struct ApprovalDecisionRequest: Decodable {
        let decision: String
    }

    /// GET /approvals — the cards this Mac is waiting on (§16.1). Owner-only:
    /// answering a card is consent to run something on this Mac.
    private func serveListApprovals(context: ChannelHandlerContext) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let approvals: [ApprovalDTO] = await MainActor.run {
                ToolPermissionPromptService.remotePrompts.map { prompt in
                    ApprovalDTO(
                        id: prompt.id.uuidString,
                        tool: prompt.toolName,
                        description: prompt.description,
                        arguments: prompt.argumentsJSON,
                        surface: prompt.surface,
                        offers_run_lease: prompt.offersRunLease,
                        presented: prompt.isPresented
                    )
                }
            }
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(ApprovalsResponse(approvals: approvals)))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"approvals":[]}"#
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    /// POST /approvals/{id} — answer one card (§16.2). Owner-only.
    private func serveAnswerApproval(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 2, let promptId = UUID(uuidString: String(components[1])) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_approval_id"}"#)
            return
        }
        guard let request = try? JSONDecoder().decode(ApprovalDecisionRequest.self, from: requestBodyData()),
            let outcome = Self.promptResolution(for: request.decision)
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body:
                    #"{"error":"bad_request","message":"Expected {decision: deny | allow_once | allow_for_run | always_allow}"}"#
            )
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let answered = await MainActor.run {
                ToolPermissionPromptService.resolveRemotely(id: promptId, outcome: outcome)
            }
            // A card that is gone was already answered on the Mac, or its run
            // ended — say so rather than pretending the decision landed.
            self.respondOnLoop(
                eventLoop, status: answered ? .ok : .notFound, headers: self.jsonHeaders(),
                body: answered ? #"{"ok":true}"# : #"{"error":"approval_not_pending"}"#)
        }
    }

    /// The §16.2 decision vocabulary. Nil for anything else.
    static func promptResolution(
        for decision: String
    ) -> ToolPermissionPromptService.PromptResolution? {
        switch decision {
        case "deny": return .denied
        case "allow_once": return .allowOnce
        case "allow_for_run": return .allowForRun
        case "always_allow": return .alwaysAllow
        default: return nil
        }
    }
}
