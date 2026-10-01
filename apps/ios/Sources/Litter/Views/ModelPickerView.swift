import SwiftUI

// MARK: - Catalog projection

extension ModelInfo {
    /// Short label for picker rows. Rust fills `pickerName` when the catalog
    /// is fetched (mode name for modes, name without provider prefix for
    /// models); fall back for catalogs cached before that field existed.
    var pickerLabel: String {
        if !pickerName.isEmpty { return pickerName }
        return displayName.isEmpty ? id : displayName
    }

    var isModeEntry: Bool { entryKind != .model }
}

/// Render-only projection of the model catalog for the picker: harnesses,
/// their provider groups, and a search index. Built once per distinct
/// catalog by `ModelPickerCatalogCache`; rows only read precomputed values.
struct ModelPickerCatalog {
    struct ProviderGroup: Identifiable {
        let id: String
        /// `nil` for a harness's own catalog (no provider split).
        let title: String?
        let models: [ModelInfo]
    }

    struct Harness: Identifiable {
        let kind: AgentRuntimeKind
        let label: String
        let modes: [ModelInfo]
        let pluginModes: [ModelInfo]
        let providers: [ProviderGroup]
        let modelCount: Int
        let summary: String

        var id: AgentRuntimeKind { kind }
    }

    struct SearchSection: Identifiable {
        let id: String
        let kind: AgentRuntimeKind
        let title: String
        var models: [ModelInfo]
    }

    struct SearchResults {
        var sections: [SearchSection] = []
        var shown = 0
        var total = 0
    }

    private struct SearchRow {
        let model: ModelInfo
        let sectionID: String
        let sectionTitle: String
        let text: String
    }

    static let searchLimit = 150

    let visible: [ModelInfo]
    let harnesses: [Harness]
    private let byScopedID: [String: ModelInfo]
    private let searchRows: [SearchRow]

    init() {
        visible = []
        harnesses = []
        byScopedID = [:]
        searchRows = []
    }

    init(models: [ModelInfo]) {
        let visible = models.filter { !$0.hidden }
        var byKind: [AgentRuntimeKind: [ModelInfo]] = [:]
        var seenOrder: [AgentRuntimeKind] = []
        var byScopedID: [String: ModelInfo] = [:]
        for model in visible {
            let kind = model.agentRuntimeKind
            if byKind[kind] == nil { seenOrder.append(kind) }
            byKind[kind, default: []].append(model)
            byScopedID[model.runtimeScopedID] = model
        }
        var ordered = AgentRuntimeKind.presentationOrder.filter { byKind[$0] != nil }
        let known = Set(ordered)
        ordered += seenOrder
            .filter { !known.contains($0) }
            .sorted { $0.titleDisplayLabel.lowercased() < $1.titleDisplayLabel.lowercased() }

        var harnesses: [Harness] = []
        var rows: [SearchRow] = []
        rows.reserveCapacity(visible.count)
        for kind in ordered {
            let harness = Self.makeHarness(kind: kind, entries: byKind[kind] ?? [])
            harnesses.append(harness)
            let label = harness.label.lowercased()
            func index(_ models: [ModelInfo], sectionID: String, title: String, provider: String?) {
                for model in models {
                    let text = [
                        model.pickerLabel, model.id, model.model, model.displayName,
                        label, provider ?? "", model.providerId ?? "",
                    ]
                    .joined(separator: "\n")
                    .lowercased()
                    rows.append(SearchRow(model: model, sectionID: sectionID, sectionTitle: title, text: text))
                }
            }
            index(harness.modes, sectionID: "\(kind)|modes", title: "\(harness.label) · Modes", provider: "mode")
            index(
                harness.pluginModes,
                sectionID: "\(kind)|plugin-modes",
                title: "\(harness.label) · Plugin modes",
                provider: "plugin mode"
            )
            for group in harness.providers {
                index(
                    group.models,
                    sectionID: group.id,
                    title: group.title.map { "\(harness.label) · \($0)" } ?? harness.label,
                    provider: group.title
                )
            }
        }

        self.visible = visible
        self.harnesses = harnesses
        self.byScopedID = byScopedID
        self.searchRows = rows
    }

