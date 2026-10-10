//
//  IntelShellDiagnostics.swift
//  osaurus
//
//  W-agent-loop-tools (2026-10-10): upstream's shell diagnostics, verbatim
//  from `Tools/BuiltinSandboxTools.swift` (excluded on Intel: the rest of
//  that file is the VM sandbox, `INC-containers`). `shell_run` uses them for
//  its warnings. Replaces the old Intel stub that returned no warnings.
//  Re-sync by copying the block from `diagnosticWarnings` through the
//  install patterns; keep the "Intel:" edit.
//

import Foundation

/// Upstream `macHostPathPrefixes` (private in `BuiltinSandboxTools`).
private let macHostPathPrefixes = [
    "/Users/", "/Volumes/", "/Applications/", "/System/", "/Library/", "/private/",
]

/// Compute the per-call warning list for a foreground shell execution.
/// Two cases the model wants flagged:
///   - `exit 0 + empty stdout + empty stderr + pipeline / 2>/dev/null` →
///     loud "no output" warning. Pre-pipefail this was the silent
///     `head` masking pattern; with pipefail on we still surface the
///     warning because suppressed stderr (`2>/dev/null`) means any
///     genuine error is invisible to the model.
///   - `exit 141` → soft SIGPIPE note. Common and benign for
///     `cmd | head -n N` patterns where the upstream had more output;
///     captured stdout is still trustworthy.
///
/// Internal — shared by `SandboxExecTool` and `ShellRunTool` so both
/// tools speak the same vocabulary.
internal func diagnosticWarnings(
    command: String,
    exitCode: Int32,
    stdout: String,
    stderr: String,
    workingDirectory: String? = nil,
    sandboxInstallAvailable: Bool? = nil
) -> [String] {
    var warnings: [String] = []
    let suspiciousEmpty =
        exitCode == 0
        && stdout.isEmpty
        && stderr.isEmpty
        && (command.contains("|") || command.contains("2>/dev/null"))
    if suspiciousEmpty {
        warnings.append(
            "Command exited 0 but produced no output. If you used `2>/dev/null` "
                + "in a pipeline, the upstream error was suppressed — re-run without "
                + "it to see what failed. (Pipefail is on, so a real upstream failure "
                + "would have set a non-zero exit; this looks like genuine empty "
                + "output OR redirected stderr.)"
        )
    }
    if exitCode == 141 {
        warnings.append(
            "A pipeline stage was terminated by SIGPIPE (exit 141). Usually safe "
                + "when piping into `head -n N` and the upstream had more data; the "
                + "captured stdout is still trustworthy."
        )
    }
    // Intel: no `sandbox_install` (no VM, `INC-containers`) and no
    // `ToolExecutionScope`, so the installer is never callable.
    let canInstall = sandboxInstallAvailable ?? false
    if let hint = shellCommandFailureHint(
        command: command,
        exitCode: exitCode,
        stderr: stderr,
        sandboxInstallAvailable: canInstall
    ) {
        warnings.append(hint)
    }
    if let hint = sandboxExecHostPathHint(command: command, exitCode: exitCode, stderr: stderr) {
        warnings.append(hint)
    }
    if let workingDirectory,
        let hint = shellWorkingDirectoryHint(
            command: command,
            workingDirectory: workingDirectory
        )
    {
        warnings.append(hint)
    }
    return warnings
}

/// Trusted-folder shell commands already start at the selected workspace.
/// Catch the common model failure where it copies a truncated absolute path
/// into a leading `cd`, then runs verification in the wrong directory.
internal func shellWorkingDirectoryHint(
    command: String,
    workingDirectory: String
) -> String? {
    let pattern = #"^\s*cd\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s;&|]+))\s*(?:&&|;)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
            in: command,
            range: NSRange(command.startIndex..., in: command)
        )
    else { return nil }

    let target = (1 ... 3).compactMap { index -> String? in
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: command) else {
            return nil
        }
        return String(command[swiftRange])
    }.first
    guard let target, target.hasPrefix("/") else { return nil }

    let cwd = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
    let destination = URL(fileURLWithPath: target).standardizedFileURL.path
    if destination == cwd {
        return
            "`shell_run` already starts in the working directory `\(cwd)`. "
            + "Omit the leading `cd` and run the command directly."
    }
    guard !destination.hasPrefix(cwd + "/") else { return nil }
    let temporaryRoots = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
    if temporaryRoots.contains(where: {
        destination == $0 || destination.hasPrefix($0 + "/")
    }) {
        return nil
    }
    return
        "`shell_run` started in `\(cwd)`, but the command changed to `\(destination)`. "
        + "That leaves the selected workspace and can make builds or tests inspect the wrong files. "
        + "Omit the leading `cd` unless an out-of-workspace read is intentional."
}

