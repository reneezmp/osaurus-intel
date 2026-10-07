//
//  CloudModelBrowserDialog.swift
//  osaurus
//
//  The live Osaurus Cloud catalog. Favorites use the same store as the
//  compact chat picker; choosing a model dismisses this dialog.
//
//  Intel adaptations:
//  - Keyboard: no `FocusState` / `onKeyPress` (macOS 14). ↑↓ move a
//    highlighted row and Return selects it through `PickerCardKeyMonitor`
//    (inactive while the search field is editing); Escape closes.
//  - No offline monitor on Intel (offline reads as a load failure), and
//    refresh goes through `connectOsaurusRouterIfPossible()`.
//  - The identity check runs once on appear (`OsaurusIdentity.exists()`).
//  - No media models, so rows show no "From …" price (upstream prices media
//    only) and image/video categories never appear.
//  - Themed bordered buttons (Ventura guard).
//

import AppKit
import SwiftUI

struct CloudModelBrowserDialog: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let onDismiss: () -> Void
    let onManageCloud: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    @ObservedObject private var favoritesStore = FavoriteModelsStore.shared
    @State private var searchText = ""
    @State private var contextFilter: ModelPickerContextFilter = .any
    @State private var categoryFilter: CloudModelCategory = .all
    @State private var isRefreshing = false
    @State private var refreshFailed = false
    @State private var keyboardNavigation = false
    /// Keyboard-highlighted row (Intel key monitor).
    @State private var highlightedModelID: String?
    @State private var hasIdentity = true

    private var providerState: RemoteProviderState? {
        providerManager.providerStates[RemoteProviderManager.osaurusRouterProviderId]
    }

    private var catalog: [ModelPickerItem] {
        options.filter { item in
            guard case .remote(_, let providerID) = item.source else { return false }
            return providerID == RemoteProviderManager.osaurusRouterProviderId
        }
        .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        // Derive one snapshot per dialog update, not once per consumer.
        // Row hover is owned by the leaf row and never invalidates this work.
        let catalog = catalog
        let categories = CloudModelCategory.available(in: catalog)
        let results = catalog
            .filter { $0.matches(searchQuery: searchText) }
            .filteredByContext(contextFilter)
            .filter(categoryFilter.includes)
        let canBrowse = providerManager.isOsaurusRouterEnabled && !catalog.isEmpty

        VStack(spacing: 0) {
            header
            if canBrowse {
                searchAndFilters(categories: categories)
                if refreshFailed {
                    Text("Couldn't refresh. Showing the last available catalog.", bundle: .module)
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                Divider()
                if results.isEmpty {
                    searchEmptyState
                } else {
                    modelList(results: results)
                }
            } else {
                catalogStatus
            }
            Divider()
            footer(canBrowse: canBrowse, resultCount: results.count)
        }
        .frame(minWidth: 540, idealWidth: 640, maxWidth: 760, minHeight: 440, idealHeight: 600, maxHeight: 720)
        .background(theme.primaryBackground)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onExitCommand(perform: onDismiss)
        .background(
            PickerCardKeyMonitor { key in
                keyboardNavigation = true
                switch key {
                case .up: moveHighlight(by: -1, results: results)
                case .down: moveHighlight(by: 1, results: results)
                case .return:
                    guard let id = highlightedModelID, let model = results.first(where: { $0.id == id }) else {
                        return false
                    }
                    selectModel(model)
                case .left, .right: return false
                }
                return true
            }
        )
        .onAppear {
            keyboardNavigation = NSApp.currentEvent?.type == .keyDown
            hasIdentity = OsaurusIdentity.exists()
        }
        .task {
            // Opening the compact picker already refreshes connected providers
            // and publishes its catalog. Do not repeat that work during this
            // sheet's entrance; fetch here only when there is nothing to show.
            if catalog.isEmpty { await refreshCatalog() }
        }
        .onChange(of: categories) { available in
            if !available.contains(categoryFilter) { categoryFilter = .all }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Osaurus Cloud", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.headingSize), weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Select a model to use it now. Star it to keep it in your list.", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize)))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(CloudCloseButtonStyle())
            .accessibilityLabel(Text("Close", bundle: .module))
            .help(L("Close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func searchAndFilters(categories: [CloudModelCategory]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField(L("Search model name or provider"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(theme.font(size: CGFloat(theme.bodySize)))
                .accessibilityLabel(Text("Search model name or provider", bundle: .module))
            HStack(spacing: 16) {
                Picker(selection: $categoryFilter) {
                    ForEach(categories) { category in
                        Text(LocalizedStringKey(category.label), bundle: .module).tag(category)
                    }
                } label: {
                    Text("Category", bundle: .module)
                }
                Picker(selection: $contextFilter) {
                    ForEach(ModelPickerContextFilter.allCases) { filter in
                        Text(LocalizedStringKey(filter.label), bundle: .module).tag(filter)
                    }
                } label: {
                    Text("Context", bundle: .module)
                }
            }
            .pickerStyle(.menu)
            .font(theme.font(size: CGFloat(theme.captionSize)))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    private func modelList(results: [ModelPickerItem]) -> some View {
        ScrollViewReader { proxy in
            // Selection is an explicit button action. Native List selection would
            // paint an accent background and conflate arrow navigation with activation.
            List {
                ForEach(results) { model in
                    CloudModelBrowserRow(
                        model: model,
                        isSelected: selectedModel == model.id,
                        isFavorite: favoritesStore.isFavorite(model.favoriteKey),
                        isHighlighted: keyboardNavigation && highlightedModelID == model.id,
                        onSelect: { selectModel(model) },
                        onToggleFavorite: { favoritesStore.toggle(model.favoriteKey) }
                    )
                    // ForEach supplies stable identity for scrolling. An extra .id
                    // forces List to resolve every row up front on macOS.
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityLabel(Text("Cloud models", bundle: .module))
            .onChange(of: highlightedModelID) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func selectModel(_ model: ModelPickerItem) {
        selectedModel = model.id
        onDismiss()
    }

    private func moveHighlight(by offset: Int, results: [ModelPickerItem]) {
        guard !results.isEmpty else { return }
        let index = highlightedModelID.flatMap { id in results.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + offset, 0), results.count - 1) } ?? (offset > 0 ? 0 : results.count - 1)
        highlightedModelID = results[next].id
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Text("No models match", bundle: .module)
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
            Text("Try another search or clear your filters.", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundStyle(theme.secondaryText)
            Button {
                searchText = ""
                contextFilter = .any
                categoryFilter = .all
            } label: {
                Text("Clear search and filters", bundle: .module)
            }
            .buttonStyle(ThemedBorderedButtonStyle())  // Intel: Ventura
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var catalogStatus: some View {
        VStack(spacing: 12) {
            if !providerManager.isOsaurusRouterEnabled {
                statusText("Osaurus Cloud is off", detail: "Open Credits to enable Osaurus Cloud.")
            } else if isRefreshing || providerState?.isConnecting == true {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading Cloud models", bundle: .module))
                statusText("Loading Cloud models…", detail: "The catalog will appear when the connection is ready.")
            } else if refreshFailed || providerState?.lastError != nil {
                statusText("Couldn't load Cloud models", detail: "Try again, or open Credits to review your Cloud settings.")
                retryButton
            } else if !hasIdentity {
                statusText("Set up Osaurus Cloud", detail: "Open Credits to set up your Cloud account.")
            } else {
                statusText("No Cloud models available", detail: "Refresh the catalog, or open Credits to review your Cloud settings.")
                retryButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func statusText(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Text(title, bundle: .module)
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text(detail, bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var retryButton: some View {
        Button {
            Task { await refreshCatalog() }
        } label: {
            Text("Try again", bundle: .module)
        }
        .buttonStyle(ThemedBorderedButtonStyle())  // Intel: Ventura
    }

    private func footer(canBrowse: Bool, resultCount: Int) -> some View {
        HStack(spacing: 16) {
            Button(action: onManageCloud) {
                Text("Manage Credits", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize)))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(CloudSecondaryButtonStyle())
            .controlSize(.small)
            Spacer()
            if canBrowse {
                Group {
                    if resultCount == 1 {
                        Text("1 model", bundle: .module)
                    } else {
                        Text("\(resultCount) models", bundle: .module)
                    }
                }
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func refreshCatalog() async {
        guard !isRefreshing, providerManager.isOsaurusRouterEnabled, hasIdentity else { return }
        isRefreshing = true
        refreshFailed = false
        defer { isRefreshing = false }
        // Intel: one path refreshes or connects the Router catalog.
        await providerManager.connectOsaurusRouterIfPossible()
        refreshFailed = providerState?.discoveredModels.isEmpty ?? true
        await ModelPickerItemCache.shared.buildModelPickerItems()
    }
}

/// Keeps pointer movement local to the visible row, so scrolling through the
/// catalog does not rerun the dialog's filters or reconstruct sibling rows.
private struct CloudModelBrowserRow: View {
    let model: ModelPickerItem
    let isSelected: Bool
    let isFavorite: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let favoriteActionLabel =
            isFavorite
            ? Text("Remove \(model.displayName) from favorites", bundle: .module)
            : Text("Add \(model.displayName) to favorites", bundle: .module)
        return HStack(alignment: .center, spacing: 0) {
            Button {
                onSelect()
            } label: {
                modelRowLabel(model, isSelected: isSelected)
                    // Include the breathing room in the model's click target.
                    .padding(.trailing, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Button {
                onToggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isFavorite ? theme.accentColor : theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ModelFavoriteButtonStyle())
            .accessibilityLabel(favoriteActionLabel)
            .accessibilityValue(isFavorite ? L("Saved") : L("Not saved"))
            .help(isFavorite ? L("Remove from favorites") : L("Add to favorites"))
        }
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.primaryText.opacity(isSelected || isHovered || isHighlighted ? 0.04 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Keep separators at the row edge instead of an inner media or vision Label.
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading]
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.displayName)
        .accessibilityAction(named: favoriteActionLabel) {
            onToggleFavorite()
        }
    }

    private func modelRowLabel(_ model: ModelPickerItem, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                .frame(width: 16)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                        .lineLimit(1)
                    if let category = CloudModelCategory.displayCategory(for: model) {
                        CloudCategoryTag(category: category)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if let price = modelPrice(model) {
                    Text(price)
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(model.displayName)
        }
        .foregroundStyle(theme.primaryText)
    }

    /// Upstream prices media models only; Intel has none yet.
    private func modelPrice(_ model: ModelPickerItem) -> String? { nil }

}

/// Matches the chat attachment button's circular hover treatment. Keeping hover
/// inside the style avoids rebuilding the Cloud catalog when Close is hovered.
private struct CloudCloseButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? theme.accentColor : theme.secondaryText)
            .background {
                ZStack {
                    Circle()
                        .fill(theme.tertiaryBackground.opacity(isHovered ? 0.95 : 0.8))
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.1), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(isHovered ? 1 : 0)
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.25 : 0.15),
                                theme.primaryBorder.opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
            .contentShape(Circle())
            .onHover { isHovered = $0 }
    }
}