    private static func makeHarness(kind: AgentRuntimeKind, entries: [ModelInfo]) -> Harness {
        var modes: [ModelInfo] = []
        var pluginModes: [ModelInfo] = []
        var modelsByProvider: [String: [ModelInfo]] = [:]
        var providerTitles: [String: String] = [:]
        var modelCount = 0
        for entry in entries {
            switch entry.entryKind {
            case .mode:
                modes.append(entry)
            case .pluginMode:
                pluginModes.append(entry)
            case .model:
                let provider = entry.providerId ?? ""
                modelsByProvider[provider, default: []].append(entry)
                if providerTitles[provider] == nil, !provider.isEmpty {
                    providerTitles[provider] = entry.providerLabel ?? provider
                }
                modelCount += 1
            }
        }
        let providers = modelsByProvider
            .map { provider, models in
                ProviderGroup(
                    id: "\(kind)|provider:\(provider)",
                    title: provider.isEmpty ? nil : providerTitles[provider],
                    models: models
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.title, rhs.title) {
                case (nil, _): return true
                case (_, nil): return false
                case let (l?, r?): return l.lowercased() < r.lowercased()
                }
            }

        var parts: [String] = []
        if modelCount > 0 {
            parts.append(modelCount == 1 ? "1 model" : "\(modelCount) models")
            let named = providers.filter { $0.title != nil }.count
            if named > 1 { parts.append("\(named) providers") }
        }
        if !modes.isEmpty {
            parts.append(modes.count == 1 ? "1 mode" : "\(modes.count) modes")
        }
        if !pluginModes.isEmpty {
            parts.append(pluginModes.count == 1 ? "1 plugin mode" : "\(pluginModes.count) plugin modes")
        }

        return Harness(
            kind: kind,
            label: kind.titleDisplayLabel,
            modes: modes,
            pluginModes: pluginModes,
            providers: providers,
            modelCount: modelCount,
            summary: parts.joined(separator: " · ")
        )
    }

    func harness(_ kind: AgentRuntimeKind) -> Harness? {
        harnesses.first { $0.kind == kind }
    }

    func model(scopedID: String) -> ModelInfo? {
        byScopedID[scopedID]
    }

    /// "Pi · OpenAI", "Amp · mode", "Codex".
    func subtitle(for model: ModelInfo) -> String {
        let harness = model.agentRuntimeKind.titleDisplayLabel
        switch model.entryKind {
        case .mode: return "\(harness) · mode"
        case .pluginMode: return "\(harness) · plugin mode"
        case .model:
            if let provider = model.providerLabel ?? model.providerId, !provider.isEmpty {
                return "\(harness) · \(provider)"
            }
            return harness
        }
    }

    /// Every whitespace-separated token must match, so "pi sonnet" or
    /// "openai mini" narrow across harness, provider and model name.
    func search(_ query: String, in kind: AgentRuntimeKind? = nil) -> SearchResults {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var results = SearchResults()
        guard !tokens.isEmpty else { return results }
        for row in searchRows {
            if let kind, row.model.agentRuntimeKind != kind { continue }
            guard tokens.allSatisfy({ row.text.contains($0) }) else { continue }
            results.total += 1
            guard results.shown < Self.searchLimit else { continue }
            results.shown += 1
            if results.sections.last?.id == row.sectionID {
                results.sections[results.sections.count - 1].models.append(row.model)
            } else {
                results.sections.append(
                    SearchSection(
                        id: row.sectionID,
                        kind: row.model.agentRuntimeKind,
                        title: row.sectionTitle,
                        models: [row.model]
                    )
                )
            }
        }
        return results
    }
}

/// Memo for `ModelPickerCatalog`. Keyed on the model list (identical array
/// buffers compare in O(1)) plus the agent-directory fingerprint, so a
/// probe that renames or reorders agents rebuilds the projection.
@MainActor
final class ModelPickerCatalogCache {
    private var cachedModels: [ModelInfo] = []
    private var cachedFingerprint: Int?
    private var cached = ModelPickerCatalog()

    func catalog(for models: [ModelInfo]) -> ModelPickerCatalog {
        let fingerprint = AgentRuntimeKind.metadataFingerprint
        if cachedFingerprint == fingerprint, cachedModels == models {
            return cached
        }
        cached = ModelPickerCatalog(models: models)
        cachedModels = models
        cachedFingerprint = fingerprint
        return cached
    }
}

/// Recently picked models, most recent first. Platform-local preference.
enum ModelPickerRecents {
    static let storageKey = "modelPicker.recents"
    private static let limit = 8
    private static let separator = "\n"

