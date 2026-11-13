//
//  ClaudePluginsMarketplaceView.swift
//  osaurus
//
//  The Claude-plugin marketplace surface shown by the Skills page's
//  "Claude Plugins" tab (category chips, install cards, detail overlays).
//  Extracted from upstream Classic's `PluginsView.swift`, whose Intel
//  counterpart is the native-plugin page; `W-skills-plugins-import`.
//

import SwiftUI

// MARK: - Marketplace Category Chips

/// Horizontal, scrollable filter chips for the Claude marketplace. The first
/// chip ("All") clears the filter; each category chip shows its plugin count
/// and adopts the shared category palette color when selected.
private struct MarketplaceCategoryChips: View {
    @Environment(\.theme) private var theme

    let categories: [ClaudeMarketplaceCategory]
    let totalCount: Int
    @Binding var selected: String?

    /// Stable scroll id for the "All" chip, whose category key is `nil`.
    private let allChipID = "__all__"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(key: nil, label: L("All"), count: totalCount, color: theme.accentColor)
                        .id(allChipID)
                    ForEach(categories) { category in
                        chip(
                            key: category.id,
                            label: category.displayName,
                            count: category.count,
                            color: ClaudeMarketplacePalette.color(for: category.id)
                        )
                        .id(category.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            // Bring the tapped pill fully into view so the user can walk
            // between the extremes of the category list.
            .onChange(of: selected) { newValue in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    proxy.scrollTo(newValue ?? allChipID, anchor: .center)
                }
            }
        }
    }

    private func chip(key: String?, label: String, count: Int, color: Color) -> some View {
        let isSelected = selected == key
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selected = key
            }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundColor(isSelected ? .white.opacity(0.85) : theme.tertiaryText)
            }
            .foregroundColor(isSelected ? .white : theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? color : theme.tertiaryBackground)
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Color.clear : theme.cardBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Marketplace Skeleton Card

/// Subtle shimmering placeholder shown while the marketplace catalog loads,
/// so the Browse tab feels alive instead of blank.
private struct MarketplaceSkeletonCard: View {
    @Environment(\.theme) private var theme
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.tertiaryBackground)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 120, height: 12)
                    bar(width: 64, height: 9)
                }
                Spacer()
            }
            bar(width: nil, height: 10)
            bar(width: 220, height: 10)
            Spacer(minLength: 0)
            bar(width: 90, height: 9)
        }
        .frame(height: 132, alignment: .top)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        .opacity(shimmer ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }

    @ViewBuilder
    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(theme.tertiaryBackground)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

// MARK: - Claude Plugins Marketplace (shared with the Skills manager)

