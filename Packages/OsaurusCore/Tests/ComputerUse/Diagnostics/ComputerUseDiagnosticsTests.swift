//
//  ComputerUseDiagnosticsTests.swift
//  OsaurusCoreTests - Computer Use
//
//  Coverage for the read-only Computer Use settings diagnostics.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ComputerUsePermissionDoctorTests {
    @Test func mapsAxOnlyPermissionPosture() {
        let snapshot = ComputerUsePermissionDoctor.snapshot(
            input: ComputerUsePermissionDoctorInput(
                availability: MacDriverAvailability(
                    accessibility: true,
                    screenRecording: false,
                    skyLight: false
                ),
                cloudVision: ComputerUseCloudVisionDoctorInput(
                    isGranted: false,
                    isPersistentlyGranted: false,
                    isSessionGranted: false,
                    scrubMode: .allText
                ),
                screenContextEnabled: false,
                agents: []
            )
        )

        #expect(snapshot.row(.accessibility)?.value == "Granted")
        #expect(snapshot.row(.screenRecording)?.value == "Optional")
        #expect(snapshot.row(.axPosture)?.value == "AX-only")
        #expect(snapshot.row(.cloudVision)?.value == "Unavailable")
        #expect(snapshot.row(.screenContext)?.value == "Off")
        #expect(snapshot.row(.perAgent)?.value == "No custom agents")
    }

    @Test func mapsCloudVisionScreenContextAndAgentAvailability() {
        let customEnabled = UUID()
        let customMissingModel = UUID()
        let snapshot = ComputerUsePermissionDoctor.snapshot(
            input: ComputerUsePermissionDoctorInput(
                availability: MacDriverAvailability(
                    accessibility: true,
                    screenRecording: true,
                    skyLight: false
                ),
                cloudVision: ComputerUseCloudVisionDoctorInput(
                    isGranted: true,
                    isPersistentlyGranted: true,
                    isSessionGranted: false,
                    scrubMode: .pii
                ),
                screenContextEnabled: true,
                agents: [
                    ComputerUseAgentAvailabilityInput(
                        id: Agent.defaultId,
                        displayName: "Osaurus",
                        isBuiltIn: true,
                        computerUseEnabled: false,
                        hasEffectiveModel: true
                    ),
                    ComputerUseAgentAvailabilityInput(
                        id: customEnabled,
                        displayName: "Desk Agent",
                        isBuiltIn: false,
                        computerUseEnabled: true,
                        hasEffectiveModel: true,
                        ceilingPreset: .balanced
                    ),
                    ComputerUseAgentAvailabilityInput(
                        id: customMissingModel,
                        displayName: "No Model Agent",
                        isBuiltIn: false,
                        computerUseEnabled: true,
                        hasEffectiveModel: false
                    ),
                ]
            )
        )

        #expect(snapshot.row(.cloudVision)?.value == "On (persistent)")
        #expect(snapshot.row(.cloudVision)?.severity == .ready)  // Intel: both scrub modes mask all text
        #expect(snapshot.row(.screenContext)?.value == "On")
        #expect(snapshot.row(.perAgent)?.value == "2/2 custom enabled")
        #expect(snapshot.agentAvailability.customAgentCount == 2)
        #expect(snapshot.agentAvailability.enabledCustomAgentCount == 2)
        #expect(snapshot.agentAvailability.rows.first { $0.id == Agent.defaultId }?.value == "Unavailable")
        #expect(snapshot.agentAvailability.rows.first { $0.id == customMissingModel }?.severity == .attention)
    }
}

@Suite
struct ComputerUseGateInspectorTests {
    private struct ParityCase {
        let name: String
        let input: ComputerUseGateInspectionInput
        let expectedEffect: EffectClass
        let expectedDecision: ComputerUseGateDecisionKind
        let expectedFinalDisposition: AutonomyDisposition?
        let expectedAllowlistAllowed: Bool
        let expectedDangerousConfirm: Bool
        let expectedPerAppContribution: AutonomyDisposition?
        let expectedCeilingContribution: AutonomyDisposition?
    }