/// Combined-mode backstop for the one read surface that can't be
/// path-routed: a raw `sandbox_exec` command (`ls`/`cat` a `/Users/...`
/// path) still hits the Linux sandbox, which has no copy of the host
/// workspace, so it fails or comes back empty. The unified `file_*` tools
/// cover everything else; this redirect catches the model that reached for
/// the shell anyway. Gated on combined mode + a macOS host path in the
/// command + a missing-file/empty signal so legitimate sandbox commands
/// are never nagged.
internal func sandboxExecHostPathHint(
    command: String,
    exitCode: Int32,
    stderr: String
) -> String? {
    guard ChatExecutionContext.hostReadOnlyScope != nil else { return nil }
    guard macHostPathPrefixes.contains(where: { command.contains($0) }) else { return nil }
    let lowered = stderr.lowercased()
    let looksMissing =
        exitCode != 0
        && (lowered.contains("no such file")
            || lowered.contains("not found")
            || lowered.contains("cannot access")
            || lowered.isEmpty)
    guard looksMissing else { return nil }
    return
        "That path looks like a host path outside the sandbox, which it can't "
        + "see. To read your read-only host workspace, use `file_read` "
        + "(reads files, lists directories) / `file_search` — not `shell_run`."
}

/// Lowercased stderr fragments that mark a shell-parse failure (as
/// opposed to an in-script runtime error). Matched case-insensitively.
private let shellParseSignatures = [
    "syntax error", "unexpected token", "unexpected eof", "unexpected end of file",
]

/// An interpreter followed by an inline-code flag — `python3 -c`,
/// `node -e`, `bash -c`, `sh -c`, `perl -e`, `ruby -e` — with flexible
/// whitespace. The signal that a command tried to inline a script.
private let interpreterInlineCodePattern = #"\b(python3?|node|bash|sh|perl|ruby)\s+-[ce]\b"#

/// Map a failed `sandbox_exec` to an actionable recovery hint for the
/// most common ways a local model mangles the `command` string. Returns
/// the single most-specific hint (branches are checked in priority order
/// so hints never stack or contradict), or nil when the failure isn't a
/// recognized shape — a raw runtime error or a syntax error the model
/// should just fix itself gets no hint.
///
/// Shapes, most-specific first:
///   1. Multi-line code mis-escaped into an interpreter `-c`/`-e` string.
///   2. Unterminated heredoc (`<<EOF` never closed).
///   3. Unbalanced / stray quote (the shell never found a closing quote).
public func shellCommandFailureHint(
    command: String,
    exitCode: Int32,
    stderr: String,
    sandboxInstallAvailable: Bool = false
) -> String? {
    guard exitCode != 0 else { return nil }
    let loweredStderr = stderr.lowercased()

    // Checked first: failed package-manager commands have a mode-aware
    // recovery path. In VM mode the dedicated installer is safer; in trusted
    // folder mode that tool is not callable, so only correct self-truncated
    // diagnostics instead of naming an unavailable function.
    if let hint = installFailureHint(
        command: command,
        sandboxInstallAvailable: sandboxInstallAvailable
    ) {
        return hint
    }
    if let hint = inlineCodeHint(command: command, stderr: loweredStderr) {
        return hint
    }
    if let hint = heredocHint(stderr: loweredStderr) {
        return hint
    }
    if let hint = unbalancedQuoteHint(stderr: loweredStderr) {
        return hint
    }
    return nil
}

/// Multi-line script embedded in a shell `-c` / `-e` string (e.g.
/// `python3 -c "…"`) whose escaping broke, so the shell mis-parsed the
/// code body. Requires BOTH a shell-parse signature AND an interpreter
/// inline-code flag, so a clean one-liner (`python3 -c 'print(1)'`) and
/// an in-script runtime error (`Traceback`) both stay silent.
private func inlineCodeHint(command: String, stderr loweredStderr: String) -> String? {
    guard shellParseSignatures.contains(where: { loweredStderr.contains($0) }) else { return nil }
    guard
        let regex = try? NSRegularExpression(pattern: interpreterInlineCodePattern, options: [.caseInsensitive]),
        regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    else { return nil }

    return
        "This looks like multi-line code embedded in a shell `-c` / `-e` "
        + "string whose escaping broke — the shell tried to parse your code "
        + "as commands (hence the syntax error). Don't re-escape it. "
        + "Use `file_write` to save the script (no shell escaping), "
        + "then `shell_run` to run that file (e.g. `python3 script.py`)."
}

