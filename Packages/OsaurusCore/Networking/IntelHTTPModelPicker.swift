//
//  IntelHTTPModelPicker.swift
//  osaurus
//
//  The owner's model picker and credits over HTTP (`W-server-api` stage 5b,
//  docs/SERVER_API_INTEL.md; upstream MOBILE_PROTOCOL §12):
//
//  - `GET /models/picker` — the chat models the Mac's composer picker lists,
//    in its tabs, with the favourites.
//  - `POST /models/options` — a model's Model Options rows;
//    `PUT /models/options` — store one, as the composer does.
//  - `PUT /models/favorites` — heart or unheart a model.
//  - `GET /credits/balance` — the Osaurus Router balance for local tools.
//
//  The picker, options and favourites are owner-only (writes need the
//  Secure Channel from a remote owner). Credits answers a verified master
//  key, or a key-less loopback caller once the user opts in.
//
//  Intel differences: image models (upstream's `kind: image` rows with their
//  `image` / `cloud` controls) come with the media routes (stage 6); the
//  Privacy Filter's per-model `privacy` field with `W-privacy-filter`; local
//  bundles' external source and Native MTP have no Intel counterpart.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    func routeModelPickerRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        if head.method == .GET, path == "/models/picker" {
            serveModelPicker(context: context)
        } else if head.method == .POST || head.method == .PUT, path == "/models/options" {
            serveModelOptions(context: context, head: head)
        } else if head.method == .PUT, path == "/models/favorites" {
            serveModelFavorite(context: context, head: head)
        } else if head.method == .GET, path == "/credits/balance" {
            serveCreditsBalance(context: context, head: head)
        } else {
            return false
        }
        return true
    }

    // MARK: - GET /models/picker

    struct PickerModelDTO: Encodable {
        let id: String
        let name: String
        /// Tab / section title: "Local", "Apple Foundation", or the provider name.
        let provider: String
        /// `foundation | local | remote`
        let source: String
        let vision: Bool
        let thinking: Bool
        let params: String?
        let quantization: String?
        /// False for local bundles the picker greys out. Intel runs none.
        let available: Bool
        let description: String?
        /// The picker tab holding this model (`local`, `remote-<uuid>`) and
        /// its title (`Local`, the provider name).
        let tab: String
        let tabTitle: String
        /// Key in the Mac's favourites list (source key + id).
        let favoriteKey: String
        /// Context window in tokens, for the context-limit filter.
        let contextLength: Int?
        /// Router price in micro-USD per million tokens, for the price sort.
        let inputPrice: Int64?
        let outputPrice: Int64?
        /// Where an externally discovered local bundle came from. Always nil
        /// on Intel.
        let externalSource: String?
        /// `chat` or `image`. Only chat models until stage 6.
        let kind: String
        let edits: Bool
        /// How the Privacy Filter treats a run on this model. Nil until
        /// `W-privacy-filter`.
        let privacy: String?

        enum CodingKeys: String, CodingKey {
            case id, name, provider, source, vision, thinking, params, quantization, available, description, tab
            case kind, edits
            case privacy
            case tabTitle = "tab_title"
            case favoriteKey = "favorite_key"
            case contextLength = "context_length"
            case inputPrice = "input_price"
            case outputPrice = "output_price"
            case externalSource = "external_source"
        }
    }

    /// The picker's chat models, in its tabs (upstream's mapping).
    static func pickerModels(from allItems: [ModelPickerItem]) -> [PickerModelDTO] {
        let items = allItems.filter { $0.isLikelyChatCapable && $0.mediaModel == nil }
        let tabbed = items.groupedByTab().flatMap { tab in tab.models.map { (tab: tab, item: $0) } }
        return tabbed.map { entry -> PickerModelDTO in
            let (tab, item) = entry
            let source: String
            switch item.source {
            case .foundation: source = "foundation"
            case .local: source = "local"
            case .remote: source = "remote"
            }
            return PickerModelDTO(
                id: item.id,
                name: item.displayName,
                provider: item.source.displayName,
                source: source,
                vision: modelSupportsImages(modelId: item.id, pickerItems: allItems),
                thinking: ModelProfileRegistry.profile(for: item.id)?.thinkingOption != nil,
                params: item.parameterCount,
                quantization: item.quantization,
                available: source != "local",
                description: item.description,
                tab: tab.key,
                tabTitle: tab.title,
                favoriteKey: item.favoriteKey,
                contextLength: item.contextLength,
                inputPrice: item.inputPriceMicroPerMTok,
                outputPrice: item.outputPriceMicroPerMTok,
                externalSource: nil,
                kind: "chat",
                edits: false,
                privacy: nil
            )
        }
    }

    /// GET /models/picker — the chat models the Mac's composer picker lists,
    /// with display names and capability flags (§12). Owner-only.
    private func serveModelPicker(context: ChannelHandlerContext) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            var allItems = await MainActor.run { ModelPickerItemCache.shared.items }
            if allItems.isEmpty { allItems = await ModelPickerItemCache.shared.buildModelPickerItems() }
            let favorites = await MainActor.run { FavoriteModelsStore.shared.favoriteKeys }
            let models = Self.pickerModels(from: allItems)
            // One model at a time: one that can't be encoded (a NaN in its
            // numbers, say) is left out rather than the whole list going out
            // empty (upstream).
            let encoder = JSONEncoder.osaurusCanonical()
            let encoded = models.compactMap { model in
                (try? encoder.encode(model)).map { String(decoding: $0, as: UTF8.self) }
            }
            let favoritesJSON = (try? encoder.encode(favorites)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let json = #"{"favorites":"# + favoritesJSON + #","models":["# + encoded.joined(separator: ",") + "]}"
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    // MARK: - PUT /models/favorites

    private struct ModelFavoriteRequest: Decodable {
        let key: String
        let favorite: Bool
    }

    /// PUT /models/favorites — heart or unheart a model in the Mac's
    /// favourites, as the picker rows' heart does; answers with the list
    /// (§12.4). Owner-only.
    private func serveModelFavorite(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        guard let request = try? JSONDecoder().decode(ModelFavoriteRequest.self, from: requestBodyData()),
            !request.key.isEmpty
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {\"key\": \"…\", \"favorite\": true}"}"#)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let favorites: [String] = await MainActor.run {
                let store = FavoriteModelsStore.shared
                if request.favorite { store.add(request.key) } else { store.remove(request.key) }
                return store.favoriteKeys
            }
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(["favorites": favorites]))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"favorites":[]}"#
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    // MARK: - POST / PUT /models/options

    private struct ModelOptionsRequest: Decodable {
        let model: String
        /// PUT only: an option id from the snapshot, or `thinking`.
        let option: String?
        /// PUT only: a segment id or a bool; null resets to the default.
        let value: ModelOptionValue?

        private enum CodingKeys: String, CodingKey { case model, option, value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            option = try container.decodeIfPresent(String.self, forKey: .option)
            if let flag = try? container.decodeIfPresent(Bool.self, forKey: .value) {
                value = .bool(flag)
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .value) {
                value = .string(text)
            } else {
                value = nil
            }
        }
    }

    /// POST /models/options — a model's picker options (Thinking, effort,
    /// other profile options); PUT /models/options — store one of them, as
    /// the Mac composer's Model Options rows do. Both answer with the model's
    /// current options (§12.3). Owner-only.
    private func serveModelOptions(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        guard let request = try? JSONDecoder().decode(ModelOptionsRequest.self, from: requestBodyData()),
            !request.model.isEmpty,
            head.method != .PUT || request.option != nil
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {\"model\": \"…\"}"}"#)
            return
        }
        let isWrite = head.method == .PUT
        let eventLoop = context.eventLoop
        runRequestTask {
            // An image model has no chat options: a name that matches a chat
            // profile mustn't lend it any (upstream).
            let isImageModel = await MainActor.run {
                ModelPickerItemCache.shared.items.contains {
                    $0.id == request.model && $0.mediaModel != nil
                }
            }
            let outcome: (HTTPResponseStatus, String) = await MainActor.run {
                if isImageModel {
                    if isWrite { return (.notFound, #"{"error":"unknown_option"}"#) }
                    let empty = ModelOptionsSnapshot(model: request.model, thinking: nil, options: [])
                    return (.ok, (try? JSONEncoder.osaurusCanonical().encode(empty))
                        .map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"encoding_failed"}"#)
                }
                if isWrite, let option = request.option {
                    do {
                        try ModelOptionsSnapshot.apply(model: request.model, optionId: option, value: request.value)
                    } catch ModelOptionsSnapshot.ApplyError.unknownOption {
                        return (.notFound, #"{"error":"unknown_option"}"#)
                    } catch {
                        return (.badRequest, #"{"error":"invalid_value"}"#)
                    }
                }
                let snapshot = ModelOptionsSnapshot.make(for: request.model)
                guard let json = try? JSONEncoder.osaurusCanonical().encode(snapshot) else {
                    return (.internalServerError, #"{"error":"encoding_failed"}"#)
                }
                return (.ok, String(decoding: json, as: UTF8.self))
            }
            self.respondOnLoop(eventLoop, status: outcome.0, headers: self.jsonHeaders(), body: outcome.1)
        }
    }

    // MARK: - GET /credits/balance

    /// `GET /credits/balance` — read-only Osaurus Router credit balance for
    /// local tools (usage dashboards, menu bar apps). Osaurus signs the router
    /// request itself, so the caller never touches the wallet key. Loopback
    /// skips the global auth gate, so `LocalCreditsBalance.isAuthorized` is
    /// applied here: a verified master key, or the key-less loopback opt-in
    /// for non-browser callers (upstream).
    private func serveCreditsBalance(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let hasVerifiedMasterKey =
            stateRef.value.callerHasVerifiedAccessKey && stateRef.value.callerAccessKeyIsMaster
        let requestHasOrigin = head.headers.contains(name: "Origin")
        let eventLoop = context.eventLoop
        runRequestTask {
            let response: (status: Int, json: [String: Any])
            if LocalCreditsBalance.isAuthorized(
                callerHasVerifiedMasterKey: hasVerifiedMasterKey,
                allowsUnkeyedLoopbackSpend: OsaurusRouter.allowsUnkeyedLoopbackSpend,
                requestHasOrigin: requestHasOrigin
            ) {
                let result = await OsaurusRouterAccountService.shared.balanceForLocalAPI()
                response = LocalCreditsBalance.response(for: result)
            } else {
                response = (
                    403,
                    LocalCreditsBalance.error(
                        code: "credits_access_not_authorized",
                        message: LocalCreditsBalance.unauthorizedMessage
                    )
                )
            }
            let data = try? JSONSerialization.data(withJSONObject: response.json, options: .osaurusCanonical)
            let body = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
            self.respondOnLoop(
                eventLoop, status: HTTPResponseStatus(statusCode: response.status), headers: self.jsonHeaders(),
                body: body)
        }
    }
}
