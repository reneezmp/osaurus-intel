import Foundation

/// Friendly, classified chat error text (upstream Classic `ChatErrorMessages`,
/// stage 5c row 13). Intel ports the Router out-of-credits branch only:
/// - the workspace branches (pool dry, stale billing, subscription inactive)
///   belong to `W-workspaces-sharing` (deferred; no `WorkspacesService` here),
///   so a workspace 402 keeps its raw text;
/// - the system-resources branch is local MLX only (Intel is cloud-only).
enum ChatErrorMessages {
    static func assistantMessage(for error: Error) -> String {
        let description = error.localizedDescription
        // Upstream's text, verbatim (not localized upstream either).
        if OsaurusRouter.isInsufficientFundsError(description) {
            return "Error: You're out of credits. Add credits to continue."
        }
        return "Error: \(description)"
    }
}