/// Unterminated heredoc: the `<<DELIM` body was never closed, so the
/// shell read to end-of-input. bash surfaces this as a `here-document …
/// delimited by end-of-file` warning.
private func heredocHint(stderr loweredStderr: String) -> String? {
    guard
        loweredStderr.contains("here-document"),
        loweredStderr.contains("delimited by end-of-file") || loweredStderr.contains("unexpected eof")
    else { return nil }

    return
        "This looks like an unterminated heredoc — the `<<` delimiter was "
        + "never closed, so the shell read to end-of-input. For multi-line "
        + "file content, prefer `file_write` to create the file "
        + "directly instead of a shell heredoc."
}

/// Unbalanced / stray quote: the shell hit end-of-input still looking for
/// a closing quote (`bash: unexpected EOF while looking for matching `'`).
/// The common slip is wrapping the whole command in a quote.
private func unbalancedQuoteHint(stderr loweredStderr: String) -> String? {
    guard loweredStderr.contains("unexpected eof while looking for matching") else { return nil }

    // bash echoes the quote it wanted as the trailing token, e.g.
    // ``matching `"'`` (double) vs ``matching `''`` (single). Default to
    // single when we can't tell — it's the more common slip.
    let quote = loweredStderr.contains("matching `\"") ? "\"" : "'"
    return
        "Your command has an unbalanced \(quote) quote — the shell reached "
        + "end-of-input still looking for the closing \(quote). Check for a "
        + "stray or unclosed quote (a common slip is wrapping the WHOLE "
        + "command in quotes; pass it verbatim and quote only the arguments "
        + "that need it). For code or data with awkward quoting, "
        + "`file_write` avoids shell quoting entirely."
}

/// A bare package-manager install run directly through `sandbox_exec`
/// (e.g. `apk add curl`, `pip install numpy`, `npm install express`) that
/// failed. These skip the dedicated `sandbox_install` tool's index
/// refresh, venv/workspace bootstrap, retry harness, and per-agent
/// serialization — `apk` always fails unprivileged, and bare pip/npm are
/// exactly what produced the historical venv/`idealTree` breakages. Redirect
/// the model to `sandbox_install` with the matching `manager`.
///
/// Matched at a statement boundary (start, or after `&&` / `||` / `;` / `|`)
/// so an install string buried in an argument doesn't false-fire, and only
/// on failure (`shellCommandFailureHint` already gates on a non-zero exit)
/// so a working install is never nagged.
private func installFailureHint(
    command: String,
    sandboxInstallAvailable: Bool
) -> String? {
    func matches(_ pattern: String) -> Bool {
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        return regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    let manager: String
    if matches(apkInstallPattern) {
        manager = "apk"
    } else if matches(pipInstallPattern) {
        manager = "pip"
    } else if matches(npmInstallPattern) {
        manager = "npm"
    } else {
        return nil
    }

    if sandboxInstallAvailable {
        return
            "This is a bare `\(manager)` install run through `shell_run`, which skips the "
            + "index refresh / venv / workspace bootstrap, retry harness, and per-agent "
            + "serialization (and `apk` needs root). Use `sandbox_install` with "
            + "`manager: \"\(manager)\"` and a `packages` array instead — e.g. "
            + "`{\"manager\": \"\(manager)\", \"packages\": [\"…\"]}`."
    }

    let truncated =
        matches(#"\|\s*(?:head|tail)\b"#)
        || matches(#"\|\s*sed\s+-n\b"#)
    guard truncated else { return nil }
    return
        "This failed `\(manager)` install truncated its own output with `head`, `tail`, or "
        + "`sed -n`, hiding the root error. Re-run the same host/project install without "
        + "that truncation and inspect the complete stdout/stderr. `sandbox_install` is not "
        + "callable in this request."
}

/// Statement-boundary prefix shared by the install detectors: start of
/// string or immediately after a shell separator, with optional `sudo`.
private let installStatementBoundary = #"(?:^|&&|\|\||;|\|)\s*(?:sudo\s+)?"#
private let apkInstallPattern = installStatementBoundary + #"apk\s+add\b"#
private let pipInstallPattern =
    installStatementBoundary + #"(?:pip3?|python3?\s+-m\s+pip)\s+install\b"#
private let npmInstallPattern =
    installStatementBoundary + #"(?:npm\s+(?:install|i|add)|yarn\s+add|pnpm\s+(?:add|install))\b"#
