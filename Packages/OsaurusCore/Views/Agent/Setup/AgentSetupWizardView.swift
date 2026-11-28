//
//  AgentSetupWizardView.swift
//  osaurus
//
//  Guided setup for an agent whose configuration this Mac cannot honour
//  yet: a model that is not installed, a working folder without access, a
//  knowledge grant with no collection, tools no server here provides, a
//  system permission the OS has not given. Steps are generated from an
//  `SetupReport`, so an agent with one gap gets one step plus Review.
//
//  Two modes, one view:
//   - `.draft(agent, template)`: Use Template. The agent does NOT exist
//     yet; every step edits the in-memory record and the primary button
//     creates the agent only when nothing blocks. Nothing is written
//     before that, so a template that cannot work here never produces a
//     broken agent.
//   - `.saved(id)`: Run Setup / first-open prompt / spawn refusal on an
//     agent that already exists. Steps write through `AgentManager`.
//
//  Guidance rule: the primary button is never disabled for a reason the
//  user cannot see. Tapping it with gaps left shows the reason in the
//  footer and glows the step that needs attention.
//
//  Intel (W-agent-templates, upstream #3172). Same wizard, adapted to what
//  Intel has:
//   - Steps Intel cannot offer are shown dimmed with a short reason, never
//     dropped: Knowledge (Intel agents have no knowledge grants) appears,
//     dimmed, when the template asks for knowledge collections, and the
//     Model step's "Download a model" is a dimmed note (no local MLX
//     models on Intel).
//   - Working Folder stores the path only (Intel is not App-Sandboxed, so no
//     security-scoped bookmark).
//   - "Open Plugins" goes to Intel's Plugins tab.
//   - Creating from a template saves through `AgentManager.add` exactly as
//     the Create Agent sheet does, after the same plan the Orchestrator's
//     `osaurus_config` shows (`ConfigPlanner`): high-risk changes in the
//     plan must be reviewed (checkbox) before Create Agent goes ahead.
//   - Ventura: one-value `onChange`, no macOS 14 APIs.
//

import AppKit
import SwiftUI

/// What the wizard works on.
enum AgentSetupSubject: Identifiable {
    case saved(UUID)
    case draft(Agent, template: AgentTemplate)

    var id: UUID {
        switch self {
        case .saved(let id): return id
        case .draft(let agent, _): return agent.id
        }
    }

    var isDraft: Bool {
        if case .draft = self { return true }
        return false
    }
}

