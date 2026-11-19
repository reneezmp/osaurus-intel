//
//  BundleImportSheet.swift
//  osaurus
//
//  Review and import Osaurus bundles (W-osaurus-bundles stage 4, upstream
//  Classic #3174). Upstream has no screen for this: an installer script runs
//  `osaurus import` and a toast says the agents are ready. On Intel the same
//  queue (`~/.osaurus/import/pending`) is applied from here, because nothing
//  in a bundle may land without the user's approval in the app:
//
//   - Choose Bundle Folder... checks the folder (`OsaurusBundle.load`: strict
//     manifest, paths confined to the folder, size caps) and queues it. It
//     applies nothing and runs nothing.
//   - Every queued request (from this button or from `osaurus import`) shows
//     the plan: what would be created, updated or removed, the declarative
//     planner's field lines and the high-risk lines. Only Apply imports it;
//     Remove from Queue forgets it.
//
//  Plain controls that exist on macOS 13 (no `.segmented` / `.bordered`).
//

import AppKit
import OsaurusRepository
import SwiftUI

struct BundleImportSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let onClose: () -> Void

    @State private var pending: [PendingImport] = []
    @State private var results: [String: ImportResult] = [:]
    @State private var message: String?
    @State private var busyRequest: String?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if pending.isEmpty && results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(pending, id: \.request.id) { item in
                            requestCard(item)
                        }
                        ForEach(results.keys.sorted(), id: \.self) { id in
                            if let result = results[id] { resultCard(result) }
                        }
                    }
                    .padding(20)
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear(perform: reload)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Import Osaurus Bundle"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(L("Review what a bundle would add before anything is installed."))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button(L("Choose Bundle Folder…"), action: chooseFolder)
            Button(L("Done"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText)
            Text(L("No bundles waiting"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                L(
                    "Choose a bundle folder (it has an osaurus-bundle.json), or run osaurus import in Terminal. Nothing is installed until you apply it here."
                )
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func requestCard(_ item: PendingImport) -> some View {
        let request = item.request
        let plan = PendingImportProcessor.shared.review(item)
        let busy = busyRequest == request.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(request.bundleName ?? request.bundleId)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                if let version = request.bundleVersion {
                    Text("v\(version)").font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                }
                Spacer()
            }
            Text(request.bundleId)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            if plan.isEmpty {
                Text(L("Nothing would change: everything in it is already installed or cannot be applied."))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            } else {
                ForEach(Array(plan.actions.enumerated()), id: \.offset) { _, action in
                    actionRow(action)
                }
            }
            HStack(spacing: 8) {
                Button(plan.hasHighRiskChanges ? L("Apply (High Risk)") : L("Apply")) {
                    apply(item)
                }
                .disabled(busy)
                Button(L("Remove from Queue")) { dismiss(item) }
                    .disabled(busy)
                if busy { Text(L("Applying…")).font(.system(size: 11)).foregroundColor(theme.tertiaryText) }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
    }

    private func actionRow(_ action: ConfigPlanAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(symbol(action.kind)) \(action.target)  ·  \(action.section)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            ForEach(action.changes, id: \.self) { change in
                Text(change).font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(action.risks, id: \.self) { risk in
                Text("! \(risk)").font(.system(size: 11)).foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultCard(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Result for \(result.bundleId)"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
                Text("\(item.kind.rawValue)/\(item.name): \(item.status.rawValue)" + (item.message.map { " — \($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundColor(item.status == .failed ? theme.errorColor : theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
    }

    private func symbol(_ kind: ConfigPlanAction.Kind) -> String {
        switch kind {
        case .create: return "+"
        case .update: return "~"
        case .delete: return "-"
        case .needsUserInput: return "?"
        }
    }

    // MARK: - Actions

    private func reload() {
        pending = ImportQueue.pending()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = L("Choose a folder that contains osaurus-bundle.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        queue(folder: url)
    }

    /// Checks the folder and queues every item in it. Applies nothing.
    private func queue(folder: URL) {
        do {
            let bundle = try OsaurusBundle.load(from: folder)
            let refs = try bundle.select(kind: nil, names: [])
            let request = ImportRequest(
                bundleId: bundle.id, bundleName: bundle.manifest.name, bundleVersion: bundle.manifest.version,
                operations: refs.map {
                    ImportOperation(action: .install, kind: $0.kind, name: $0.name, explicit: $0.explicit)
                },
                confirmHighRisk: false)
            try ImportQueue.enqueue(request, bundle: bundle)
            message = L("Queued \"\(bundle.manifest.name)\". Review it below.")
            reload()
        } catch let error as OsaurusBundleError {
            message = error.issues.joined(separator: " ")
        } catch {
            message = error.localizedDescription
        }
    }

    /// The user's Apply click is the approval: the plan is on screen above it.
    private func apply(_ item: PendingImport) {
        let id = item.request.id
        busyRequest = id
        Task { @MainActor in
            let outcome = await PendingImportProcessor.shared.process(requestId: id, approver: { _ in .approved })
            busyRequest = nil
            if case .completed(let result)? = outcome {
                results[id] = result
            } else {
                message = L("That import could not be applied. It is still queued.")
            }
            reload()
            await PendingImportProcessor.shared.applyDeferredSettings()
        }
    }

    private func dismiss(_ item: PendingImport) {
        _ = ImportQueue.cancelPending(bundleId: item.request.bundleId)
        message = L("Removed \"\(item.request.bundleName ?? item.request.bundleId)\" from the queue.")
        reload()
    }
}