    @Test func inspectorMatchesClassifierPolicyAndGate() async {
        var trustedWithCautiousNotes = AutonomyPolicy(globalPreset: .trusted)
        trustedWithCautiousNotes.perApp["notes"] = .cautious

        let cases: [ParityCase] = [
            ParityCase(
                name: "send",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced),
                    appName: "Mail",
                    verb: .click,
                    targetLabel: "Send",
                    targetRole: "AXButton"
                ),
                expectedEffect: .consequential,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "delete",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .trusted),
                    appName: "Notes",
                    verb: .click,
                    targetLabel: "Delete",
                    targetRole: "AXButton"
                ),
                expectedEffect: .consequential,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "save with per-app override",
                input: ComputerUseGateInspectionInput(
                    policy: trustedWithCautiousNotes,
                    appName: "Notes",
                    verb: .click,
                    targetLabel: "Save",
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: .confirm,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "OK",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced),
                    appName: "Dialog",
                    verb: .click,
                    targetLabel: "OK",
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "icon-only",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced),
                    appName: "Notes",
                    verb: .click,
                    targetLabel: nil,
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "System Settings",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .autonomous),
                    appName: "System Settings",
                    verb: .click,
                    targetLabel: "Displays",
                    targetRole: "AXButton"
                ),
                expectedEffect: .navigate,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: true,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "open app",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced, allowlist: ["mail"]),
                    appName: "Mail",
                    verb: .open,
                    targetLabel: "Save",
                    targetRole: "AXButton",
                    targetValue: "Draft invoice",
                    targetRoleDescription: "button"
                ),
                expectedEffect: .navigate,
                expectedDecision: .run,
                expectedFinalDisposition: .allow,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "allowlist",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced, allowlist: ["notes"]),
                    appName: "Mail",
                    verb: .click,
                    targetLabel: "Files",
                    targetRole: "AXButton"
                ),
                expectedEffect: .navigate,
                expectedDecision: .reject,
                expectedFinalDisposition: nil,
                expectedAllowlistAllowed: false,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "read-only ceiling",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .autonomous),
                    ceiling: AutonomyCeiling.cappedAt(.readOnly),
                    appName: "Notes",
                    verb: .click,
                    targetLabel: "Save",
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .reject,
                expectedFinalDisposition: .deny,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: .deny
            ),
        ]

        for testCase in cases {
            let inspection = await ComputerUseGateInspector.inspect(testCase.input)
            let appName = appNameForGate(testCase.input, action: inspection.action)
            let isOpen = inspection.action.verb == .open
            let directEffect = EffectClassifier.classify(
                action: inspection.action,
                resolvedRole: isOpen ? nil : nonEmpty(testCase.input.targetRole),
                resolvedLabel: isOpen ? nil : nonEmpty(testCase.input.targetLabel),
                resolvedValue: isOpen ? nil : nonEmpty(testCase.input.targetValue),
                resolvedRoleDescription: isOpen ? nil : nonEmpty(testCase.input.targetRoleDescription),
                appName: appName,
                recipeSignals: AppRecipes.signals(for: appName)
            )
            let directDecision = await ComputerUseGate(
                policy: testCase.input.policy,
                ceiling: testCase.input.ceiling
            ).evaluate(
                action: inspection.action,
                effect: directEffect,
                appName: appName,
                targetLabel: targetLabelForGate(testCase.input, action: inspection.action)
            )

            #expect(inspection.gateIsReached, Comment(rawValue: testCase.name))
            #expect(inspection.effect == directEffect, Comment(rawValue: testCase.name))
            #expect(inspection.decision == directDecision, Comment(rawValue: testCase.name))
            #expect(inspection.effect == testCase.expectedEffect, Comment(rawValue: testCase.name))
            #expect(inspection.decisionKind == testCase.expectedDecision, Comment(rawValue: testCase.name))
            #expect(inspection.finalDisposition == testCase.expectedFinalDisposition, Comment(rawValue: testCase.name))
            #expect(inspection.allowlist.isAllowed == testCase.expectedAllowlistAllowed, Comment(rawValue: testCase.name))
            #expect(inspection.dangerousAppRequiresConfirm == testCase.expectedDangerousConfirm, Comment(rawValue: testCase.name))
            #expect(inspection.perAppContribution?.disposition == testCase.expectedPerAppContribution, Comment(rawValue: testCase.name))
            #expect(inspection.ceilingContribution?.disposition == testCase.expectedCeilingContribution, Comment(rawValue: testCase.name))
        }
    }

    @Test func readAndTerminalPreviewVerbsBypassAutonomyGateLikeLiveLoop() async {
        let policy = AutonomyPolicy(globalPreset: .readOnly, allowlist: ["Notes"])
        let verbs: [AgentVerb] = [.observe, .wait, .find, .done, .giveUp]

        for verb in verbs {
            let inspection = await ComputerUseGateInspector.inspect(
                ComputerUseGateInspectionInput(
                    policy: policy,
                    appName: "Mail",
                    verb: verb,
                    targetLabel: "Inbox",
                    targetRole: "AXGroup",
                    note: "Preview"
                )
            )

            #expect(!(inspection.gateIsReached), Comment(rawValue: verb.rawValue))
            #expect(!(inspection.allowlist.isReached), Comment(rawValue: verb.rawValue))
            #expect(inspection.allowlist.displayValue == "Not reached", Comment(rawValue: verb.rawValue))
            #expect(inspection.allowlist.isAllowed == false, Comment(rawValue: verb.rawValue))
            #expect(inspection.finalDisposition == nil, Comment(rawValue: verb.rawValue))
            #expect(inspection.decision == .run, Comment(rawValue: verb.rawValue))
            #expect(inspection.decisionKind == .run, Comment(rawValue: verb.rawValue))
            #expect(inspection.decisionSummary == "Handled before autonomy gating in the live loop.", Comment(rawValue: verb.rawValue))
        }
    }

    private func appNameForGate(_ input: ComputerUseGateInspectionInput, action: AgentAction) -> String? {
        if action.verb == .open {
            return nonEmpty(action.app) ?? nonEmpty(input.appName)
        }
        return nonEmpty(input.appName)
    }

    private func targetLabelForGate(_ input: ComputerUseGateInspectionInput, action: AgentAction) -> String? {
        if action.verb == .open {
            return nonEmpty(action.app) ?? nonEmpty(input.appName)
        }
        return nonEmpty(input.targetLabel) ?? nonEmpty(input.targetDescription)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Intel additions (stage 5)

@Suite
struct ComputerUseGateInspectorHardStopTests {
    @Test func passwordFieldPreviewIsBlockedNotConfirmed() async {
        let inspection = await ComputerUseGateInspector.inspect(
            ComputerUseGateInspectionInput(
                policy: AutonomyPolicy(globalPreset: .trusted),
                appName: "Safari",
                verb: .type,
                targetLabel: "Password",
                targetRole: "AXSecureTextField",
                text: "hunter2"
            )
        )
        #expect(inspection.decisionKind == .reject)
        #expect(inspection.decisionSummary.hasPrefix("Blocked:"))
    }

    @Test func ordinaryClickPreviewStillFollowsThePolicy() async {
        let inspection = await ComputerUseGateInspector.inspect(
            ComputerUseGateInspectionInput(
                policy: AutonomyPolicy(globalPreset: .trusted),
                appName: "Notes",
                verb: .click,
                targetLabel: "Folders",
                targetRole: "AXButton"
            )
        )
        #expect(inspection.decisionKind == .run)
    }
}

/// Source guards for the stage 5 safety rules (no real permission request, no
/// real input: these only read source files).
@Suite
struct ComputerUseSettingsSafetyTests {
    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func permissionIsRequestedOnlyFromTheGrantButton() throws {
        let settings = try Self.source("Views/Settings/ComputerUseSettingsView.swift")
        // One call, inside the Grant button's action, never in appear/task code.
        #expect(settings.components(separatedBy: "requestPermission(").count - 1 == 1)
        #expect(settings.contains("Button(action: { permissionService.requestPermission(permission) })"))
        for file in [
            "Views/Settings/ComputerUseDiagnosticsPanel.swift",
            "Views/Agent/IntelComputerUseAbilitySection.swift",
            "ComputerUse/Diagnostics/ComputerUsePermissionDoctor.swift",
            "ComputerUse/Diagnostics/ComputerUseGateInspector.swift",
        ] {
            let text = try Self.source(file)
            #expect(!text.contains("requestPermission("), Comment(rawValue: file))
            #expect(!text.contains("AXIsProcessTrustedWithOptions"), Comment(rawValue: file))
        }
    }

    @Test func switchIsOffByDefaultAndSetOnlyByTheUserToggle() throws {
        // A config with no mention of the switch decodes to off.
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(decoded.computerUseEnabled == false)
        #expect(AgentSettings.defaultDisabled.computerUseEnabled == false)
        let section = try Self.source("Views/Agent/IntelComputerUseAbilitySection.swift")
        #expect(section.components(separatedBy: "computerUseEnabled = value").count - 1 == 1)
        #expect(section.contains("agentId == Agent.defaultId"))
    }

    @Test func quitAndStopWiring() throws {
        let delegate = try Self.source("AppDelegate.swift")
        #expect(delegate.contains("ComputerUseTeardown.stopEverything()"))
        #expect(delegate.contains("SubagentInterruptCenter.shared.interruptAll()"))
        #expect(delegate.contains("ComputerUsePolicyStore.flushPendingWrites()"))
        let chat = try Self.source("Views/Chat/ChatView.swift")
        #expect(chat.contains("ComputerUseTeardown.interruptRuns("))
    }

    @Test func settingsTabIsRegisteredAndSearchable() {
        #expect(ManagementTab.computerUse.label == "Computer Use")
        #expect(ManagementSection.automation.tabs.contains(.computerUse))
        #expect(SettingsSearchIndex.entries.contains { $0.id == "computerUse.enable" && $0.tab == .computerUse })
        #expect(ManagementTab(rawValue: "computerUse") == .computerUse)
    }
}

@Suite
struct ComputerUseTeardownTests {
    @Test func interruptRunsTripsOnlyThisChatsComputerUseRuns() {
        let mine = "teardown-mine-\(UUID().uuidString)"
        let other = "teardown-other-\(UUID().uuidString)"
        let spawn = "teardown-spawn-\(UUID().uuidString)"
        let owner = UUID().uuidString
        let kind = SubagentCapabilityRegistry.computerUse.id
        let tokens = [mine: InterruptToken(), other: InterruptToken(), spawn: InterruptToken()]
        let feeds = [
            SubagentFeed(toolCallId: mine, kindId: kind, title: "t", parentSessionId: owner),
            SubagentFeed(toolCallId: other, kindId: kind, title: "t", parentSessionId: UUID().uuidString),
            SubagentFeed(
                toolCallId: spawn, kindId: SubagentCapabilityRegistry.spawn.id, title: "t",
                parentSessionId: owner),
        ]
        for feed in feeds {
            SubagentFeedRegistry.shared.register(feed)
            SubagentInterruptCenter.shared.register(tokens[feed.toolCallId]!, for: feed.toolCallId)
        }
        defer {
            for id in tokens.keys {
                SubagentInterruptCenter.shared.unregister(id)
                SubagentFeedRegistry.shared.removeNow(toolCallId: id)
            }
        }

        let count = ComputerUseTeardown.interruptRuns(ownedBy: [owner.lowercased()])

        #expect(count == 1)
        #expect(tokens[mine]!.isInterrupted)
        #expect(!tokens[other]!.isInterrupted)
        #expect(!tokens[spawn]!.isInterrupted)
    }

    @Test func noOwnersInterruptsNothing() {
        #expect(ComputerUseTeardown.interruptRuns(ownedBy: []) == 0)
    }
}
