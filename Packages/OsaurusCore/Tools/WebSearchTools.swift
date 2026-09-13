//
//  WebSearchTools.swift
//  osaurus
//
//  Native web-search tool surface — exactly two tools, tuned for both local
//  and frontier callers:
//
//    - `web_search` — always-loaded baseline built-in. One required param
//      (`query`); optional `category` whose enum is generated from what the
//      user's enabled providers actually support (omitted entirely when only
//      web search is available).
//    - `search_and_extract` — dynamic built-in (loaded via capabilities);
//      search plus Readability extraction of the top results.
//
//  Weak-caller contract: never fail the call over a malformed argument.
//  Unknown categories fall back to web with a warning, string numbers are
//  accepted, time-range variants are normalized, unknown fields are ignored.
//

import Foundation

// MARK: - Shared argument sanitization

enum WebSearchArgs {
    /// Canonicalize a time-range value: "d"/"day" -> "d", "week" -> "w", etc.
    /// Invalid values return nil and append a warning.
    static func sanitizeTimeRange(_ raw: Any?, warnings: inout [String]) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty
        else { return nil }
        switch s {
        case "d", "day": return "d"
        case "w", "week": return "w"
        case "m", "month": return "m"
        case "y", "year": return "y"
        default:
            warnings.append("Ignored invalid time_range '\(s)'; expected d, w, m, or y.")
            return nil
        }
    }

    /// Validate a region code ("xx-yy"). Invalid values return nil + warning.
    static func sanitizeRegion(_ raw: Any?, warnings: inout [String]) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.range(of: "^[A-Za-z]{2}-[A-Za-z]{2}$", options: .regularExpression) != nil {
            return s.lowercased()
        }
        warnings.append("Ignored invalid region '\(s)'; expected format 'xx-yy' (e.g. 'us-en').")
        return nil
    }

    /// Resolve a requested category against what's actually available.
    /// Unknown categories fall back to web with a warning instead of erroring.
    static func sanitizeCategory(
        _ raw: Any?,
        available: [String],
        warnings: inout [String]
    ) -> String {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty
        else { return SearchCategory.web }
        if available.contains(s) { return s }
        // Common synonyms local models produce.
        let synonyms: [String: String] = [
            "websearch": SearchCategory.web, "general": SearchCategory.web,
            "article": SearchCategory.news, "articles": SearchCategory.news,
            "image": SearchCategory.images, "img": SearchCategory.images,
            "photo": SearchCategory.images, "photos": SearchCategory.images,
        ]
        if let mapped = synonyms[s], available.contains(mapped) { return mapped }
        warnings.append(
            "Ignored unknown category '\(s)'; searched the web instead. "
                + "Available: \(available.joined(separator: ", ")).")
        return SearchCategory.web
    }

    static func optionalTrimmedString(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return s
    }
}

// MARK: - Result formatting

enum WebSearchResultFormatter {
    /// Cap snippet length so local models don't drown in tokens; frontier
    /// callers still get the full structure.
    static let maxSnippetLength = 400

    static func resultsPayload(
        request: SearchRequest,
        outcome: SearchEngineOutcome
    ) -> [String: Any] {
        var out: [String: Any] = [
            "query": request.query,
            "category": request.category,
            "provider": outcome.provider ?? "",
            "results": outcome.hits.enumerated().map { index, hit -> [String: Any] in
                var d = hit.toDict(rank: index + 1)
                if let snippet = d["snippet"] as? String, snippet.count > maxSnippetLength {
                    d["snippet"] = String(snippet.prefix(maxSnippetLength)) + "…"
                }
                return d
            },
            "count": outcome.hits.count,
        ]
        if outcome.hits.count == request.maxResults {
            out["next_offset"] = request.offset + request.maxResults
        }
        return out
    }

    /// Actionable hint for a NO_RESULTS failure — differs depending on
    /// whether any API provider is configured, since "add a provider" is
    /// useless advice when the user already has one and it just failed.
    static func noResultsHint(hasConfiguredAPIProvider: Bool) -> String {
        if hasConfiguredAPIProvider {
            return
                "Tried the configured providers and free fallbacks. Try a broader query, "
                + "or check in Settings → Search that the API keys are still valid."
        }
        return
            "Try a broader query or drop site:/filetype:/time_range. For better results, "
            + "add a free search provider in Settings → Search."
    }

