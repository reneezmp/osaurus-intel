//
//  IntelToolIndexService.swift
//  osaurus
//
//  Intel stand-in for the two read-only exposure methods of upstream's
//  `ToolIndexService` (excluded on Intel with its tool-index database) that
//  the Tools catalog calls (`W-tool-catalog-ui`). Same row shapes as
//  upstream so `ToolsManagerView`, `ToolCatalogRows` and
//  `ToolAdvancedDiagnosticsSection` compile unchanged.
//
//  Difference: Intel has no tool index database. Capability search
//  (`CapabilitySearch` in Tools/CapabilityTools.swift) reads the live
//  registry, so every registered, globally enabled tool counts as indexed.
//

#if OSAURUS_INTEL

import Foundation

actor ToolIndexService {
    static let shared = ToolIndexService()

    /// Every registered tool with its availability and search reasons.
    func exposureSnapshot(
        agentAllowedNames: Set<String>? = nil,
        executionMode: Any? = nil,
        selectedPreflightNames: Set<String>? = nil
    ) async -> ToolExposureDiagnostic {
        let toolNames = await MainActor.run { ToolRegistry.shared.listTools().map(\.name) }
        return await exposureDiagnostic(forToolNames: toolNames, agentAllowedNames: agentAllowedNames)
    }

    /// How named tools move through the registry → capability search path.
    func exposureDiagnostic(
        forToolNames rawNames: [String],
        agentAllowedNames: Set<String>? = nil,
        executionMode: Any? = nil,
        selectedPreflightNames: Set<String>? = nil
    ) async -> ToolExposureDiagnostic {
        var seen = Set<String>()
        let names = rawNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        return await MainActor.run {
            let registry = ToolRegistry.shared
            let tools = registry.listTools()
            let entriesByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
            let enabledNames = Set(tools.filter(\.enabled).map(\.name))
            let runtimeManaged = registry.runtimeManagedToolNames

            let rows = names.map { name -> ToolExposureDiagnostic.Row in
                let entry = entriesByName[name]
                let registered = entry != nil
                let enabled = enabledNames.contains(name)
                let availability = registry.availability(forTool: name, agentAllowedNames: agentAllowedNames)

                var blockers: [ToolExposureSearchReasonCode] = []
                func append(_ reason: ToolExposureSearchReasonCode) {
                    if !blockers.contains(reason) { blockers.append(reason) }
                }
                if !registered { append(.notRegistered) }
                if Self.capabilityToolNames.contains(name) { append(.excludedCapabilityInfrastructure) }
                if runtimeManaged.contains(name) { append(.runtimeManaged) }
                if registered, !enabled { append(.globallyDisabled) }
                if availability.reasonCodes.contains(.hiddenByAgentScope) { append(.hiddenByAgentScope) }

                let searchable = registered && blockers.isEmpty
                var reasons: [ToolExposureSearchReasonCode] = searchable ? [.searchable, .indexed] : []
                reasons.append(contentsOf: blockers)

                return ToolExposureDiagnostic.Row(
                    toolName: name,
                    description: entry?.description ?? "",
                    source: Self.source(for: name, registry: registry),
                    state: Self.state(for: availability),
                    availability: availability,
                    registered: registered,
                    globallyEnabled: enabled,
                    indexedForSearch: registered && enabled,
                    searchableByCapabilitiesDiscover: searchable,
                    searchReasonCodes: reasons,
                    tokenEstimate: entry?.estimatedTokens ?? 0
                )
            }
            return ToolExposureDiagnostic(
                registeredToolCount: tools.count,
                indexedToolCount: enabledNames.count,
                rows: rows
            )
        }
    }

    /// The capability gateway itself is never a search result.
    static let capabilityToolNames: Set<String> = ["capabilities", "capabilities_discover", "capabilities_load"]

    @MainActor
    static func source(for toolName: String, registry: ToolRegistry) -> ToolExposureSource {
        if registry.runtimeManagedToolNames.contains(toolName) { return .runtime }
        if registry.isBuiltInTool(toolName) { return .builtIn }
        if registry.isMCPTool(toolName) { return .mcpProvider }
        if registry.isSandboxTool(toolName) { return .sandboxPlugin }
        if registry.isPluginTool(toolName) { return .plugin }
        return .native
    }

    /// Same mapping as upstream `ToolIndexService.exposureState(for:)`.
    static func state(for availability: ToolAvailability) -> ToolExposureState {
        let reasons = Set(availability.reasonCodes)
        if reasons.contains(.permissionBlocked) || reasons.contains(.missingPermission) { return .blocked }
        if reasons.contains(.disabled) { return .disabled }
        if reasons.contains(.hiddenByAgentScope) || reasons.contains(.hiddenByExecutionMode)
            || reasons.contains(.notSelectedByPreflight)
        {
            return .hidden
        }
        if availability.isCallableNow { return .exposed }
        if availability.isLoadableViaCapabilitiesLoad { return .loadable }
        return .unavailable
    }
}

#endif