    static func decode(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func recording(_ model: ModelInfo, in raw: String) -> String {
        var ids = decode(raw).filter { $0 != model.runtimeScopedID }
        ids.insert(model.runtimeScopedID, at: 0)
        return ids.prefix(limit).joined(separator: separator)
    }
}

// MARK: - Picker

/// Thread-level controls shown in the picker's options section when the
/// picker is opened from a context that owns them (home composer or an
/// existing thread's options sheet).
struct ModelPickerSessionControls {
    var threadKey: ThreadKey?
    var collaborationMode: AppModeKind = .default
    var effectiveApprovalPolicy: AppAskForApproval?
    var effectiveSandboxPolicy: AppSandboxPolicy?
}

private struct ModelPickerRoute: Hashable {
    let kind: AgentRuntimeKind
}

/// Composer model picker: current selection and recents on top, then one
/// row per harness that opens its models (grouped by provider) or modes,
/// then a small options section. Search covers the whole catalog.
struct ModelPickerView: View {
    let models: [ModelInfo]
    var catalogLoaded = false
    var catalogError: String?
    var onRetryModels: () -> Void = {}
    @Binding var selectedModel: String
    @Binding var selectedAgentRuntimeKind: AgentRuntimeKind?
    @Binding var reasoningEffort: String
    var isReasoningEffortLocked = false
    /// Treat the catalog default as current when nothing is picked yet
    /// (home composer before the first choice).
    var fallsBackToDefaultModel = false
    var dismissOnSelect = false
    var session: ModelPickerSessionControls?
    var onDone: () -> Void = {}

    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false
    @AppStorage(ModelPickerRecents.storageKey) private var recentsRaw = ""
    @State private var catalogCache = ModelPickerCatalogCache()
    @State private var path: [ModelPickerRoute] = []
    @State private var query = ""