/// The Claude-plugin marketplace discovery surface (category chips, install
/// cards, and detail overlays), extracted so the Skills manager can present
/// the same "Claude Plugins" tab as the Plugins section. Owns its own
/// marketplace filtering, install flow, and detail navigation; the parent
/// supplies only the shared header search query.
struct ClaudePluginsMarketplaceView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var claudeMarketplace = ClaudeMarketplaceService.shared
    @StateObject private var claudeAggregator = InstalledClaudePluginsAggregator()

    private let claudeSkillManager = SkillManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// Shared header search query from the hosting view.
    let searchText: String

    /// Incremented by the host after an out-of-band install (e.g. the GitHub
    /// import sheet) so installed state is re-read.
    var installGeneration: Int = 0

    @State private var hasAppeared = false
    @State private var selectedCategory: String?
    @State private var filteredMarketplaceEntries: [MarketplacePlugin] = []
    @State private var marketplaceChipCounts: (total: Int, byCategory: [String: Int])?
    @State private var selectedMarketplaceEntry: MarketplacePlugin?
    @State private var selectedClaudePlugin: ClaudePluginInstalled?
    @State private var userConfigTarget: ClaudePluginInstalled?
    @State private var showUserConfigSheet = false
    @State private var successMessage: String?

    private var responsiveGrid: [GridItem] {
        [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)]
    }

    var body: some View {
        ZStack {
            if selectedMarketplaceEntry == nil && selectedClaudePlugin == nil {
                marketplaceContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            marketplaceDetailOverlay
            claudeDetailOverlay
            successToastOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            claudeMarketplace.loadIfNeeded()
            Task { await claudeAggregator.checkForUpdates() }
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) { hasAppeared = true }
            Task { await updateFilteredEntries() }
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await updateFilteredEntries()
        }
        .onChange(of: selectedCategory) { _ in Task { await updateFilteredEntries() } }
        .onChange(of: installGeneration) { _ in
            claudeAggregator.refresh()
            Task { await claudeAggregator.checkForUpdates() }
        }
        .onReceive(claudeMarketplace.$entries) { _ in Task { await updateFilteredEntries() } }
        .onReceive(claudeAggregator.$plugins) { _ in Task { await updateFilteredEntries() } }
        .sheet(isPresented: $showUserConfigSheet) {
            if let target = userConfigTarget, let snap = target.snapshot {
                ClaudePluginUserConfigSheet(
                    pluginId: target.pluginId,
                    pluginName: target.displayName,
                    pluginVersion: target.version,
                    fields: snap.userConfigSpec,
                    onSave: {
                        showUserConfigSheet = false
                        claudeAggregator.refresh()
                    }
                )
            }
        }
    }

    // MARK: Content

    private var marketplaceContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Claude plugin installs and update checks go through the
                // GitHub API, so surface token status here as well.
                GitHubTokenCard()
                if !claudeMarketplace.categories.isEmpty {
                    MarketplaceCategoryChips(
                        categories: claudeMarketplace.categories.map { category in
                            ClaudeMarketplaceCategory(
                                id: category.id,
                                count: marketplaceChipCounts?.byCategory[category.id] ?? category.count
                            )
                        },
                        totalCount: marketplaceChipCounts?.total ?? claudeMarketplace.entries.count,
                        selected: $selectedCategory
                    )
                }
                marketplaceSection
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var marketplaceSection: some View {
        if claudeMarketplace.isLoading && claudeMarketplace.entries.isEmpty {
            LazyVGrid(columns: responsiveGrid, spacing: 20) {
                ForEach(0 ..< 6, id: \.self) { _ in MarketplaceSkeletonCard() }
            }
        } else if let error = claudeMarketplace.lastError, claudeMarketplace.entries.isEmpty {
            marketplaceErrorView(error)
        } else if filteredMarketplaceEntries.isEmpty {
            marketplaceEmptyView
        } else {
            LazyVGrid(columns: responsiveGrid, spacing: 20) {
                ForEach(Array(filteredMarketplaceEntries.enumerated()), id: \.element.name) { index, entry in
                    ClaudeMarketplaceCard(
                        entry: entry,
                        animationDelay: Double(min(index, 12)) * 0.04,
                        hasAppeared: hasAppeared,
                        onSelect: { openMarketplaceEntry(entry) },
                        onInstall: { try await installMarketplaceEntry(entry) }
                    )
                }
            }
        }
    }

    private func marketplaceErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 14))
                    .foregroundColor(theme.warningColor)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.warningColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                    )
            )
            Button(action: { Task { await claudeMarketplace.refresh() } }) {
                Text("Retry", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(claudeMarketplace.isLoading)
        }
    }

    private var marketplaceEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text(
                searchText.isEmpty
                    ? "No plugins in this category yet"
                    : "No plugins match your search",
                bundle: .module
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: Detail overlays

    @ViewBuilder
    private var marketplaceDetailOverlay: some View {
        if let entry = selectedMarketplaceEntry {
            ClaudeMarketplaceDetailView(
                entry: entry,
                onBack: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedMarketplaceEntry = nil
                    }
                },
                onInstall: {
                    try await installMarketplaceEntry(entry)
                    if let installed = installedClaudePlugin(for: entry) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedMarketplaceEntry = nil
                            selectedClaudePlugin = installed
                        }
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    @ViewBuilder
    private var claudeDetailOverlay: some View {
        if let claudePlugin = selectedClaudePlugin {
            ClaudePluginDetailView(
                plugin: claudePlugin,
                onBack: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedClaudePlugin = nil
                    }
                },
                onUpdate: { try await updateClaudePlugin(claudePlugin) },
                onUninstall: {
                    await uninstallClaudePlugin(claudePlugin)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedClaudePlugin = nil
                    }
                },
                onConfigure: {
                    userConfigTarget = claudePlugin
                    showUserConfigSheet = true
                },
                onChange: {
                    claudeAggregator.refresh()
                    Task { await updateFilteredEntries() }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    @ViewBuilder
    private var successToastOverlay: some View {
        if let message = successMessage {
            VStack {
                Spacer()
                ThemedToastView(message, type: .success)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
            .zIndex(100)
        }
    }

    // MARK: Helpers

    private func installedClaudePlugin(for entry: MarketplacePlugin) -> ClaudePluginInstalled? {
        guard let id = claudeMarketplace.pluginId(for: entry) else { return nil }
        return claudeAggregator.plugins.first { $0.pluginId == id }
    }

    private func openMarketplaceEntry(_ entry: MarketplacePlugin) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let installed = installedClaudePlugin(for: entry) {
                selectedClaudePlugin = installed
            } else {
                selectedMarketplaceEntry = entry
            }
        }
    }

    private func installMarketplaceEntry(_ entry: MarketplacePlugin) async throws {
        let report = try await claudeMarketplace.install(entry: entry)
        await claudeSkillManager.refresh()
        claudeAggregator.refresh()
        await updateFilteredEntries()
        if let report {
            let total =
                report.totalImportedSkills + report.totalImportedAgents
                + report.totalImportedCommands + report.totalImportedMCPProviders
            let baseMessage =
                total > 0
                ? L("Installed \(total) items from \(entry.name)")
                : L("Installed \(entry.name)")
            let message =
                report.requiresAttention
                ? "\(baseMessage); \(report.totalAttentionItems) need review"
                : baseMessage
            showSuccess(message)
        }
    }

    private func updateClaudePlugin(_ plugin: ClaudePluginInstalled) async throws {
        guard let snap = plugin.snapshot else { return }
        let repo = GitHubRepo(
            owner: snap.sourceOwner,
            name: snap.sourceRepo,
            branch: snap.sourceBranch ?? "main"
        )
        let url = "https://github.com/\(snap.sourceOwner)/\(snap.sourceRepo)"
        let result = try await GitHubSkillService.shared.fetchPlugins(from: url)
        guard let manifest = result.plugins.first(where: { $0.name == snap.name }) else {
            throw GitHubSkillError.noSkillsFound
        }
        let selection = ClaudePluginSelection(manifest: manifest)
        _ = await ClaudePluginInstaller.shared.install(
            selections: [selection],
            from: repo,
            replaceExisting: true
        )
        await claudeSkillManager.refresh()
        claudeAggregator.refresh()
        await updateFilteredEntries()
    }

    private func uninstallClaudePlugin(_ plugin: ClaudePluginInstalled) async {
        _ = await ClaudePluginInstaller.shared.uninstall(pluginId: plugin.pluginId)
        await claudeSkillManager.refresh()
        claudeAggregator.refresh()
        await updateFilteredEntries()
    }

    /// Search + category filter over the marketplace entries. Mirrors the
    /// marketplace slice of `PluginsView.updateFilteredLists`, excluding
    /// already-installed entries (they open the installed detail on tap).
    private func updateFilteredEntries() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentClaudePlugins = claudeAggregator.plugins
        let currentMarketplace = claudeMarketplace.entries
        let category = selectedCategory
        let installedPluginIds = Set(currentClaudePlugins.map { $0.pluginId })
        let marketplaceRepo = claudeMarketplace.repo

        let (entries, counts) = await Task.detached(priority: .userInitiated) {
            let searchMatched = currentMarketplace.filter { entry in
                let isInstalled: Bool = {
                    guard let marketplaceRepo else { return false }
                    let id = ClaudePluginInstaller.pluginId(
                        repo: marketplaceRepo,
                        pluginName: entry.name
                    )
                    return installedPluginIds.contains(id)
                }()
                return !isInstalled && ClaudePluginsMarketplaceView.entryMatchesQuery(entry, query: query)
            }
            let filtered =
                searchMatched
                .filter {
                    category == nil || ClaudeMarketplaceService.categoryKey(for: $0) == category
                }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            var byCategory: [String: Int] = [:]
            for entry in searchMatched {
                byCategory[ClaudeMarketplaceService.categoryKey(for: entry), default: 0] += 1
            }
            return (filtered, (total: searchMatched.count, byCategory: byCategory))
        }.value

        guard !Task.isCancelled else { return }
        filteredMarketplaceEntries = entries
        marketplaceChipCounts = counts
    }

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }
}

extension ClaudePluginsMarketplaceView {
    /// Search over a marketplace entry's name, keywords, description, author
    /// and category. Upstream uses `SearchService` (not compiled on Intel);
    /// this is a case-insensitive substring match over the same fields.
    nonisolated static func entryMatchesQuery(_ entry: MarketplacePlugin, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var fields: [String] = [entry.name]
        fields.append(contentsOf: entry.keywords ?? [])
        if let description = entry.description { fields.append(description) }
        if let author = entry.author?.name { fields.append(author) }
        if let category = entry.category { fields.append(category) }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
