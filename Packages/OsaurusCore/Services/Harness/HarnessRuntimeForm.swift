//
//  HarnessRuntimeForm.swift
//  osaurus
//
//  The pure parts of Settings > Agent Runtimes (#3175): parsing the editor's
//  arguments and environment text, and the Test button's bookkeeping. Split
//  from the views so tests run them with a fake probe: nothing here starts a
//  process by itself; only `HarnessRuntimeTester.run` does, through the probe
//  it is given, and only when the user presses Test or Sign In.
//

import Foundation

enum HarnessRuntimeForm {
    /// One argument per line; blank lines dropped.
    static func parseArguments(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A Pi runtime without `--mode rpc` only works if the command starts in
    /// RPC mode on its own; warn instead of refusing (upstream).
    static func argumentWarning(kind: HarnessKind, arguments args: [String]) -> String? {
        guard kind == .piRPC else { return nil }
        if let index = args.firstIndex(of: "--mode"), args.indices.contains(index + 1), args[index + 1] == "rpc" {
            return nil
        }
        if args.contains("--mode=rpc") { return nil }
        return L(
            "The arguments don't include --mode rpc. That's fine only if this command starts in RPC mode on its own.")
    }

    /// `KEY=value` lines. `OSAURUS_*` is reserved for the contract Osaurus
    /// sets itself; comments (`#`) and blank lines are skipped.
    static func parseEnvironment(_ text: String) -> (values: [String: String], errors: [String]) {
        var values: [String: String] = [:]
        var errors: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else {
                errors.append(String(format: L("\"%@\" isn't KEY=value."), line))
                continue
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            let validKey =
                !key.isEmpty && key.first.map { $0 == "_" || $0.isLetter } == true
                && key.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
            guard validKey else {
                errors.append(String(format: L("\"%@\" isn't a valid variable name."), key))
                continue
            }
            if key.uppercased().hasPrefix("OSAURUS_") {
                errors.append(String(format: L("%@ is set by Osaurus and can't be overridden."), key))
                continue
            }
            values[key] = value
        }
        return (values, errors)
    }
}

/// The Test button's state: which runtimes are being probed and the last
/// result of each. The probe is injectable; the default is the real one.
@MainActor
final class HarnessRuntimeTester: ObservableObject {
    @Published private(set) var testing: Set<UUID> = []
    @Published private(set) var results: [UUID: HarnessProbeResult] = [:]

    private let probe: @Sendable (HarnessRuntime) async -> HarnessProbeResult

    init(
        probe: @escaping @Sendable (HarnessRuntime) async -> HarnessProbeResult = { runtime in
            await HarnessRuntimeProbe.run(runtime)
        }
    ) {
        self.probe = probe
    }

    func isTesting(_ id: UUID) -> Bool { testing.contains(id) }

    func clear(_ id: UUID) { results[id] = nil }

    /// Starts one probe per runtime at a time (a second press while one is
    /// running does nothing). Returns the task so tests can await it.
    @discardableResult
    func run(_ runtime: HarnessRuntime) -> Task<Void, Never>? {
        guard !testing.contains(runtime.id) else { return nil }
        testing.insert(runtime.id)
        results[runtime.id] = nil
        let probe = probe
        return Task { [weak self] in
            let result = await probe(runtime)
            self?.testing.remove(runtime.id)
            self?.results[runtime.id] = result
        }
    }
}
