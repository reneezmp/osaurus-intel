//
//  IntelBuildInfo.swift
//  OsaurusCore (Intel fork)
//
//  Build-identity metadata for the Intel fork.
//
//  The fork keeps its OWN, independent version line
//  (`CFBundleShortVersionString`, e.g. 1.0.x) — that number describes THIS
//  build's user-facing state. These constants surface the upstream-sync
//  correspondence as *metadata* (shown in the About panel + release notes),
//  NOT as the version number. We deliberately do not peg the release number to
//  upstream's, because the fork amputates whole subsystems (MLX, voice,
//  sandbox, Vectura) and skips amputated/Tahoe-only commits — so a pegged
//  number would imply a parity we don't have.
//
//  ⚠️ SINGLE SOURCE OF TRUTH. Update these two values whenever you run an
//  upstream sync, in lockstep with `docs/UPSTREAM_SYNC.md`. The release script
//  (`scripts/release/cut_intel_release.sh`) greps `upstreamBase` from this file
//  to stamp the release notes, so this is the only place the number lives.
//

#if OSAURUS_INTEL
import Foundation

enum IntelBuildInfo {
    /// The upstream Osaurus version era this build is synced to (display only).
    static let upstreamBase = "0.19.15"

    /// The exact upstream commit last synced (short hash) — matches the
    /// "Last synced upstream commit" line in `docs/UPSTREAM_SYNC.md`.
    static let upstreamCommit = "d132b728"
}
#endif