    var body: some View {
        let catalog = catalogCache.catalog(for: models)
        let current = currentModel(in: catalog)

        NavigationStack(path: $path) {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browseSections(catalog: catalog, current: current)
                } else {
                    ModelPickerSearchSections(
                        results: catalog.search(query),
                        query: query,
                        isSelected: isSelected,
                        onSelect: select
                    )
                }
            }
            .modelPickerListStyle()
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search all models"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .litterFont(.body, weight: .semibold)
                        .foregroundStyle(LitterTheme.accent)
                        .accessibilityIdentifier("modelPicker.done")
                }
            }
            .navigationDestination(for: ModelPickerRoute.self) { route in
                if let harness = catalog.harness(route.kind) {
                    ModelPickerHarnessPage(
                        harness: harness,
                        catalog: catalog,
                        isSelected: isSelected,
                        onSelect: select
                    )
                }
            }
        }
        .tint(LitterTheme.accent)
    }

    // MARK: Browse

    @ViewBuilder
    private func browseSections(catalog: ModelPickerCatalog, current: ModelInfo?) -> some View {
        if let notice = catalogNotice(hasModels: !catalog.visible.isEmpty) {
            Section {
                VStack(spacing: 8) {
                    Text(notice)
                        .litterFont(.footnote)
                        .foregroundStyle(LitterTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    if catalogError != nil {
                        Button("Retry", action: onRetryModels)
                            .litterFont(.footnote, weight: .semibold)
                            .foregroundStyle(LitterTheme.accent)
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .modelPickerRowBackground()
        }

        if let current {
            Section {
                ModelPickerModelRow(
                    model: current,
                    subtitle: catalog.subtitle(for: current),
                    showsIcon: true,
                    isSelected: isSelected(current)
                ) {
                    path = [ModelPickerRoute(kind: current.agentRuntimeKind)]
                }
                .accessibilityIdentifier("modelPicker.current")
            } header: {
                ModelPickerSectionHeader(title: "Current")
            }
            .modelPickerRowBackground()
        }

        let recents = recentModels(catalog: catalog, excluding: current)
        if !recents.isEmpty {
            Section {
                ForEach(recents, id: \.runtimeScopedID) { model in
                    ModelPickerModelRow(
                        model: model,
                        subtitle: catalog.subtitle(for: model),
                        showsIcon: true,
                        isSelected: false
                    ) {
                        select(model)
                    }
                }
            } header: {
                ModelPickerSectionHeader(title: "Recent")
            }
            .modelPickerRowBackground()
        }

        if !catalog.harnesses.isEmpty {
            Section {
                ForEach(catalog.harnesses) { harness in
                    NavigationLink(value: ModelPickerRoute(kind: harness.kind)) {
                        ModelPickerHarnessRow(
                            harness: harness,
                            isCurrent: current?.agentRuntimeKind == harness.kind
                        )
                    }
                    .accessibilityIdentifier("modelPicker.harness.\(harness.kind)")
                }
            } header: {
                ModelPickerSectionHeader(title: "Harnesses")
            }
            .modelPickerRowBackground()
        }

        optionsSection(current: current)
    }

    // MARK: Options

    @ViewBuilder
    private func optionsSection(current: ModelInfo?) -> some View {
        let efforts = isReasoningEffortLocked ? [] : (current?.supportedReasoningEfforts ?? [])
        Section {
            if isReasoningEffortLocked && current?.isModeEntry == true {
                HStack {
                    Text("Reasoning")
                        .litterFont(.body)
                        .foregroundStyle(LitterTheme.textPrimary)
                    Spacer()
                    Text("Locked after first message")
                        .litterFont(.footnote)
                        .foregroundStyle(LitterTheme.textSecondary)
                }
            } else if !efforts.isEmpty {
                Picker(selection: $reasoningEffort) {
                    if !efforts.contains(where: { $0.reasoningEffort.wireValue == reasoningEffort }) {
                        Text("Default").tag(reasoningEffort)
                    }
                    ForEach(efforts) { effort in
                        Text(effort.reasoningEffort.wireValue.capitalized)
                            .tag(effort.reasoningEffort.wireValue)
                    }
                } label: {
                    Text("Reasoning")
                        .litterFont(.body)
                        .foregroundStyle(LitterTheme.textPrimary)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("modelPicker.reasoning")
            }

            Toggle(isOn: $fastMode) {
                ModelPickerOptionLabel(title: "Fast mode", systemImage: "bolt")
            }
            .accessibilityIdentifier("modelPicker.fastMode")

            if let session {
                ModelPickerSessionToggles(session: session, current: current, selectedRuntime: selectedAgentRuntimeKind)
            }
        } header: {
            ModelPickerSectionHeader(title: "Options")
        }
        .modelPickerRowBackground()
    }

    // MARK: Selection

    private func currentModel(in catalog: ModelPickerCatalog) -> ModelInfo? {
        let trimmed = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let match = catalog.visible.first(where: {
               modelMatchesSelection($0, trimmed, runtime: selectedAgentRuntimeKind)
           }) {
            return match
        }
        guard fallsBackToDefaultModel else { return nil }
        return catalog.visible.first(where: \.isDefault) ?? catalog.visible.first
    }

    private func isSelected(_ model: ModelInfo) -> Bool {
        modelMatchesSelection(model, selectedModel, runtime: selectedAgentRuntimeKind)
    }

    private func recentModels(catalog: ModelPickerCatalog, excluding current: ModelInfo?) -> [ModelInfo] {
        let currentID = current?.runtimeScopedID
        return ModelPickerRecents.decode(recentsRaw)
            .filter { $0 != currentID }
            .compactMap(catalog.model(scopedID:))
            .prefix(4)
            .map { $0 }
    }

    private func select(_ model: ModelInfo) {
        selectedModel = model.id
        selectedAgentRuntimeKind = model.agentRuntimeKind
        if isReasoningEffortLocked && model.isModeEntry {
            reasoningEffort = ""
        } else {
            reasoningEffort = model.supportedDefaultReasoningEffort?.wireValue ?? ""
        }
        recentsRaw = ModelPickerRecents.recording(model, in: recentsRaw)
        query = ""
        path = []
        if dismissOnSelect { onDone() }
    }

    private func catalogNotice(hasModels: Bool) -> String? {
        if let catalogError { return catalogError }
        if !catalogLoaded { return "Loading models…" }
        return hasModels ? nil : "No models available"
    }
}

// MARK: - Harness page

private struct ModelPickerHarnessPage: View {
    let harness: ModelPickerCatalog.Harness
    let catalog: ModelPickerCatalog
    let isSelected: (ModelInfo) -> Bool
    let onSelect: (ModelInfo) -> Void

    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var didInitializeExpansion = false

    /// Large multi-provider catalogs start folded so one provider cannot
    /// bury the rest; the provider holding the selection starts open.
    private var collapsesProviders: Bool {
        harness.providers.count > 1 && harness.modelCount > 30
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if !harness.modes.isEmpty {
                    Section {
                        rows(harness.modes, showsDescription: true)
                    } header: {
                        ModelPickerSectionHeader(title: "Modes")
                    }
                    .modelPickerRowBackground()
                }
                if !harness.pluginModes.isEmpty {
                    Section {
                        rows(harness.pluginModes, showsDescription: false)
                    } header: {
                        ModelPickerSectionHeader(title: "Plugin modes")
                    } footer: {
                        Text("Modes added by \(harness.label) plugins on the host.")
                            .litterFont(.caption)
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                    .modelPickerRowBackground()
                }
                ForEach(harness.providers) { group in
                    providerSection(group)
                }
            } else {
                ModelPickerSearchSections(
                    results: catalog.search(query, in: harness.kind),
                    query: query,
                    isSelected: isSelected,
                    onSelect: onSelect
                )
            }
        }
        .modelPickerListStyle()
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search \(harness.label)"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle(harness.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: initializeExpansion)
    }

    @ViewBuilder
    private func providerSection(_ group: ModelPickerCatalog.ProviderGroup) -> some View {
        let isOpen = !collapsesProviders || expanded.contains(group.id)
        Section {
            if isOpen {
                rows(group.models, showsDescription: true)
            }
        } header: {
            if collapsesProviders {
                Button {
                    if expanded.contains(group.id) {
                        expanded.remove(group.id)
                    } else {
                        expanded.insert(group.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        ModelPickerSectionHeader(title: group.title ?? "Other")
                        Spacer()
                        if group.models.contains(where: isSelected) {
                            Circle()
                                .fill(LitterTheme.accent)
                                .frame(width: 6, height: 6)
                        }
                        Text("\(group.models.count)")
                            .litterFont(.footnote)
                            .foregroundStyle(LitterTheme.textMuted)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .litterFont(size: 11, weight: .semibold)
                            .foregroundStyle(LitterTheme.textMuted)
                            .frame(width: 14)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("modelPicker.provider.\(group.id)")
                .accessibilityLabel("\(group.title ?? "Other"), \(group.models.count) models")
                .accessibilityHint(isOpen ? "Collapse" : "Expand")
            } else if let title = group.title {
                ModelPickerSectionHeader(title: title)
            } else if harness.providers.count > 1 || !harness.modes.isEmpty || !harness.pluginModes.isEmpty {
                ModelPickerSectionHeader(title: "Models")
            }
        }
        .modelPickerRowBackground()
    }

    private func rows(_ models: [ModelInfo], showsDescription: Bool) -> some View {
        ForEach(models, id: \.runtimeScopedID) { model in
            ModelPickerModelRow(
                model: model,
                subtitle: showsDescription ? model.description : nil,
                showsIcon: false,
                isSelected: isSelected(model)
            ) {
                onSelect(model)
            }
        }
    }

    private func initializeExpansion() {
        guard !didInitializeExpansion else { return }
        didInitializeExpansion = true
        if let group = harness.providers.first(where: { $0.models.contains(where: isSelected) }) {
            expanded.insert(group.id)
        }
    }
}

// MARK: - Search results

private struct ModelPickerSearchSections: View {
    let results: ModelPickerCatalog.SearchResults
    let query: String
    let isSelected: (ModelInfo) -> Bool
    let onSelect: (ModelInfo) -> Void

    var body: some View {
        if results.sections.isEmpty {
            Section {
                Text("No models match “\(query.trimmingCharacters(in: .whitespaces))”")
                    .litterFont(.footnote)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .modelPickerRowBackground()
        }
        ForEach(results.sections) { section in
            Section {
                ForEach(section.models, id: \.runtimeScopedID) { model in
                    ModelPickerModelRow(
                        model: model,
                        subtitle: nil,
                        showsIcon: false,
                        isSelected: isSelected(model)
                    ) {
                        onSelect(model)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    AgentIconView(kind: section.kind, size: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    ModelPickerSectionHeader(title: section.title)
                }
            }
            .modelPickerRowBackground()
        }
        if results.total > results.shown {
            Section {
                Text("Showing \(results.shown) of \(results.total) matches. Keep typing to narrow.")
                    .litterFont(.caption)
                    .foregroundStyle(LitterTheme.textMuted)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
    }
}

// MARK: - Rows

private struct ModelPickerModelRow: View {
    let model: ModelInfo
    let subtitle: String?
    let showsIcon: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if showsIcon {
                    ModelPickerHarnessIcon(kind: model.agentRuntimeKind, size: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.pickerLabel)
                            .litterFont(.body)
                            .foregroundStyle(LitterTheme.textPrimary)
                            .lineLimit(1)
                        if model.isDefault {
                            Text("Default")
                                .litterFont(.caption2, weight: .medium)
                                .foregroundStyle(LitterTheme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    LitterTheme.textPrimary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .litterFont(.footnote)
                            .foregroundStyle(LitterTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .litterFont(size: 14, weight: .semibold)
                        .foregroundStyle(LitterTheme.accent)
                }
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ModelPickerHarnessRow: View {
    let harness: ModelPickerCatalog.Harness
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ModelPickerHarnessIcon(kind: harness.kind, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.label)
                    .litterFont(.body)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .lineLimit(1)
                Text(harness.summary)
                    .litterFont(.footnote)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .litterFont(size: 13, weight: .semibold)
                    .foregroundStyle(LitterTheme.accent)
                    .accessibilityLabel("Current harness")
            }
        }
        .frame(minHeight: 36)
    }
}

/// Harness icon on a quiet tile so light and dark glyphs both read.
private struct ModelPickerHarnessIcon: View {
    let kind: AgentRuntimeKind
    let size: CGFloat

    var body: some View {
        AgentIconView(kind: kind, size: size * 0.64)
            .frame(width: size, height: size)
            .background(
                LitterTheme.textPrimary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

private struct ModelPickerSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .litterFont(.footnote, weight: .medium)
            .foregroundStyle(LitterTheme.textSecondary)
            .textCase(nil)
            .lineLimit(1)
    }
}

private struct ModelPickerOptionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .litterFont(.body)
                .foregroundStyle(LitterTheme.textPrimary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(LitterTheme.textSecondary)
        }
    }
}

/// Plan mode and permission toggles for pickers opened with a session
/// context. Mirrors the previous chip behaviour: a thread writes through
/// the store, the home composer writes pending app-state preferences.
private struct ModelPickerSessionToggles: View {
    let session: ModelPickerSessionControls
    let current: ModelInfo?
    let selectedRuntime: AgentRuntimeKind?

    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState

    private var collaborationMode: AppModeKind {
        session.threadKey == nil ? appState.pendingCollaborationMode : session.collaborationMode
    }

    private var isFullAccess: Bool {
        let approval = appState.launchApprovalPolicy(for: session.threadKey) ?? session.effectiveApprovalPolicy
        let sandbox = appState.turnSandboxPolicy(for: session.threadKey) ?? session.effectiveSandboxPolicy
        return threadPermissionPreset(approvalPolicy: approval, sandboxPolicy: sandbox) == .fullAccess
    }

    private var supportsPermissionOverrides: Bool {
        (selectedRuntime ?? current?.agentRuntimeKind)?.supportsThreadPermissionOverrides ?? true
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { collaborationMode == .plan },
            set: { setPlan($0) }
        )) {
            ModelPickerOptionLabel(title: "Plan mode", systemImage: "doc.text")
        }
        .accessibilityIdentifier("modelPicker.planMode")

        if supportsPermissionOverrides {
            Toggle(isOn: Binding(
                get: { isFullAccess },
                set: { setFullAccess($0) }
            )) {
                ModelPickerOptionLabel(
                    title: "Full access",
                    systemImage: isFullAccess ? "lock.open" : "lock"
                )
            }
            .tint(LitterTheme.danger)
            .accessibilityIdentifier("modelPicker.fullAccess")
        }
    }

    private func setPlan(_ enabled: Bool) {
        let next: AppModeKind = enabled ? .plan : .default
        if let threadKey = session.threadKey {
            Task {
                try? await appModel.store.setThreadCollaborationMode(key: threadKey, mode: next)
            }
        } else {
            appState.pendingCollaborationMode = next
        }
    }

    private func setFullAccess(_ enabled: Bool) {
        if enabled {
            appState.setPermissions(approvalPolicy: "never", sandboxMode: "danger-full-access", for: session.threadKey)
        } else {
            appState.setPermissions(approvalPolicy: "on-request", sandboxMode: "workspace-write", for: session.threadKey)
        }
    }
}

// MARK: - Styling

private extension View {
    func modelPickerListStyle() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(LitterTheme.surface)
            .environment(\.defaultMinListRowHeight, 48)
            .scrollDismissesKeyboard(.immediately)
    }

    func modelPickerRowBackground() -> some View {
        listRowBackground(LitterTheme.textPrimary.opacity(0.045))
    }
}
