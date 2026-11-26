//
//  ComputerUseEvidencePackTests.swift
//  OsaurusCoreTests — Computer Use
//
//  CI-safe evidence for the contract documented in docs/COMPUTER_USE.md.
//  These tests intentionally stay on pure seams: prompt/tool resolution,
//  MockMacDriver-backed loop runs, the policy gate, the prompt queue, and
//  screen-context injection. They do not require Accessibility or Screen
//  Recording permissions.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite struct ComputerUseEvidencePackTests {

    @Test func testComputerUseGoalContractDoesNotExpandUserScope() {
        let tool = ComputerUseTool()
        #expect(tool.description.contains("preserve the user's requested scope exactly"))
        #expect(tool.description.contains("do not add saving"))
        #expect(ComputerUseTool.authoritativeGoal(
                modelGoal: "In TextEdit, replace “old” with “new” and save the file",
                userRequest: "In TextEdit, replace “old” with “new”. Do not save."
            ) == "In TextEdit, replace “old” with “new”. Do not save.", "The exact user replacement, not the parent's expanded delegation, owns side-effect scope.")
        #expect(ComputerUseTool.authoritativeGoal(
                modelGoal: "Open the previously discussed report in TextEdit",
                userRequest: "Yes, do it"
            ) == "Open the previously discussed report in TextEdit", "Non-replacement turns keep the parent model's resolved context.")
        #expect(ComputerUseTool.authoritativeGoal(
                modelGoal: "Open Calculator",
                userRequest: nil
            ) == "Open Calculator", "Programmatic callers without a published user turn keep the explicit tool argument.")
    }

    // Intel: upstream's `testComputerUseToolIsCustomAgentOptInOnly` drives
    // `SystemPromptComposer.resolveTools(snapshot: AgentConfigSnapshot)`, which
    // Intel does not have. The same opt-in gate lives in `IntelDataConformers`
    // compose (`computerUseEnabled`) and `ToolRegistry.runtimeCapabilityDenial`;
    // `ComputerUseAuthorizationTests` covers the execution side.

    @Test func testAxResolvedRunStaysAxOnlyAndDoesNotUseScreenshots() async {
        let pid: Int32 = 4242
        let window = CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Notes",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(id: "title", role: "textfield", label: "Title", value: "", windowId: 1),
                CUElement(id: "save", role: "button", label: "Save", windowId: 1),
            ],
            image: nil
        )
        let driver = MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true),
            activeWindow: CUActiveWindow(pid: pid, app: "Notes", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snapshot]]
        )

        let result = await ComputerUseLoop.run(
            goal: "read the title field",
            modelId: "scripted",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            feed: SubagentFeed(toolCallId: "evidence-ax", kindId: "computer_use", title: "read the title field"),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 2, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-ax",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .done, reason: "Title field is visible")
            ])
        )

        #expect(result.outcome.isSuccess)
        #expect(result.metrics.maxTier == .ax)
        #expect(!(result.metrics.cloudVisionUsed))
    }

    @Test func testBrowserFormLoopFillsFieldsAndSubmitsDeterministically() async {
        let pid: Int32 = 5150
        // MockMacDriver advances one snapshot per capture: initial observe,
        // one post-action verify per acting verb, then one final assertion read.
        // Keep status as Draft through snapshot 5 so the submit click resolves
        // against the pre-submit tree, then expose the submitted state on 6-7.
        let snapshots = [
            browserFormSnapshot(snapshotId: 1, pid: pid),
            browserFormSnapshot(snapshotId: 2, pid: pid, team: "Synthetic Platform Team"),
            browserFormSnapshot(
                snapshotId: 3,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com"
            ),
            browserFormSnapshot(
                snapshotId: 4,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request."
            ),
            browserFormSnapshot(
                snapshotId: 5,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request.",
                termsAccepted: true
            ),
            browserFormSnapshot(
                snapshotId: 6,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request.",
                termsAccepted: true,
                status: "Submitted"
            ),
            browserFormSnapshot(
                snapshotId: 7,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request.",
                termsAccepted: true,
                status: "Submitted"
            ),
        ]
        let driver = MockMacDriver(
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [pid: snapshots]
        )
        let confirmationRecorder = ConfirmationRecorder()

        let result = await ComputerUseLoop.run(
            goal: "Fill out and submit the access request web form.",
            modelId: "scripted-browser-form",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "evidence-browser-form",
                kindId: "computer_use",
                title: "Fill out the form"
            ),
            interrupt: InterruptToken(),
            confirm: { preview in
                await confirmationRecorder.record(preview)
                return true
            },
            limits: RunLimits(maxSteps: 8, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-browser-form",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: "Team name"),
                    text: "Synthetic Platform Team"
                ),
                AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: "Email"),
                    text: "ops@example.com"
                ),
                AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: "Justification"),
                    text: "Automate a repetitive access request."
                ),
                AgentAction(verb: .click, target: AgentTarget(describe: "Agree to terms")),
                AgentAction(verb: .click, target: AgentTarget(describe: "Submit request")),
                AgentAction(verb: .done, reason: "The access request form was submitted."),
            ])
        )

        #expect(result.outcome.isSuccess, "Expected form completion; got \(result.outcome)")
        #expect(result.metrics.maxTier == .ax)
        #expect(!(result.metrics.cloudVisionUsed))
        #expect(result.metrics.targetResolveAttempts == 5)
        #expect(result.metrics.targetResolveSuccesses == 5)
        #expect(result.metrics.actsAttempted == 5)
        #expect(result.metrics.verifyChanged == 5)
        #expect(result.metrics.confirmsRequested == 1)
        #expect(result.metrics.confirmsApproved == 1)

        let confirmed = await confirmationRecorder.previews()
        #expect(confirmed.map(\.effect) == [.consequential])
        #expect(confirmed.first?.targetLabel == "button \"Submit request\"")

        let actions = await driver.elementActions
        #expect(privacySafeActionTrace(actions) == [
                "setValue:team:length=23",
                "setValue:email:length=15",
                "setValue:justification:length=37",
                "click:terms",
                "click:submit",
            ])
        let coordinateActions = await driver.coordinateActions
        #expect(coordinateActions.isEmpty, "Resolved AX form controls should not need coordinate fallback.")

        let finalSnapshot = await driver.capture(pid: pid, tier: .ax)
        #expect(value(in: finalSnapshot, id: "team") == "Synthetic Platform Team", "Team field did not match.")
        #expect(value(in: finalSnapshot, id: "email") == "ops@example.com", "Email field did not match.")
        #expect(value(in: finalSnapshot, id: "justification") == "Automate a repetitive access request.", "Justification field did not match.")
        #expect(value(in: finalSnapshot, id: "terms") == "checked", "Terms checkbox did not stay checked.")
        #expect(value(in: finalSnapshot, id: "status") == "Submitted", "Status field did not match.")
    }

    @Test func testAmbiguousWebFormTargetStopsBeforeTyping() async {
        let pid: Int32 = 5151
        let window = CUWindowSummary(
            id: 1,
            title: "Access request form",
            focused: true,
            x: 0,
            y: 0,
            w: 1280,
            h: 900
        )
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Safari",
            focusedWindow: "Access request form",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(id: "primary-email", role: "textfield", label: "Email", value: "", windowId: 1),
                CUElement(id: "recovery-email", role: "textfield", label: "Email", value: "", windowId: 1),
                CUElement(id: "submit", role: "button", label: "Submit request", windowId: 1),
            ],
            image: nil
        )
        let driver = MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: false, skyLight: true),
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [pid: [snapshot]]
        )

        let result = await ComputerUseLoop.run(
            goal: "Fill the email field.",
            modelId: "scripted-ambiguous-form",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "evidence-ambiguous-form",
                kindId: "computer_use",
                title: "Fill email"
            ),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(
                maxSteps: 5,
                maxConsecutiveReobserve: 2,
                maxConsecutiveDeadEnd: 1,
                wallClockSeconds: 30
            ),
            vision: .none,
            sessionId: "evidence-ambiguous-form",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .type,
                    target: AgentTarget(describe: "Email"),
                    text: "ops@example.com"
                )
            ])
        )

        guard case .deadEnd(let reason) = result.outcome else {
            Issue.record("Expected ambiguous target to dead-end; got \(result.outcome)"); return
        }
        #expect(reason.localizedCaseInsensitiveContains("resolve"), "Unexpected dead-end reason: \(reason)")
        #expect(result.metrics.targetResolveAttempts == 2)
        #expect(result.metrics.targetResolveSuccesses == 0)
        let elementActions = await driver.elementActions
        let coordinateActions = await driver.coordinateActions
        #expect(elementActions.isEmpty, "Ambiguous target must never reach element actions.")
        #expect(coordinateActions.isEmpty, "Ambiguous target must not fall back to coordinates.")
    }

    @Test func testTextInputRoutesToResolvedWebFormField() async {
        let pid: Int32 = 5152
        let driver = MockMacDriver(
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [
                pid: [
                    browserFormSnapshot(snapshotId: 1, pid: pid),
                    browserFormSnapshot(snapshotId: 2, pid: pid, email: "ops@example.com"),
                ]
            ]
        )

        let result = await ComputerUseLoop.run(
            goal: "Type the email address into the email field.",
            modelId: "scripted-text-routing",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "evidence-text-routing",
                kindId: "computer_use",
                title: "Type email"
            ),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-text-routing",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .type,
                    target: AgentTarget(describe: "Email"),
                    text: "ops@example.com"
                ),
                AgentAction(verb: .done, reason: "Email typed."),
            ])
        )

        #expect(result.outcome.isSuccess, "Expected resolved text routing; got \(result.outcome)")
        let actions = await driver.elementActions
        #expect(actions.count == 1)
        guard case .typeText(let id, let routedPid, let text, let replace) = actions.first else {
            Issue.record("Expected typeText into the resolved field; got \(actions)"); return
        }
        #expect(id == "email")
        #expect(routedPid == pid)
        #expect(text == "ops@example.com")
        #expect(replace)
        let coordinateActions = await driver.coordinateActions
        #expect(coordinateActions.isEmpty, "Resolved text input should not use coordinates.")
    }

    @Test func testWebFormFixtureIsLocalOnlyAndMatchesProofControls() throws {
        let request = try String(contentsOf: webFormFixtureFile("request.html"), encoding: .utf8)
        let submitted = try String(contentsOf: webFormFixtureFile("submitted.html"), encoding: .utf8)
        let combined = request + "\n" + submitted

        #expect(request.contains(#"action="./submitted.html""#))
        #expect(request.contains(#"autocomplete="off""#))
        #expect(request.contains(#"method="post""#))
        #expect(request.contains("form-action 'self'"))
        #expect(submitted.contains(#"href="./request.html""#))

        for forbidden in ["http://", "https://", "fetch(", "XMLHttpRequest", "sendBeacon", "src="] {
            #expect(!(combined.localizedCaseInsensitiveContains(forbidden)), "The local web-form fixture must not reference external resources: \(forbidden)")
        }
        for rawValue in ["Synthetic Platform Team", "ops@example.com", "Automate a repetitive access request."] {
            #expect(!(combined.contains(rawValue)), "The fixture page should not contain proof-run typed contents.")
        }

        let requiredControls = [
            #"id="team""#,
            #"id="email""#,
            #"id="justification""#,
            #"id="terms""#,
            ">Submit request<",
        ]
        for control in requiredControls {
            #expect(request.contains(control), "Missing expected form control marker: \(control)")
        }
    }

    @Test func testDangerousAppConfirmGuardrailCannotBeBypassedByAutonomousPreset() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous))
        let decision = await gate.evaluate(
            action: AgentAction(verb: .click, target: AgentTarget(describe: "New Window")),
            effect: .navigate,
            appName: "Terminal.app",
            targetLabel: "New Window"
        )

        guard case .confirm(let preview) = decision else {
            Issue.record("Terminal navigation should require confirmation even under autonomous."); return
        }
        #expect(preview.appName == "Terminal.app")
        #expect(preview.effect == .navigate)
    }

    @Test func testDangerousOpenDeclineKeepsActionsInCurrentWebForm() async {
        let pid: Int32 = 5153
        let driver = MockMacDriver(
            apps: [
                CUAppListing(pid: pid, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [pid: [browserFormSnapshot(snapshotId: 1, pid: pid)]]
        )
        let confirmationRecorder = ConfirmationRecorder()

        let result = await ComputerUseLoop.run(
            goal: "Try to open Terminal, then click the web form team field.",
            modelId: "scripted-dangerous-open",
            driver: driver,
            gate: ComputerUseGate(
                policy: AutonomyPolicy(
                    globalPreset: .autonomous,
                    allowlist: ["Safari", "Terminal"]
                )
            ),
            feed: SubagentFeed(
                toolCallId: "evidence-dangerous-open",
                kindId: "computer_use",
                title: "Open boundary"
            ),
            interrupt: InterruptToken(),
            confirm: { preview in
                await confirmationRecorder.record(preview)
                return false
            },
            // This case measures the gate boundary, not completion evidence:
            // the static mock view never changes after the click, so the
            // production done-verification gate is switched off here (it has
            // its own coverage in `ComputerUseLoopRunTests`).
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30, requireVerifiedChangeForDone: false),
            vision: .none,
            sessionId: "evidence-dangerous-open",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .open, app: "Terminal.app"),
                AgentAction(verb: .click, target: AgentTarget(describe: "Team name")),
                AgentAction(verb: .done, reason: "Stayed in the form."),
            ])
        )

        #expect(result.outcome.isSuccess, "Expected run to recover after declined open; got \(result.outcome)")
        let confirmed = await confirmationRecorder.previews()
        #expect(confirmed.count == 1)
        #expect(confirmed.first?.appName == "Terminal.app")
        #expect(confirmed.first?.effect == .navigate)
        #expect(result.metrics.confirmsDeclined == 1)
        let openCalls = await driver.openCalls
        #expect(openCalls.isEmpty, "Declining the dangerous open must prevent the driver open call.")
        let actions = await driver.elementActions
        #expect(actions.count == 1)
        guard case .click(let id, _, _) = actions.first else {
            Issue.record("Expected the follow-up action to click the original form; got \(actions)"); return
        }
        #expect(id == "team")
    }

    // Intel: stage 6 (screen context) test, not ported yet.
    @Test func testCloudVisionRequiresConsentAndScrubbedFrameRoute() async throws {
        let rawFrame = renderEvidenceCUImage(text: "Visible account number 1234")
        let noConsent = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: false,
            cloudConsent: false,
            cloudScrubMode: .allText
        )
        let available = MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true)

        #expect(VisionAttachment.decide(image: rawFrame, context: noConsent, availability: available) == .none)
        #expect(VisionAttachment.wouldAttachWithConsent(
                image: rawFrame,
                context: noConsent,
                availability: available
            ))

        let consented = noConsent.withConsent(true)
        #expect(VisionAttachment.decide(image: rawFrame, context: consented, availability: available) == .needsScrubForCloud(rawFrame))

        let scrubbed = try await FrameScrubber.scrub(rawFrame, mode: .allText)
        #expect(CaptureRouter.cloudRoute(
                scrubbed: scrubbed,
                consentGranted: false,
                availability: available
            ) == nil)

        guard
            case .cloudVision(let carried)? = CaptureRouter.cloudRoute(
                scrubbed: scrubbed,
                consentGranted: true,
                availability: available
            )
        else {
            Issue.record("Consent + Screen Recording + ScrubbedFrame should produce a cloud route."); return
        }
        #expect(carried == scrubbed)
    }

    @Test @MainActor
    func testStopCancelResolvesPendingConfirmationAndCloudConsentPrompts() async {
        let queue = ComputerUsePromptQueue.shared
        let toolCallId = "evidence-stop-\(UUID().uuidString)"
        let preview = ActionPreview(
            appName: "Notes",
            actionLabel: "Type text",
            targetLabel: "Body",
            effect: .edit,
            note: nil,
            typedText: "hello"
        )

        let confirmation = Task { @MainActor in
            await queue.requestConfirmation(preview, toolCallId: toolCallId)
        }
        let consent = Task { @MainActor in
            await queue.requestCloudVisionConsent(toolCallId: toolCallId)
        }

        await waitForPromptQueue(toolCallId: toolCallId)
        #expect(queue.pending.contains { $0.toolCallId == toolCallId })
        #expect(queue.pendingConsent.contains { $0.toolCallId == toolCallId })

        queue.cancelAll(forToolCallId: toolCallId)

        let approved = await confirmation.value
        let consentChoice = await consent.value
        #expect(!(approved))
        #expect(consentChoice == .deny)
        #expect(!(queue.pending.contains { $0.toolCallId == toolCallId }))
        #expect(!(queue.pendingConsent.contains { $0.toolCallId == toolCallId }))
    }

    // Intel: stage 6 (screen context) test, not ported yet.
    @MainActor
    private func waitForPromptQueue(toolCallId: String) async {
        for _ in 0 ..< 100 {
            if ComputerUsePromptQueue.shared.pending.contains(where: { $0.toolCallId == toolCallId }),
                ComputerUsePromptQueue.shared.pendingConsent.contains(where: { $0.toolCallId == toolCallId })
            {
                return
            }
            await Task.yield()
        }
    }

    private func renderEvidenceCUImage(text: String) -> CUImage {
        let size = CGSize(width: 640, height: 140)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: CGPoint(x: 20, y: 50), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let cg = rep.cgImage!
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        return CUImage(
            base64: png.base64EncodedString(),
            mimeType: "image/png",
            width: cg.width,
            height: cg.height
        )
    }

    private func webFormFixtureFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WebForm", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func browserFormSnapshot(
        snapshotId: Int,
        pid: Int32,
        team: String = "",
        email: String = "",
        justification: String = "",
        termsAccepted: Bool = false,
        status: String = "Draft"
    ) -> CUSnapshot {
        let window = CUWindowSummary(
            id: 1,
            title: "Access request form",
            focused: true,
            x: 0,
            y: 0,
            w: 1280,
            h: 900
        )
        let elements = [
            CUElement(
                id: "team",
                role: "textfield",
                label: "Team name",
                value: team,
                windowId: 1,
                x: 120,
                y: 120,
                w: 360,
                h: 32,
                actions: ["setValue"]
            ),
            CUElement(
                id: "email",
                role: "textfield",
                label: "Email",
                value: email,
                windowId: 1,
                x: 120,
                y: 180,
                w: 360,
                h: 32,
                actions: ["setValue"]
            ),
            CUElement(
                id: "justification",
                role: "textview",
                label: "Justification",
                value: justification,
                windowId: 1,
                x: 120,
                y: 240,
                w: 520,
                h: 120,
                actions: ["setValue"]
            ),
            CUElement(
                id: "terms",
                role: "checkbox",
                label: "Agree to terms",
                value: termsAccepted ? "checked" : "unchecked",
                windowId: 1,
                x: 120,
                y: 390,
                w: 220,
                h: 28,
                actions: ["press"]
            ),
            CUElement(
                id: "submit",
                role: "button",
                label: "Submit request",
                windowId: 1,
                x: 120,
                y: 450,
                w: 180,
                h: 36,
                actions: ["press"]
            ),
            CUElement(
                id: "status",
                role: "staticText",
                label: "Status",
                value: status,
                windowId: 1,
                x: 120,
                y: 520,
                w: 520,
                h: 24
            ),
        ]
        return CUSnapshot(
            snapshotId: snapshotId,
            pid: pid,
            app: "Safari",
            focusedWindow: "Access request form",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: elements,
            image: nil
        )
    }

    private func privacySafeActionTrace(_ actions: [CUElementAction]) -> [String] {
        actions.map { action in
            switch action {
            case .click(let id, _, _):
                return "click:\(id)"
            case .setValue(let id, let value):
                return "setValue:\(id):length=\(value.count)"
            case .typeText(let id, _, let text, let replace):
                return "typeText:\(id ?? "pid"):length=\(text.count):replace=\(replace)"
            case .pressKey(_, let key, let modifiers):
                return "pressKey:\((modifiers + [key]).joined(separator: "+"))"
            case .clearField(let id):
                return "clear:\(id)"
            }
        }
    }

    private func value(in snapshot: CUSnapshot, id: String) -> String? {
        snapshot.elements.first(where: { $0.id == id })?.value
    }

    /// An explicit `open` verb must launch the app FOREGROUND (`background: false`).
    /// A background launch sets `config.hides = true`; a hidden Cocoa app exposes no
    /// AX windows, so the readiness poll times out, the verify capture is empty, and
    /// the model reports the open as failed even though the app did launch. Regression
    /// guard for the 0.22.3 report: "launches the app but never brings the window to
    /// the foreground, then incorrectly reports the task as failed."
    @Test @MainActor
    func testOpenVerbLaunchesForegroundSoTheWindowIsVisibleAndVerifiable() async {
        let pid: Int32 = 7420
        let window = CUWindowSummary(id: 1, title: "Untitled", focused: true, x: 0, y: 0, w: 600, h: 400)
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "TextEdit",
            focusedWindow: "Untitled",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [CUElement(id: "doc", role: "textarea", label: "Document", value: "", windowId: 1)],
            image: nil
        )
        let driver = MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true),
            apps: [CUAppListing(pid: pid, bundleId: "com.apple.TextEdit", name: "TextEdit", active: false, hidden: false)],
            snapshots: [pid: [snapshot, snapshot]]
        )

        let result = await ComputerUseLoop.run(
            goal: "Open TextEdit.",
            modelId: "scripted-open",
            driver: driver,
            gate: ComputerUseGate(
                policy: AutonomyPolicy(globalPreset: .autonomous, allowlist: ["TextEdit"])
            ),
            feed: SubagentFeed(toolCallId: "evidence-open-fg", kindId: "computer_use", title: "Open TextEdit"),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-open-fg",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .open, app: "TextEdit"),
                AgentAction(verb: .done, reason: "TextEdit is open."),
            ])
        )

        #expect(result.outcome.isSuccess, "Open run should succeed; got \(result.outcome)")
        let openCalls = await driver.openCalls
        #expect(openCalls.count == 1, "The open verb must reach the driver exactly once.")
        #expect(openCalls.first?.identifier == "TextEdit")
        #expect(openCalls.first?.background == false, """
            The `open` verb launched the app in background mode. Background launching sets \
            config.hides = true, so the app never comes to the foreground and exposes no AX \
            windows — the model then reports a successful launch as a failure. An explicit \
            open must foreground the app.
            """)
    }
}

private actor ConfirmationRecorder {
    private var stored: [ActionPreview] = []

    func record(_ preview: ActionPreview) {
        stored.append(preview)
    }

    func previews() -> [ActionPreview] {
        stored
    }
}

private actor TranscriptRecorder {
    private var turns: [AgentStepInput.Turn] = []

    func record(_ transcript: [AgentStepInput.Turn]) {
        turns = transcript
    }

    func text() -> String {
        turns.map(\.text).joined(separator: "\n")
    }
}