struct AgentSetupWizardView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let subject: AgentSetupSubject
    let onClose: () -> Void
    /// Draft mode: the agent was created. Saved mode: setup finished.
    var onFinished: (Agent) -> Void = { _ in }

    enum Step: Hashable {
        case model
        case folder
        case knowledge
        case tools
        case permissions
        case review

        var title: String {
            switch self {
            case .model: return L("Model")
            case .folder: return L("Working Folder")
            case .knowledge: return L("Knowledge")
            case .tools: return L("Tools")
            case .permissions: return L("Permissions")
            case .review: return L("Review")
            }
        }

        var icon: String {
            switch self {
            case .model: return "cube"
            case .folder: return "folder"
            case .knowledge: return "books.vertical"
            case .tools: return "wrench.and.screwdriver"
            case .permissions: return "lock.shield"
            case .review: return "checkmark.seal"
            }
        }

        /// Intel has no knowledge grants, so the step only explains itself.
        var isUnavailableOnIntel: Bool { self == .knowledge }

        /// Why `isUnavailableOnIntel` steps are dimmed.
        var unavailableReason: String {
            switch self {
            case .knowledge:
                return L(
                    "Knowledge collections are not available on this Mac yet, so this agent cannot be granted any.")
            default: return ""
            }
        }

        /// `needsKnowledge`: the template (or the agent's source template)
        /// asks for knowledge collections. Intel's checker never reports
        /// them, so the step is added here, dimmed, instead of vanishing.
        static func steps(for report: SetupReport, needsKnowledge: Bool = false) -> [Step] {
            var steps: [Step] = []
            let kinds = Set(report.items.map(\.kind))
            if kinds.contains(.model) { steps.append(.model) }
            if kinds.contains(.workingFolder) { steps.append(.folder) }
            if kinds.contains(.knowledgeCollection) || needsKnowledge { steps.append(.knowledge) }
            if kinds.contains(.mcpServer) || kinds.contains(.plugin) { steps.append(.tools) }
            if kinds.contains(.systemPermission) { steps.append(.permissions) }
            steps.append(.review)
            return steps
        }

        func items(in report: SetupReport) -> [SetupItem] {
            report.items.filter { item in
                switch self {
                case .model: return item.kind == .model
                case .folder: return item.kind == .workingFolder
                case .knowledge: return item.kind == .knowledgeCollection
                case .tools: return item.kind == .mcpServer || item.kind == .plugin
                case .permissions: return item.kind == .systemPermission
                case .review: return false
                }
            }
        }
    }

    /// Draft-mode working copy. Saved mode reads `AgentManager` directly.
    @State private var draft: Agent?
    @State private var report: SetupReport?
    @State private var steps: [Step] = [.review]
    @State private var current: Step = .review
    @State private var hasAppeared = false
    @State private var footerWarning: String?
    /// Rail step glowing after a refused primary action.
    @State private var glowingStep: Step?
    @State private var glowClearTask: Task<Void, Never>?
    /// Add-provider form, presented over the wizard so configuring a
    /// provider never tears the wizard (and, in draft mode, the unsaved
    /// agent) down.
    @State private var showAddProvider = false
    /// Draft mode: the plan for the template, as `osaurus_config` would show
    /// it. High-risk changes need a deliberate review before Create.
    @State private var planText: String?
    @State private var planHasHighRisk = false
    @State private var reviewedRisks = false

    private var template: AgentTemplate? {
        if case .draft(_, let template) = subject { return template }
        return nil
    }

    private var agent: Agent? {
        switch subject {
        case .saved(let id): return agentManager.agent(for: id)
        case .draft: return draft
        }
    }

    /// Whether the template behind this wizard asks for knowledge
    /// collections (draft: the template itself; saved: the agent's source).
    private var needsKnowledge: Bool {
        if let template { return !template.requirements(of: .knowledgeCollection).isEmpty }
        guard let source = agent?.sourceTemplateName,
            let named = TemplateStore.shared.template(named: source, kind: .agent)
        else { return false }
        return !named.requirements(of: .knowledgeCollection).isEmpty
    }

    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }
    private var isLast: Bool { currentIndex == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                stepRail
                    .frame(width: 200)
                    .layoutPriority(1)
                Divider()
                ScrollView {
                    Group {
                        if let report, let agent {
                            stepContent(agent: agent, report: report)
                        } else {
                            ProgressView()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.primaryBackground)
            footer
        }
        .fittedSheetFrame(width: 820, height: 560)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1))
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
        .onAppear {
            hasAppeared = true
            if case .draft(let agent, _) = subject, draft == nil { draft = agent }
            refresh(rebuildSteps: true)
            refreshPlan()
        }
        // Permissions granted in System Settings land here when the user
        // comes back; the step re-checks without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh(rebuildSteps: false)
        }
        .onChange(of: agentManager.agents) { _ in
            if !subject.isDraft { refresh(rebuildSteps: false) }
        }
        .sheet(isPresented: $showAddProvider) {
            RemoteProviderEditSheet(provider: nil) { provider, apiKey, oauthTokens in
                RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
                Task { @MainActor in
                    // A new provider only becomes a pickable model once the
                    // picker cache is rebuilt. (Intel: same `addProvider` the
                    // Providers tab calls; no separate catalog refresh.)
                    _ = await ModelPickerItemCache.shared.buildModelPickerItems()
                    refresh(rebuildSteps: false)
                }
            }
            .environment(\.theme, theme)
        }
    }

    /// Hand the wizard off to another tab without losing it. The subject,
    /// including edits made to an unsaved draft, is parked on the shared
    /// management state; `AgentsView` reopens the wizard from there when the
    /// user comes back.
    private func leave(to tab: ManagementTab) {
        let resume: AgentSetupSubject
        if case .draft(let original, let template) = subject {
            resume = .draft(draft ?? original, template: template)
        } else {
            resume = subject
        }
        ManagementStateManager.shared.pendingSetupSubject = .agent(resume)
        onClose()
        AppDelegate.shared?.showManagementWindow(initialTab: tab)
    }

    @ViewBuilder
    private var header: some View {
        if let template {
            AgentSheetHeader(
                icon: "square.on.square.dashed",
                title: "Create Agent from Template",
                subtitleText: L("Based on the \(template.name) template"),
                onClose: onClose
            )
        } else {
            AgentSheetHeader(
                icon: "checklist",
                title: "Set Up Agent",
                subtitleText: agent?.name,
                onClose: onClose
            )
        }
    }

    // MARK: - Rail

    private var stepRail: some View {
        SetupStepRail(steps: steps, current: $current, glowing: glowingStep, title: \.title) { step in
            guard step != .review, let report else { return .none }
            if step.isUnavailableOnIntel { return .unavailable }
            let remaining = step.items(in: report)
            if remaining.isEmpty { return .done }
            return remaining.contains(where: \.isBlocking) ? .required : .optional
        }
    }

    // MARK: - Footer

    private var footer: some View {
        AgentSheetFooter(
            primary: AgentSheetFooter.Action(
                label: isLast ? (subject.isDraft ? "Create Agent" : "Finish") : "Next",
                handler: { if isLast { finish() } else { advance() } }
            ),
            secondary: AgentSheetFooter.Action(
                label: currentIndex == 0 ? (subject.isDraft ? "Cancel" : "Later") : "Back",
                handler: { if currentIndex == 0 { onClose() } else { goBack() } }
            ),
            hint: nil,
            warning: footerWarning
        )
    }

    private func advance() {
        guard currentIndex + 1 < steps.count else { return }
        withAnimation(.easeInOut(duration: 0.18)) { current = steps[currentIndex + 1] }
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.18)) { current = steps[currentIndex - 1] }
    }

    /// Create (draft) or finish (saved). Refused with guidance while a
    /// blocking item remains.
    private func finish() {
        refresh(rebuildSteps: false)
        guard let agent, let report else { return }
        if let blocker = report.blocking.first,
            let step = steps.first(where: { !$0.items(in: report).filter(\.isBlocking).isEmpty })
        {
            warn(blocker.detail, glowing: step)
            return
        }
        var final = agent
        // A `preferred` template whose model is still missing falls back to
        // the default model here, explicitly, after the user saw the step.
        if subject.isDraft, let pinned = final.defaultModel, !pinned.isEmpty,
            report.items.contains(where: { $0.kind == .model })
        {
            final.defaultModel = nil
        }
        switch subject {
        case .draft:
            let trimmed = final.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                warn(L("Give the agent a name before creating it."), glowing: .review)
                return
            }
            final.name = trimmed
            final.sourceTemplateName = template?.name
            // Intel: the plan `osaurus_config` would show for this template.
            // High-risk changes (sandbox, computer use, ...) are created only
            // after the user ticked the review box on the Review step.
            refreshPlan(name: trimmed)
            if planHasHighRisk, !reviewedRisks {
                warn(L("Review the risks listed on the Review step before creating this agent."), glowing: .review)
                return
            }
            AgentManager.shared.add(final)
            // `add` flags the agent for first-run setup; the check that just
            // passed is that setup, so clear it right away.
            SetupStateStore.shared.clear(final.id)
            onFinished(final)
        case .saved:
            if final != agent { AgentManager.shared.update(final) }
            SetupStateStore.shared.clear(final.id)
            _ = ToastManager.shared.success(L("\(final.name) is ready"))
            onFinished(final)
        }
        onClose()
    }

    private func warn(_ text: String, glowing step: Step) {
        withAnimation(.easeOut(duration: 0.15)) { footerWarning = text }
        glowClearTask?.cancel()
        glowingStep = nil
        glowingStep = step
        glowClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            glowingStep = nil
        }
    }

    /// Apply a change to the subject: the draft in memory, or the saved
    /// agent through the manager. Re-checks afterwards.
    private func mutate(_ change: (inout Agent) -> Void) {
        switch subject {
        case .draft:
            guard var working = draft else { return }
            change(&working)
            draft = working
        case .saved(let id):
            guard var working = AgentManager.shared.agent(for: id) else { return }
            change(&working)
            AgentManager.shared.update(working)
        }
        withAnimation(.easeOut(duration: 0.15)) { footerWarning = nil }
        refresh(rebuildSteps: false)
    }

    /// Re-run the check. Steps are rebuilt only on first appear so a fixed
    /// step stays in the rail with its check mark instead of vanishing.
    private func refresh(rebuildSteps: Bool) {
        adoptTemplateGroupTools()
        guard let agent else { return }
        var fresh = SetupChecker.check(agent)
        if let template, template.modelPolicy == .preferred {
            fresh = Self.downgradeModelToAdvisory(fresh, requested: template.agent.model.valueOrNil)
        }
        report = fresh
        if rebuildSteps {
            steps = Step.steps(for: fresh, needsKnowledge: needsKnowledge)
            current = steps.first ?? .review
        }
    }

    /// Draft mode: plan the template the way `osaurus_config` would, for the
    /// Review step to show. Nothing is applied here.
    private func refreshPlan(name: String? = nil) {
        guard let template else { return }
        let agentName = (name ?? draft?.name ?? template.agent.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty else { return }
        var entry = template.resolvedEntry(overrides: AgentEntry(name: agentName))
        entry.sourceTemplate = template.name
        var doc = OsaurusConfigDocument()
        doc.version = 1
        doc.agents = [entry]
        do {
            let plan = try ConfigPlanner.plan(document: doc, prune: false)
            planText = plan.summaryText()
            planHasHighRisk = plan.hasHighRiskChanges
        } catch let issues as ConfigPlanIssues {
            planText = issues.issues.map { "• \($0)" }.joined(separator: "\n")
            planHasHighRisk = false
        } catch {
            planText = error.localizedDescription
            planHasHighRisk = false
        }
    }

    /// Pull in the tools of any template MCP server or plugin that exists
    /// now, e.g. one the user just added from the Tools step.
    private func adoptTemplateGroupTools() {
        guard let agent, let source = agent.sourceTemplateName,
            let groups = TemplateStore.shared.template(named: source)?.toolGroups, !groups.isEmpty
        else { return }
        let updated = SetupChecker.addingTemplateGroupTools(
            to: agent, groups: groups, available: ToolRegistry.shared.portableToolGroups())
        guard updated.manualToolNames != agent.manualToolNames else { return }
        switch subject {
        case .draft: draft = updated
        case .saved: AgentManager.shared.update(updated)
        }
    }

    /// `preferred` templates may fall back to the default model, so a
    /// missing model is a choice to confirm, not a blocker.
    private static func downgradeModelToAdvisory(_ report: SetupReport, requested: String?) -> SetupReport {
        let items = report.items.map { item -> SetupItem in
            guard item.kind == .model else { return item }
            let name = requested ?? item.value
            return SetupItem(
                kind: .model, severity: .advisory, title: item.title,
                detail: L("The template prefers \(name), which is not installed here. Create will use your default model unless you pick one."),
                value: item.value)
        }
        return SetupReport(subjectId: report.subjectId, items: items)
    }

    // MARK: - Step content

    @ViewBuilder
    private func stepContent(agent: Agent, report: SetupReport) -> some View {
        let items = current.items(in: report)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: current.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(current.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)
            }
            switch current {
            case .model:
                ModelStep(
                    agent: agent, items: items, mutate: mutate,
                    onAddProvider: { showAddProvider = true }
                )
            case .folder: FolderStep(agent: agent, items: items, mutate: mutate)
            case .knowledge: UnavailableStep(reason: current.unavailableReason)
            case .tools: ToolsStep(agent: agent, items: items, mutate: mutate, onLeave: { leave(to: $0) })
            case .permissions:
                PermissionsStep(
                    items: items, doneText: L("Every permission this agent needs is granted."),
                    onChanged: { refresh(rebuildSteps: false) })
            case .review:
                ReviewStep(
                    agent: agent, report: report, isDraft: subject.isDraft,
                    planText: planText, planHasHighRisk: planHasHighRisk,
                    reviewedRisks: $reviewedRisks,
                    onRename: { newName in
                        mutate { $0.name = newName }
                        refreshPlan(name: newName)
                    }
                )
            }
        }
    }
}