    static func applySourceMetadata(_ payload: inout [String: Any], run: HostedFirstSearchResult) {
        payload["search_source"] = run.source.rawValue
        if let reason = run.hostedFallbackReason { payload["premium_fallback"] = reason }
    }

    static func noResultsFailure(
        tool: String,
        request: SearchRequest,
        outcome: SearchEngineOutcome,
        warnings: [String],
        hasConfiguredAPIProvider: Bool
    ) -> String {
        var metadata: [String: Any] = [
            "query": request.query,
            "attempts": outcome.attempts.map { $0.toDict() },
            "hint": noResultsHint(hasConfiguredAPIProvider: hasConfiguredAPIProvider),
        ]
        if !warnings.isEmpty { metadata["warnings"] = warnings }
        return ToolEnvelope.failure(
            kind: .executionError,
            message: "No results from any search provider.",
            tool: tool,
            retryable: true,
            metadata: metadata
        )
    }
}

// MARK: - web_search

final class WebSearchTool: OsaurusTool, @unchecked Sendable {
    let name = "web_search"
    let description =
        "Search the web. Just pass `query`; results come from the user's configured "
        + "search providers with automatic fallback. Returns ranked results with "
        + "title, url, and snippet."

    // Immutable because this baseline schema is part of the prompt prefix.
    // Execution validates category against the current provider set.
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Plain-language search query."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("How many results (1-50). Default 10."),
            ]),
            "time_range": .object([
                "type": .string("string"),
                "enum": .array([.string("d"), .string("w"), .string("m"), .string("y")]),
                "description": .string("Recency: d=day, w=week, m=month, y=year. Omit for any time."),
            ]),
            "site": .object([
                "type": .string("string"),
                "description": .string("Restrict to a domain (e.g. 'arxiv.org')."),
            ]),
            "filetype": .object([
                "type": .string("string"),
                "description": .string("Restrict to a file type (e.g. 'pdf')."),
            ]),
            "offset": .object([
                "type": .string("integer"),
                "description": .string("Pagination offset. Default 0."),
            ]),
            "region": .object([
                "type": .string("string"),
                "description": .string("Region code 'xx-yy' (e.g. 'us-en'). Omit for global."),
            ]),
            "category": .object([
                "type": .string("string"),
                "description": .string(
                    "What to search: web (default), news, images, or a provider-specific category. "
                        + "Unsupported values fall back to web."),
            ]),
        ]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let queryReq = requireString(args, "query", expected: "non-empty search query", tool: name)
        guard case .value(let queryRaw) = queryReq else { return queryReq.failureEnvelope ?? "" }
        let query = queryRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `query` must not be whitespace-only.",
                field: "query",
                expected: "non-empty search query",
                tool: name
            )
        }

        var warnings: [String] = []
        let available = await SearchProviderManager.shared.availableCategories()
        let category = WebSearchArgs.sanitizeCategory(
            args["category"], available: available, warnings: &warnings)
        let timeRange = WebSearchArgs.sanitizeTimeRange(args["time_range"], warnings: &warnings)
        let region = WebSearchArgs.sanitizeRegion(args["region"], warnings: &warnings)
        let maxCap = category == SearchCategory.images ? 100 : 50
        let defaultMax = category == SearchCategory.images ? 20 : 10
        let maxResults = max(1, min(ArgumentCoercion.int(args["max_results"]) ?? defaultMax, maxCap))
        let offset = max(0, ArgumentCoercion.int(args["offset"]) ?? 0)

        let request = SearchRequest(
            query: query,
            category: category,
            maxResults: maxResults,
            offset: offset,
            site: WebSearchArgs.optionalTrimmedString(args["site"]),
            filetype: WebSearchArgs.optionalTrimmedString(args["filetype"]),
            // News defaults to the last week so stale results don't read as news.
            timeRange: timeRange ?? (category == SearchCategory.news ? "w" : nil),
            region: region
        )

        let run = await SearchProviderManager.shared.runHostedFirstSearch(
            request, idempotencyKey: UUID().uuidString)
        let outcome = run.outcome
        if outcome.hits.isEmpty {
            let hasAPIProvider = await SearchProviderManager.shared.hasConfiguredAPIProvider
            return WebSearchResultFormatter.noResultsFailure(
                tool: name,
                request: request,
                outcome: outcome,
                warnings: warnings,
                hasConfiguredAPIProvider: hasAPIProvider
            )
        }
        var payload = WebSearchResultFormatter.resultsPayload(request: request, outcome: outcome)
        WebSearchResultFormatter.applySourceMetadata(&payload, run: run)
        return ToolEnvelope.success(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }
}

