//
//  IntelXAICredentials.swift
//  OsaurusCore
//
//  xAI (SuperGrok) OAuth token refresh before each request. Upstream's
//  `RemoteProviderService.refreshXAIOAuthIfNeeded` / `xaiOAuthHeaders`,
//  shaped like `IntelCodexCredentials` (Intel's engine has no per-provider
//  service object to cache the tokens in).
//

import Foundation

/// Resolves saved xAI OAuth tokens per provider, refreshing an expired access
/// token once (shared in-flight) and persisting the result. A permanent
/// refresh failure (`invalid_grant` / 401) is reported through
/// `onPermanentFailure` so the manager can clear the dead tokens and flag the
/// provider as needing sign-in.
actor IntelXAICredentials {
    static let shared = IntelXAICredentials()

    private let load: @Sendable (UUID) async -> RemoteProviderOAuthTokens?
    private let refresh: @Sendable (RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens
    private let save: @Sendable (RemoteProviderOAuthTokens, UUID) async -> Bool
    private let onPermanentFailure: @Sendable (UUID) async -> Void
    private var inFlight: [UUID: Task<RemoteProviderOAuthTokens, Error>] = [:]

    init(
        load: @escaping @Sendable (UUID) async -> RemoteProviderOAuthTokens? = { providerId in
            await RemoteProviderKeychain.runOffCooperativeExecutor {
                RemoteProviderKeychain.getOAuthTokens(for: providerId)
            }
        },
        refresh: @escaping @Sendable (RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens = { tokens in
            try await XAIOAuthService.refresh(tokens)
        },
        save: @escaping @Sendable (RemoteProviderOAuthTokens, UUID) async -> Bool = { tokens, providerId in
            await RemoteProviderKeychain.saveOAuthTokensOffMainActor(tokens, for: providerId)
        },
        onPermanentFailure: @escaping @Sendable (UUID) async -> Void = { providerId in
            await MainActor.run {
                RemoteProviderManager.shared.handlePermanentOAuthFailure(providerId: providerId)
            }
        }
    ) {
        self.load = load
        self.refresh = refresh
        self.save = save
        self.onPermanentFailure = onPermanentFailure
    }

    func tokens(for providerId: UUID) async throws -> RemoteProviderOAuthTokens {
        if let task = inFlight[providerId] {
            return try await task.value
        }
        let task = Task { [load, refresh, save, onPermanentFailure] () throws -> RemoteProviderOAuthTokens in
            guard let current = await load(providerId) else { throw XAIOAuthError.missingSignInTokens }
            guard current.isExpired else { return current }
            let refreshed: RemoteProviderOAuthTokens
            do {
                refreshed = try await refresh(current)
            } catch {
                if RemoteProviderManager.isPermanentOAuthFailure(error) {
                    await onPermanentFailure(providerId)
                }
                throw error
            }
            // A failed save still lets this request use the fresh token.
            _ = await save(refreshed, providerId)
            return refreshed
        }
        inFlight[providerId] = task
        defer { inFlight.removeValue(forKey: providerId) }
        return try await task.value
    }
}