// MARK: - Model

private struct ModelStep: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared
    let agent: Agent
    let items: [SetupItem]
    let mutate: ((inout Agent) -> Void) -> Void
    /// Opens the add-provider form over the wizard.
    let onAddProvider: () -> Void

    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("This agent has a model it can run."))
            } else {
                StepIssueList(items: items)
            }
            // One control. Models the user already has are in the dropdown,
            // and "Add Provider" is a row inside that same dropdown.
            modelField
                .frame(maxWidth: .infinity)
            // Upstream's "Download a model" row. Intel has no local models,
            // so it is shown dimmed with the reason instead of dropped.
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("Download a model", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                Text("Local models are not available on this Mac. Add a provider to use a cloud model.", bundle: .module)
                    .font(.system(size: 11))
                    .lineLimit(2)
            }
            .foregroundColor(theme.tertiaryText)
            .opacity(0.7)
        }
        .onAppear {
            // The cache is prewarmed at launch; guard the cold case anyway.
            if !pickerCache.isLoaded { pickerCache.prewarm() }
        }
    }

    /// Same dropdown as the Create Agent sheet's Default Model field.
    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Default Model")
            Button {
                showPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(agent.defaultModel == nil ? theme.tertiaryText : theme.accentColor)
                    if let model = agent.defaultModel, !model.isEmpty {
                        Text(model.split(separator: "/").last.map(String.init) ?? model)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(items.isEmpty ? theme.primaryText : theme.warningColor)
                            .lineLimit(1)
                    } else {
                        Text("Default (from global settings)", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                ModelPickerView(
                    options: pickerCache.items,
                    selectedModel: Binding(
                        get: { agent.defaultModel },
                        set: { newModel in
                            mutate { $0.defaultModel = newModel }
                            showPicker = false
                        }),
                    agentId: nil,
                    onDismiss: { showPicker = false },
                    onAddProvider: {
                        showPicker = false
                        onAddProvider()
                    }
                )
            }
        }
    }
}