// MARK: - search_and_extract

final class SearchAndExtractTool: OsaurusTool, @unchecked Sendable {
    let name = "search_and_extract"
    let description =
        "Fetch a specific URL or search the web and extract page content as markdown. "
        + "After web_search, pass the selected result in `url`; use `query` only when no URL is known."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Plain-language search query. Use only when no URL is known."),
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string("Direct http(s) page URL to fetch."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("How many search results (1-20). Default 5."),
            ]),
            "extract_count": .object([
                "type": .string("integer"),
                "description": .string("How many of the top results to extract. Default 3."),
            ]),
            "time_range": .object([
                "type": .string("string"),
                "enum": .array([.string("d"), .string("w"), .string("m"), .string("y")]),
                "description": .string("Recency filter."),
            ]),
            "site": .object([
                "type": .string("string"),
                "description": .string("Restrict to a domain."),
            ]),
            "filetype": .object([
                "type": .string("string"),
                "description": .string("Restrict to a file type."),
            ]),
            "timeout": .object([
                "type": .string("number"),
                "description": .string("Per-page extraction timeout in seconds. Default 25."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let directURL = WebSearchArgs.optionalTrimmedString(args["url"])
        let query = WebSearchArgs.optionalTrimmedString(args["query"])
        guard directURL != nil || query != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Provide a direct `url` or a non-empty `query`.",
                expected: "url or query",
                tool: name
            )
        }

        var warnings: [String] = []
        let timeRange = WebSearchArgs.sanitizeTimeRange(args["time_range"], warnings: &warnings)
        let maxResults = max(1, min(ArgumentCoercion.int(args["max_results"]) ?? 5, 20))
        let extractCount = max(1, min(ArgumentCoercion.int(args["extract_count"]) ?? 3, maxResults))
        let timeout: TimeInterval = {
            if let n = args["timeout"] as? NSNumber { return n.doubleValue }
            if let s = args["timeout"] as? String, let d = Double(s) { return d }
            return 25
        }()

        if let directURL {
            // Never disclose an obvious or DNS-resolved private target to the
            // hosted extractor. The local fallback repeats this check and
            // also rejects unsafe redirects.
            var hostedText: (title: String?, text: String)?
            if SearchHTML.resolvedUnsafeExtractionURLReason(directURL) == nil,
               let hosted = await SearchProviderManager.shared.hostedExtract(
                    urls: [directURL], idempotencyKey: UUID().uuidString),
               !hosted.replayed,
               let page = hosted.pages.first(where: { $0.succeeded }),
               let text = page.text, !text.isEmpty
            {
                hostedText = (page.title, text)
            }

            var entry = SearchHit(
                title: hostedText?.title ?? directURL,
                url: directURL,
                snippet: "",
                engine: "direct_url"
            ).toDict(rank: 1)
            if let hostedText {
                let bounded = SearchDiagnostics.truncate(
                    hostedText.text, maxCharacters: SearchReadability.maxMarkdownCharacters)
                entry["extract_status"] = SearchExtractionStatus.ok.rawValue
                entry["word_count"] = bounded.text.split(whereSeparator: \.isWhitespace).count
                entry["extracted"] = true
                entry["markdown"] = bounded.text
                entry["truncated"] = bounded.truncated
                entry["extract_source"] = "premium"
            } else {
                let extraction = await SearchReadability.extract(url: directURL, timeout: timeout)
                if let title = extraction.title, !title.isEmpty { entry["title"] = title }
                if let canonicalURL = extraction.canonicalURL, !canonicalURL.isEmpty {
                    entry["canonical_url"] = canonicalURL
                }
                entry["extract_status"] = extraction.status.rawValue
                entry["word_count"] = extraction.wordCount
                entry["extracted"] = extraction.extracted
                if extraction.extracted {
                    entry["markdown"] = extraction.markdown
                    entry["truncated"] = extraction.truncated
                } else if let message = extraction.message, !message.isEmpty {
                    entry["extract_error"] = message
                }
            }
            return ToolEnvelope.success(
                tool: name,
                result: ["mode": "direct_url", "provider": "direct_url", "results": [entry]]
            )
        }

        let request = SearchRequest(
            query: query ?? "",
            category: SearchCategory.web,
            maxResults: maxResults,
            site: WebSearchArgs.optionalTrimmedString(args["site"]),
            filetype: WebSearchArgs.optionalTrimmedString(args["filetype"]),
            timeRange: timeRange
        )

        let run = await SearchProviderManager.shared.runHostedFirstSearch(
            request,
            idempotencyKey: UUID().uuidString,
            extractTextMaxCharacters: SearchReadability.maxMarkdownCharacters
        )
        let outcome = run.outcome
        if outcome.hits.isEmpty {
            let hasAPIProvider = await SearchProviderManager.shared.hasConfiguredAPIProvider
            return WebSearchResultFormatter.noResultsFailure(
                tool: name,
                request: request,
                outcome: outcome,
                warnings: warnings,
                hasConfiguredAPIProvider: hasAPIProvider
            )
        }

        var payload = WebSearchResultFormatter.resultsPayload(request: request, outcome: outcome)
        var enriched: [[String: Any]] = []
        for (index, hit) in outcome.hits.enumerated() {
            var entry = hit.toDict(rank: index + 1)
            let shouldExtract = index < extractCount && !hit.url.isEmpty && !Task.isCancelled
            if shouldExtract, let hostedText = run.hostedTextByURL[hit.url.lowercased()], !hostedText.isEmpty {
                let bounded = SearchDiagnostics.truncate(
                    hostedText, maxCharacters: SearchReadability.maxMarkdownCharacters)
                entry["extract_status"] = SearchExtractionStatus.ok.rawValue
                entry["word_count"] = bounded.text.split(whereSeparator: \.isWhitespace).count
                entry["extracted"] = true
                entry["markdown"] = bounded.text
                entry["truncated"] = bounded.truncated
                entry["extract_source"] = "premium"
                enriched.append(entry)
                continue
            }
            if shouldExtract {
                let extraction = await SearchReadability.extract(url: hit.url, timeout: timeout)
                if let title = extraction.title, !title.isEmpty { entry["title"] = title }
                if let canonicalURL = extraction.canonicalURL, !canonicalURL.isEmpty {
                    entry["canonical_url"] = canonicalURL
                }
                entry["extract_status"] = extraction.status.rawValue
                entry["word_count"] = extraction.wordCount
                if let total = extraction.totalWordCount {
                    entry["word_count_total"] = total
                }
                entry["extracted"] = extraction.extracted
                if extraction.extracted {
                    entry["markdown"] = extraction.markdown
                    entry["truncated"] = extraction.truncated
                    if let byline = extraction.byline { entry["byline"] = byline }
                    if let lang = extraction.lang { entry["lang"] = lang }
                } else if let message = extraction.message, !message.isEmpty {
                    entry["extract_error"] = message
                }
            } else {
                entry["extracted"] = false
                if Task.isCancelled { entry["extract_status"] = SearchExtractionStatus.cancelled.rawValue }
            }
            enriched.append(entry)
        }
        payload["results"] = enriched
        WebSearchResultFormatter.applySourceMetadata(&payload, run: run)

        return ToolEnvelope.success(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }
}
