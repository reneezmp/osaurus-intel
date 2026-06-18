#if !OSAURUS_INTEL
//
//  ModelPickerView.swift
//  osaurus
//
//  A rich model picker with search, grouped sections, and metadata display.
//

import SwiftUI

struct ModelPickerView: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let agentId: UUID?
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var collapsedGroups: Set<String> = []
    @State private var cachedGroupedOptions: [(source: ModelPickerItem.Source, models: [ModelPickerItem])] = []
    @State private var cachedFlattenedRows: [ModelPickerRow] = []
    @State private var cachedGroupRows: [String: [ModelPickerRow]] = [:]
    @Environment(\.theme) private var theme

    // MARK: - Test Mode

    #if DEBUG
        // set USE_MOCK_MODELS=1 in Xcode scheme to automatically use mock data
        private var useMockData: Bool {
            ProcessInfo.processInfo.environment["USE_MOCK_MODELS"] == "1"
        }

        private var displayOptions: [ModelPickerItem] {
            useMockData ? ModelPickerItem.generateMockModels(count: 500) : options
        }
    #else
        private var displayOptions: [ModelPickerItem] { options }
    #endif

    // MARK: - Data

    private func recomputeRows() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [(source: ModelPickerItem.Source, models: [ModelPickerItem])]

        if query.isEmpty {
            groups = cachedGroupedOptions
        } else {
            groups = cachedGroupedOptions.compactMap { group in
                let groupMatches = SearchService.matches(query: query, in: group.source.displayName)
                let matchedModels = group.models.filter {
                    SearchService.matches(query: query, in: $0.displayName)
                        || SearchService.matches(query: query, in: $0.id)
                }
                if groupMatches { return group }
                if !matchedModels.isEmpty {
                    return (source: group.source, models: matchedModels)
                }
                return nil
            }
        }

        var rows: [ModelPickerRow] = []
        // preallocate to reduce allocations
        rows.reserveCapacity(groups.count * 20)

        for group in groups {
            let sourceKey = group.source.uniqueKey
            let expanded = !query.isEmpty || !collapsedGroups.contains(sourceKey)

            rows.append(
                .groupHeader(
                    sourceKey: sourceKey,
                    displayName: group.source.displayName,
                    sourceType: group.source,
                    count: group.models.count,
                    isExpanded: expanded
                )
            )

            if expanded {
                // check if we have cached model rows for this group
                let cacheKey = sourceKey + "_\(group.models.count)"
                if let cachedModelRows = cachedGroupRows[cacheKey], query.isEmpty {
                    rows.append(contentsOf: cachedModelRows)
                } else {
                    var modelRows: [ModelPickerRow] = []
                    modelRows.reserveCapacity(group.models.count)

                    for model in group.models {
                        let row = ModelPickerRow.model(
                            id: model.id,
                            sourceKey: sourceKey,
                            displayName: model.displayName,
                            description: model.description,
                            parameterCount: model.parameterCount,
                            quantization: model.quantization,
                            isVLM: model.isVLM
                        )
                        modelRows.append(row)
                    }

                    // cache model rows when not searching
                    if query.isEmpty {
                        cachedGroupRows[cacheKey] = modelRows
                    }
                    rows.append(contentsOf: modelRows)
                }
            }
        }
        cachedFlattenedRows = rows
    }

    private func toggleGroup(_ source: ModelPickerItem.Source) {
        let key = source.uniqueKey
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
        // onChange(of: collapsedGroups) will trigger recomputeRows()
    }

    // MARK: - Body

    private var selectedModelReplacement: String? {
        guard let id = selectedModel else { return nil }
        return ModelManager.replacementForDeprecatedModel(id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if let replacement = selectedModelReplacement {
                deprecationBanner(replacement: replacement)
            }

            if cachedFlattenedRows.isEmpty {
                emptyState
            } else {
                modelList
            }
        }
        .frame(width: 380, height: min(CGFloat(displayOptions.count * 48 + 160), 480))
        .background(popoverBackground)
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
        .onAppear {
            cachedGroupedOptions = displayOptions.groupedBySource()
            recomputeRows()
        }
        .task {
            // refresh remote model lists on open so newly-added/removed
            // models surface
            await RemoteProviderManager.shared.refreshConnectedProviders()

            // Drop external models (HF cache, LM Studio) the user deleted on
            // disk while the app stayed running — the picker cache is built
            // once and only rebuilds on `.localModelsChanged`, which this
            // posts when something went missing. Cheap existence check; no-op
            // when nothing changed. Runs last since it's the lowest priority.
            await Task.detached(priority: .utility) {
                ExternalModelLocator.pruneMissing()
            }.value
        }
        .onDisappear {
            searchDebounceTask?.cancel()
        }
        .onChange(of: displayOptions.count) { _ in
            cachedGroupedOptions = displayOptions.groupedBySource()
            recomputeRows()
        }
        .onChange(of: searchText) { newValue in
            searchDebounceTask?.cancel()
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recomputeRows()
            } else {
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    recomputeRows()
                }
            }
        }
        .onChange(of: collapsedGroups) { _ in
            // debounce to avoid multiple rapid toggles
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                recomputeRows()
            }
        }
    }

    // MARK: - Background & Border

    private var popoverBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.primaryBackground)
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Available Models", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("\(displayOptions.count)", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.secondaryBackground))

            Spacer()

            Button(action: {
                onDismiss()
                Task { @MainActor in
                    try? await Task.sleepForPopoverDismiss()
                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Add Model", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
                        .background(Capsule().fill(theme.accentColor.opacity(0.08)))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text("Search models...", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $searchText)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
            }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    // MARK: - Deprecation Banner

    private func deprecationBanner(replacement: String) -> some View {
        Button(action: {
            onDismiss()
            Task { @MainActor in
                try? await Task.sleepForPopoverDismiss()
                AppDelegate.shared?.showManagementWindow(initialTab: .models)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)

                Text("Selected model is outdated.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Text("Update", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No models found", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Model List

    private var modelList: some View {
        ModelPickerTableRepresentable(
            rows: cachedFlattenedRows,
            theme: theme,
            selectedModelId: selectedModel,
            onToggleGroup: { sourceKey in
                if let group = cachedGroupedOptions.first(where: { $0.source.uniqueKey == sourceKey }) {
                    toggleGroup(group.source)
                }
            },
            onSelectModel: { modelId in
                selectedModel = modelId
                onDismiss()
            },
            onDismiss: onDismiss
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct ModelPickerView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var selected: String? = "foundation"
            @State private var useMockData = true

            var body: some View {
                VStack(spacing: 0) {
                    // toggle for mock data
                    HStack {
                        Toggle(isOn: $useMockData) {
                            Text("Use Mock Data (\(mockModels.count) models)", bundle: .module)
                        }
                        .padding()
                        Spacer()
                    }
                    .background(Color.gray.opacity(0.1))

                    ModelPickerView(
                        options: useMockData ? mockModels : smallSampleModels,
                        selectedModel: $selected,
                        agentId: nil,
                        onDismiss: {}
                    )
                    .padding()
                }
                .frame(width: 450, height: 550)
                .background(Color.gray.opacity(0.2))
            }

            // large mock dataset for performance testing
            private var mockModels: [ModelPickerItem] {
                ModelPickerItem.generateMockModels(count: 500)
            }

            // small sample for quick testing
            private var smallSampleModels: [ModelPickerItem] {
                [
                    .foundation(),
                    ModelPickerItem(
                        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                        displayName: "Llama 3.2 3B Instruct 4bit",
                        source: .local,
                        parameterCount: "3B",
                        quantization: "4-bit",
                        isVLM: false
                    ),
                    ModelPickerItem(
                        id: "mlx-community/Qwen2-VL-7B-Instruct-4bit",
                        displayName: "Qwen2 VL 7B Instruct 4bit",
                        source: .local,
                        parameterCount: "7B",
                        quantization: "4-bit",
                        isVLM: true
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-4o",
                        displayName: "gpt-4o",
                        source: .remote(providerName: "OpenAI", providerId: UUID())
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-3.5-turbo",
                        displayName: "gpt-3.5-turbo",
                        source: .remote(providerName: "OpenAI", providerId: UUID())
                    ),
                ]
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
#else
import SwiftUI

/// Intel model picker. The upstream "rich" picker (the `#if !OSAURUS_INTEL`
/// half above) renders through `ModelPickerTableRepresentable` — an NSTableView
/// that trips the same macOS-13 AppKit auto-sizing demon we fought in the chat
/// layout. So on Intel we render a pure-SwiftUI popover instead, keeping the
/// pieces that actually matter with a large catalog: a real `ScrollView` (the
/// old stub rendered an unbounded `VStack` that couldn't scroll), a search
/// field, and source tabs (e.g. Osaurus / DeepSeek) — mirroring upstream's
/// structure without the table. Pricing/context badges need catalog metadata
/// the Intel `ModelPickerItem` doesn't yet carry; Vision comes from `isVLM`.
struct ModelPickerView: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let agentId: UUID?
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var searchText = ""
    /// `nil` = the "All" tab; otherwise a `Source.uniqueKey`.
    @State private var selectedSourceKey: String?
    @State private var sortOrder: ModelPickerSortOrder = .default
    @State private var contextFilter: ModelPickerContextFilter = .any
    @State private var visionFilter: ModelPickerVisionFilter = .any
    @State private var showSortPopover = false

    private var groups: [(source: ModelPickerItem.Source, models: [ModelPickerItem])] {
        options.groupedBySource()
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sort/filter only makes sense on a single source tab that actually carries
    /// router pricing/context metadata (the Osaurus tab), and not while searching.
    private var showSortButton: Bool {
        guard !isSearching, let key = selectedSourceKey else { return false }
        return options.contains { $0.source.uniqueKey == key && $0.inputPriceMicroPerMTok != nil }
    }

    private var isSortOrFilterActive: Bool {
        sortOrder != .default || contextFilter != .any || visionFilter != .any
    }

    private var visibleModels: [ModelPickerItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = options
        if let key = selectedSourceKey {
            items = items.filter { $0.source.uniqueKey == key }
        }
        if !query.isEmpty {
            items = items.filter {
                $0.displayName.lowercased().contains(query) || $0.id.lowercased().contains(query)
            }
        }
        // Filters + price sort apply only on a specific tab (where router
        // metadata exists); the "All" tab keeps the grouped/alphabetical order.
        if selectedSourceKey != nil {
            items =
                items
                .filteredByContext(contextFilter)
                .filteredByVision(visionFilter)
                .sortedByPrice(sortOrder)
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            if groups.count > 1 {
                sourceTabs
            }
            Divider().background(theme.primaryBorder.opacity(0.3))
            if visibleModels.isEmpty {
                emptyState
            } else {
                modelScroll
            }
        }
        .frame(width: 380, height: 480)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Available Models", bundle: .module)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("\(options.count)")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.secondaryBackground))
            Spacer()
            if showSortButton {
                sortButton
            }
            addProviderButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var sortButton: some View {
        Button(action: { showSortPopover.toggle() }) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSortOrFilterActive ? theme.accentColor : theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(theme.accentColor.opacity(isSortOrFilterActive ? 0.18 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .help(Text("Sort and filter", bundle: .module))
        .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
            sortFilterPopover
        }
    }

    private var addProviderButton: some View {
        Button(action: {
            onDismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                AppDelegate.shared?.showManagementWindow(initialTab: .providers)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Add Provider", bundle: .module)
                    .font(theme.font(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
                    .background(Capsule().fill(theme.accentColor.opacity(0.08)))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sort & Filter Popover

    private var sortFilterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Sort by price")
            VStack(spacing: 2) {
                sortRow(.default, "Default", icon: "list.bullet")
                sortRow(.priceLowToHigh, "Cheapest first", icon: "arrow.down")
                sortRow(.priceHighToLow, "Priciest first", icon: "arrow.up")
            }

            Divider().background(theme.primaryBorder.opacity(0.2))

            sectionHeader("Min context")
            chipRow(ModelPickerContextFilter.allCases, current: contextFilter, label: { $0.label }) {
                contextFilter = $0
            }

            sectionHeader("Vision")
            chipRow(ModelPickerVisionFilter.allCases, current: visionFilter, label: { $0.label }) {
                visionFilter = $0
            }

            if isSortOrFilterActive {
                Button(action: {
                    sortOrder = .default
                    contextFilter = .any
                    visionFilter = .any
                }) {
                    Text("Reset", bundle: .module)
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 240)
        .background(theme.primaryBackground)
    }

    private func sectionHeader(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key, bundle: .module))
            .font(theme.font(size: 10, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .textCase(.uppercase)
    }

    private func sortRow(_ order: ModelPickerSortOrder, _ titleKey: String.LocalizationValue, icon: String)
        -> some View
    {
        let isSelected = sortOrder == order
        return Button(action: { sortOrder = order }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(String(localized: titleKey, bundle: .module))
                    .font(theme.font(size: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chipRow<T: Hashable>(
        _ items: [T],
        current: T,
        label: @escaping (T) -> String,
        select: @escaping (T) -> Void
    ) -> some View {
        FlowChips(items: items, isSelected: { $0 == current }, label: label, select: select)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text("Search models...", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
            }
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
    }

    // MARK: - Source Tabs

    private var sourceTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabPill(label: String(localized: "All", bundle: .module), count: options.count, key: nil)
                ForEach(groups, id: \.source.uniqueKey) { group in
                    tabPill(
                        label: group.source.displayName,
                        count: group.models.count,
                        key: group.source.uniqueKey
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func tabPill(label: String, count: Int, key: String?) -> some View {
        let isSelected = selectedSourceKey == key
        return Button(action: { selectedSourceKey = key }) {
            HStack(spacing: 5) {
                Text(label)
                    .font(theme.font(size: 11, weight: .medium))
                Text("\(count)")
                    .font(theme.font(size: 10, weight: .medium))
                    .opacity(0.7)
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isSelected ? theme.accentColor.opacity(0.12) : theme.secondaryBackground.opacity(0.5)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? theme.accentColor.opacity(0.35) : Color.clear, lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Model List

    private var modelScroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleModels) { item in
                    modelRow(item)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func modelRow(_ item: ModelPickerItem) -> some View {
        let isSelected = item.id == selectedModel
        return Button(action: {
            selectedModel = item.id
            onDismiss()
        }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText.opacity(0.5))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(theme.font(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if item.isVLM {
                    visionBadge
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isSelected ? theme.accentColor.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var visionBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye")
                .font(.system(size: 9))
            Text("Vision", bundle: .module)
                .font(theme.font(size: 9, weight: .medium))
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.accentColor.opacity(0.1)))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundColor(theme.tertiaryText)
            Text("No models found", bundle: .module)
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A horizontally-scrolling row of selectable filter chips. Reads the theme
/// from the environment so callers don't have to thread it through.
private struct FlowChips<T: Hashable>: View {
    let items: [T]
    let isSelected: (T) -> Bool
    let label: (T) -> String
    let select: (T) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    let selected = isSelected(item)
                    Button(action: { select(item) }) {
                        Text(label(item))
                            .font(theme.font(size: 11, weight: .medium))
                            .foregroundColor(selected ? theme.accentColor : theme.secondaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    selected
                                        ? theme.accentColor.opacity(0.15)
                                        : theme.secondaryBackground.opacity(0.5)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }
}
#endif