// MARK: - Folder

private struct FolderStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [SetupItem]
    let mutate: ((inout Agent) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Osaurus can read and write \(agent.workingFolderPath ?? "")."))
            } else {
                StepIssueList(items: items)
                if let hint = agent.workingFolderPath {
                    Text("Hint from the agent's author: \(hint)", bundle: .module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                StepActionButton(title: "Choose Folder…", icon: "folder.badge.plus") { chooseFolder() }
                OrSeparator()
                StepActionButton(title: "Remove Working Folder", icon: "folder.badge.minus", primary: false) {
                    mutate {
                        $0.workingFolderBookmark = nil
                        $0.workingFolderPath = nil
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func chooseFolder() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = L("Select Working Folder")
            panel.message = L("Choose the folder this agent works inside.")
            panel.prompt = L("Select")
            if let hint = agent.workingFolderPath {
                let expanded = (hint as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                    panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
                }
            }
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            // Intel: no security-scoped bookmark, the path alone is the grant.
            let path = url.standardizedFileURL.path
            RecentFoldersStore.shared.record(path: path)
            mutate {
                $0.workingFolderBookmark = nil
                $0.workingFolderPath = path
            }
        }
    }
}

// MARK: - Unavailable (Intel)

/// A step upstream offers that Intel cannot: shown dimmed with the reason,
/// so the user sees it exists rather than wondering where it went.
private struct UnavailableStep: View {
    @Environment(\.theme) private var theme
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "nosign")
                .foregroundColor(theme.tertiaryText)
                .padding(.top, 1)
            Text(reason)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.4)))
        .opacity(0.7)
    }
}

