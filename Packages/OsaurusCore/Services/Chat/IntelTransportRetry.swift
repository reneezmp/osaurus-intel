//
//  IntelTransportRetry.swift
//  osaurus
//
//  `W-cov-reaudit` stage 5c slice 6 (rows 11 and 12): the transport-level
//  recovery upstream Classic keeps in `RemoteProviderService` and `ChatView`,
//  for Intel's `ChatEngine` (which replaces `RemoteProviderService` for chat):
//
//  - `connectWithRetry`: a transient connect failure (TCP / DNS / TLS) is
//    retried with 200 ms and 800 ms backoff before any byte has arrived.
//  - 429 (and 503 with a `Retry-After`) become `CloudChatError.rateLimited`
//    with upstream's "Retry in about Ns" text.
//  - Tool-call arguments cut off mid-stream (invalid JSON) are quarantined
//    instead of run; the chat retries the round twice, uncharged, only while
//    nothing has been shown yet.
//
//  A retried request keeps its Router `idempotency_key` (same body, same
//  round), so the Router dedupes it and never bills twice.
//

import Foundation

enum IntelTransportRetry {
    /// Upstream `ChatView.maxTransientRetries`.
    static let maxTransientRetries = 2

    /// Upstream `RemoteProviderService.connectWithRetry`: three attempts,
    /// 200 ms then 800 ms apart. Only the connect phase is retried: once the
    /// response head arrives, the caller owns the stream. Intel's engine owns
    /// its `URLSession` and never invalidates it mid-request, so upstream's
    /// `isCancelled` hook is not needed.
    static func connectWithRetry(
        session: URLSession,
        urlRequest: URLRequest,
        maxAttempts: Int = 3,
        backoffNanoseconds: [UInt64] = [200_000_000, 800_000_000]
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var lastError: Error?
        for attempt in 0 ..< maxAttempts {
            if attempt > 0 {
                let delay = backoffNanoseconds[min(attempt - 1, backoffNanoseconds.count - 1)]
                try? await Task.sleep(nanoseconds: delay)
            }
            if Task.isCancelled { throw lastError ?? CancellationError() }
            do {
                return try await session.bytes(for: urlRequest)
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                // Only classic transient categories; auth / bad-request /
                // cancelled errors go straight to the caller.
                guard isRetryableConnectError(error) else { throw error }
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    /// Upstream `isRetryableConnectError`.
    static func isRetryableConnectError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
            .secureConnectionFailed, .serverCertificateUntrusted,
            .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// A drop in the middle of a stream that is worth one more try while
    /// nothing has been shown: the link went away or went silent.
    static func isTransientStreamDrop(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .networkConnectionLost || urlError.code == .timedOut
    }

    /// Upstream `RemoteProviderServiceError.rateLimited(from:)`: 429 always
    /// qualifies; 503 only with a `Retry-After` hint (a plain 503 stays an
    /// ordinary HTTP error so real outages read as failures).
    static func rateLimited(from response: HTTPURLResponse) -> CloudChatError? {
        let retryAfter = parseRetryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"))
        switch response.statusCode {
        case 429:
            return .rateLimited(retryAfter: retryAfter, statusCode: 429)
        case 503 where retryAfter != nil:
            return .rateLimited(retryAfter: retryAfter, statusCode: 503)
        default:
            return nil
        }
    }

    /// Upstream `parseRetryAfterSeconds`: delta-seconds or an HTTP-date; nil
    /// when absent, unparseable or not in the future.
    static func parseRetryAfterSeconds(_ headerValue: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return seconds > 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            let delta = date.timeIntervalSince(now)
            return delta > 0 ? delta : nil
        }
        return nil
    }

    /// Upstream `validateToolCallJSON(...).wasRepaired`: streamed arguments
    /// that are not valid JSON mean the stream was cut mid-argument (or the
    /// model wrote broken JSON); empty arguments are valid (no-argument tool).
    static func argumentsAreMalformed(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8) else { return true }
        return (try? JSONSerialization.jsonObject(with: data)) == nil
    }
}