// MARK: - Tools

private struct ToolsStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [SetupItem]
    let mutate: ((inout Agent) -> Void) -> Void
    /// Parks the wizard (and an unsaved draft) before switching tabs; a
    /// bare tab switch tears the sheet down and loses the draft.
    let onLeave: (ManagementTab) -> Void

    private var missingNames: [String] {
        items.flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every tool this agent lists is available here."))
            } else {
                StepIssueList(items: items)
                if !missingNames.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(missingNames, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Capsule().fill(theme.tertiaryBackground))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                StepActionButton(title: "Open MCP Servers", icon: "server.rack") {
                    onLeave(.tools)
                }
                StepActionButton(title: "Open Plugins", icon: "puzzlepiece.extension") {
                    onLeave(.plugins)
                }
                OrSeparator()
                StepActionButton(title: "Remove Missing Tools", icon: "minus.circle", primary: false) {
                    let missing = Set(missingNames)
                    mutate { $0.manualToolNames = ($0.manualToolNames ?? []).filter { !missing.contains($0) } }
                }
                .disabled(items.isEmpty)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Review

private struct ReviewStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let report: SetupReport
    let isDraft: Bool
    /// Draft mode: the plan `osaurus_config` would show for the template.
    var planText: String?
    var planHasHighRisk: Bool = false
    @Binding var reviewedRisks: Bool
    let onRename: (String) -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isDraft {
                VStack(alignment: .leading, spacing: 6) {
                    AgentSheetSectionLabel("Agent Name")
                    StyledTextField(placeholder: L("e.g., Invoice Bot"), text: $name, icon: "textformat")
                        .onChange(of: name) { newValue in onRename(newValue) }
                }
                summary
                if let planText, !planText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        AgentSheetSectionLabel("Plan")
                        ScrollView {
                            Text(planText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.6)))
                        if planHasHighRisk {
                            Toggle(isOn: $reviewedRisks) {
                                Text("I reviewed the risks above", bundle: .module)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            if report.isClean {
                StepDoneBanner(
                    text: isDraft
                        ? L("Everything this template needs is in place. Create the agent when you are ready.")
                        : L("Everything checks out. The agent is ready to use."))
            } else if report.hasBlockers {
                Text(
                    isDraft
                        ? "Some items still block this agent. Go back to fix them before creating it."
                        : "Some items still block this agent. Go back to fix them, or choose Later to keep the agent as is.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                AgentSetupChecklistView(report: report)
            } else {
                Text("Nothing blocks this agent. The notes below are worth a look but do not stop it from running.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                AgentSetupChecklistView(report: report)
            }
        }
        .onAppear { if name.isEmpty { name = agent.name } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("What Will Be Created")
            VStack(alignment: .leading, spacing: 4) {
                row("cube", agent.defaultModel.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? L("Default Model"))
                if agent.toolSelectionMode == .manual {
                    let toolCount = agent.manualToolNames?.count ?? 0
                    row("wrench.and.screwdriver", toolCount == 1 ? L("1 tool") : L("\(toolCount) tools"))
                } else {
                    row("sparkles", L("Auto tools"))
                }
                if agent.autonomousExec?.enabled == true { row("shippingbox", L("Sandbox on")) }
                if agent.settings.spawnDelegationEnabled { row("person.2", L("Can use subagents")) }
                if agent.memoryEnabled { row("brain", L("Memory on")) }
                if let path = agent.workingFolderPath, !path.isEmpty { row("folder", path) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.6)))
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(theme.tertiaryText).frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundColor(theme.secondaryText).lineLimit(1).truncationMode(.middle)
        }
    }
}
