import SwiftUI
import os

private let sessionsScreenSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "SessionsScreen"
)

struct SessionsScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sessionsModel = SessionsModel()
    @State private var isLoading: Bool
    @State private var resumingKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var directoryPickerSheet: SessionLaunchSupport.DirectoryPickerSheetModel?
    @State private var sessionSearchQuery = ""
    @State private var debouncedSessionSearchQuery = ""
    @State private var selectedRuntimeKindFilter: AgentRuntimeKind?
    @State private var isForkingActiveThread = false
    @State private var sessionActionErrorMessage: String?
    @State private var renamingThreadKey: ThreadKey?
    @State private var renameCurrentTitle = ""
    @State private var renameDraft = ""
    @State private var archiveTargetKey: ThreadKey?
    @State private var pinnedKeys: Set<PinnedThreadKey> = []
    @State private var pendingActiveSessionScroll = false
    @State private var sessionSearchDebounceTask: Task<Void, Never>?
    @State private var hasLoadedInitialSessions = false
    @State private var isSessionLoadInFlight = false
    @State private var sessionHydrationLimit = SessionsScreen.sessionHydrationPageSize
    private static let sessionHydrationPageSize: UInt32 = SessionListRules.pageSize
    private let autoLoadSessions: Bool
    private let onOpenConversation: (ThreadKey) -> Void
    private let onInfo: (() -> Void)?
    private let onPin: ((ThreadKey) -> Void)?
    private let onUnpin: ((ThreadKey) -> Void)?

    init(
        autoLoadSessions: Bool = true,
        onOpenConversation: @escaping (ThreadKey) -> Void,
        onInfo: (() -> Void)? = nil,
        onPin: ((ThreadKey) -> Void)? = nil,
        onUnpin: ((ThreadKey) -> Void)? = nil
    ) {
        self.autoLoadSessions = autoLoadSessions
        self.onOpenConversation = onOpenConversation
        self.onInfo = onInfo
        self.onPin = onPin
        self.onUnpin = onUnpin
        _isLoading = State(initialValue: autoLoadSessions)
    }

    var body: some View {
        screenContent(derived: sessionsModel.derivedData)
    }


    private func screenContent(derived: SessionsDerivedData) -> some View {
        let base = screenLayout(derived: derived)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 20) {
                        if let onInfo {
                            Button(action: onInfo) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(LitterTheme.textSecondary)
                            }
                            .accessibilityLabel("Server info")
                        }
                        filterMenu
                        refreshToolbarButton
                        newSessionButton
                    }
                }
                .litterPlainToolbarItem()
            }

        let lifecycle = attachLifecycleHandlers(to: base, derived: derived)
        let alerts = attachSheetAndAlerts(to: lifecycle)

        return alerts.sheet(item: $directoryPickerSheet) { _ in
            NavigationStack {
                DirectoryPickerView(
                    servers: connectedServerOptions,
                    selectedServerId: Binding(
                        get: { directoryPickerSheet?.selectedServerId ?? defaultNewSessionServerId() ?? "" },
                        set: { nextServerId in
                            guard var sheet = directoryPickerSheet else { return }
                            sheet.selectedServerId = nextServerId
                            directoryPickerSheet = sheet
                        }
                    ),
                    localServerIds: sessionsModel.localServerIds,
                    browseableServerIds: sessionsModel.browseableServerIds,
                    onServerChanged: { nextServerId in
                        guard var sheet = directoryPickerSheet else { return }
                        sheet.selectedServerId = nextServerId
                        directoryPickerSheet = sheet
                    },
                    onDirectorySelected: { serverId, cwd in
                        directoryPickerSheet = nil
                        Task { await startNewSession(serverId: serverId, cwd: cwd) }
                    },
                    onDismissRequested: {
                        directoryPickerSheet = nil
                    }
                )
            }
            .environment(appModel)
        }
    }

    private func attachLifecycleHandlers<Content: View>(
        to content: Content,
        derived: SessionsDerivedData
    ) -> some View {
        content
            .task {
                pinnedKeys = Set(SavedThreadsStore.pinnedKeys())
                sessionsModel.bind(appModel: appModel, appState: appState)
                sessionsModel.updateSearchQuery(debouncedSessionSearchQuery)
                await loadSessionsIfNeeded()
            }
            .onAppear {
                scheduleActiveSessionScrollIfNeeded()
            }
            .onChange(of: connectedServerIds) { _, ids in
                guard autoLoadSessions, !ids.isEmpty else { return }
                Task { await loadSessionsIfNeeded(force: true) }
                scheduleActiveSessionScrollIfNeeded()
                guard let pickerSheet = directoryPickerSheet else {
                    if let filterId = selectedServerFilterId, !ids.contains(filterId) {
                        selectedServerFilterId = nil
                    }
                    return
                }
                guard let fallbackServerId = defaultNewSessionServerId(preferredServerId: pickerSheet.selectedServerId) else {
                    directoryPickerSheet = nil
                    appState.showServerPicker = true
                    return
                }
                if pickerSheet.selectedServerId != fallbackServerId {
                    var nextSheet = pickerSheet
                    nextSheet.selectedServerId = fallbackServerId
                    directoryPickerSheet = nextSheet
                }
                if let filterId = selectedServerFilterId, !ids.contains(filterId) {
                    selectedServerFilterId = nil
                }
            }
            .onChange(of: activeThreadKey) { _, _ in
                scheduleActiveSessionScrollIfNeeded()
            }
            .onChange(of: sessionSearchQuery) { _, next in
                scheduleSessionSearchDebounce(for: next)
            }
            .onChange(of: debouncedSessionSearchQuery) { _, next in
                sessionsModel.updateSearchQuery(next)
            }
            .onChange(of: selectedRuntimeKindFilter) { _, next in
                sessionsModel.updateRuntimeKindFilter(next)
            }
            .onReceive(NotificationCenter.default.publisher(for: .litterThreadPreferencesDidChange)) { _ in
                pinnedKeys = Set(SavedThreadsStore.pinnedKeys())
            }
            .onDisappear {
                sessionSearchDebounceTask?.cancel()
                sessionSearchDebounceTask = nil
            }
    }

    private func attachSheetAndAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert("Session Action Failed", isPresented: Binding(
                get: { sessionActionErrorMessage != nil },
                set: { if !$0 { sessionActionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { sessionActionErrorMessage = nil }
            } message: {
                Text(sessionActionErrorMessage ?? "Unknown error")
            }
            .alert("Rename Session", isPresented: Binding(
                get: { renamingThreadKey != nil },
                set: {
                    if !$0 {
                        renamingThreadKey = nil
                        renameCurrentTitle = ""
                        renameDraft = ""
                    }
                }
            )) {
                TextField("New session title", text: $renameDraft)
                Button("Save") { Task { await submitRename() } }
                Button("Cancel", role: .cancel) {
                    renamingThreadKey = nil
                    renameCurrentTitle = ""
                    renameDraft = ""
                }
            } message: {
                Text("Current session title:\n\(renameCurrentTitle)")
            }
            .confirmationDialog(
                "Delete session?",
                isPresented: Binding(
                    get: { archiveTargetKey != nil },
                    set: { if !$0 { archiveTargetKey = nil } }
                ),
                titleVisibility: Visibility.visible,
                presenting: archiveTargetThread
            ) { thread in
                Button("Delete \"\(thread.sessionTitle)\"", role: .destructive) {
                    Task { await confirmArchiveSession() }
                }
                Button("Cancel", role: .cancel) { archiveTargetKey = nil }
            } message: { _ in
                Text("This removes the session from the list.")
            }
    }

    // Litter Quiet "all sessions": search field, then one plain virtualized
    // list grouped by mono section labels (pinned, now, today, yesterday,
    // this week, older). Rows are title + "server · project · age". Filters
    // (server, runtime, forks) live in one toolbar menu. See
    // `SessionListRules` for the virtualization and pagination rules.
    private func screenLayout(derived: SessionsDerivedData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionSearchField
            if connectedServers.isEmpty {
                notConnectedLine
            }
            if derived.allThreads.isEmpty {
                Spacer()
                Text(isLoading ? "loading…" : "no sessions yet")
                    .litterMeta()
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if derived.filteredThreads.isEmpty {
                Spacer()
                Text(trimmedSessionSearchQuery.isEmpty
                     ? "no sessions match these filters"
                     : "no matches for \"\(trimmedSessionSearchQuery)\"")
                    .litterMeta()
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                sessionList(derived: derived)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityIdentifier("sessions.container")
    }

    private var selectedServerFilterId: String? {
        get { appState.sessionsSelectedServerFilterId }
        nonmutating set { appState.sessionsSelectedServerFilterId = newValue }
    }

    private var showOnlyForks: Bool {
        get { appState.sessionsShowOnlyForks }
        nonmutating set { appState.sessionsShowOnlyForks = newValue }
    }

    private var connectedServerIds: [String] {
        connectedServerOptions.map(\.id).sorted()
    }

    private var trimmedSessionSearchQuery: String {
        sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var archiveTargetThread: AppSessionSummary? {
        guard let archiveTargetKey else { return nil }
        return sessionsModel.derivedData.allThreads.first(where: { $0.key == archiveTargetKey })
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        sessionsModel.connectedServerOptions
    }

    private var connectedServers: [HomeDashboardServer] {
        sessionsModel.connectedServers
    }

    private var ephemeralStateByThreadKey: [ThreadKey: SessionsModel.ThreadEphemeralState] {
        sessionsModel.ephemeralStateByThreadKey
    }

    private var activeThreadKey: ThreadKey? {
        sessionsModel.activeThreadKey
    }

    private func scheduleSessionSearchDebounce(for nextQuery: String) {
        sessionSearchDebounceTask?.cancel()
        sessionSearchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let normalized = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if debouncedSessionSearchQuery != normalized {
                debouncedSessionSearchQuery = normalized
            }
        }
    }

    private func defaultNewSessionServerId(preferredServerId: String? = nil) -> String? {
        SessionLaunchSupport.defaultConnectedServerId(
            connectedServerIds: connectedServerIds,
            activeThreadKey: activeThreadKey,
            preferredServerId: preferredServerId
        )
    }

    private func startNewSessionFromToolbar() {
        if let defaultServerId = defaultNewSessionServerId(preferredServerId: appState.sessionsSelectedServerFilterId) {
            if connectedServers.first(where: { $0.id == defaultServerId })?.isLocal == true {
                let cwd = LitterPlatform.defaultLocalWorkingDirectory()
                Task { await startNewSession(serverId: defaultServerId, cwd: cwd) }
            } else {
                directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
            }
        } else {
            appState.showServerPicker = true
        }
    }

    private var newSessionButton: some View {
        Button(action: startNewSessionFromToolbar) {
            if isStartingNewSession {
                ProgressView().controlSize(.small).tint(LitterTheme.textSecondary)
            } else {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(LitterTheme.textPrimary)
            }
        }
        .disabled(isStartingNewSession)
        // Mac builds (Catalyst + iOS-on-Mac) bind Cmd+N at the menu
        // level via `MacCommands`; the in-view shortcut would either
        // double-bind (Catalyst) or be the only binding (iOS-on-Mac
        // doesn't get menus, so we keep it on then).
        .keyboardShortcut(LitterPlatform.isCatalyst ? nil : KeyboardShortcut("n", modifiers: [.command]))
        .accessibilityLabel("New session")
        .accessibilityIdentifier("sessions.newSessionButton")
    }

    private var refreshToolbarButton: some View {
        Button(action: refreshSessions) {
            if isLoading && hasLoadedInitialSessions {
                ProgressView().controlSize(.small).tint(LitterTheme.textSecondary)
            } else {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(connectedServers.isEmpty ? LitterTheme.textMuted : LitterTheme.textSecondary)
            }
        }
        .disabled(isLoading || connectedServers.isEmpty)
        .accessibilityLabel("Refresh sessions")
        .accessibilityIdentifier("sessions.refreshButton")
    }

    private var hasActiveFilters: Bool {
        selectedServerFilterId != nil || showOnlyForks || selectedRuntimeKindFilter != nil
    }

    /// Server, runtime and fork filters in one menu (was three chip rows).
    private var filterMenu: some View {
        let runtimeKinds = Set(sessionsModel.derivedData.allThreads.map(\.agentRuntimeKind))
        return Menu {
            Section("Server") {
                Button {
                    selectedServerFilterId = nil
                } label: {
                    menuLabel("All servers", checked: selectedServerFilterId == nil)
                }
                ForEach(connectedServerOptions, id: \.id) { option in
                    Button {
                        selectedServerFilterId = option.id
                    } label: {
                        menuLabel(option.name, checked: selectedServerFilterId == option.id)
                    }
                }
            }
            if runtimeKinds.count > 1 {
                Section("Agent") {
                    Button {
                        selectedRuntimeKindFilter = nil
                    } label: {
                        menuLabel("All agents", checked: selectedRuntimeKindFilter == nil)
                    }
                    ForEach(AgentRuntimeKind.presentationOrder.filter { runtimeKinds.contains($0) }, id: \.self) { kind in
                        Button {
                            selectedRuntimeKindFilter = kind
                        } label: {
                            menuLabel(kind.titleDisplayLabel, checked: selectedRuntimeKindFilter == kind)
                        }
                    }
                }
            }
            Section {
                Toggle("Forks only", isOn: Binding(
                    get: { showOnlyForks },
                    set: { showOnlyForks = $0 }
                ))
                if hasActiveFilters {
                    Button("Clear filters") {
                        selectedServerFilterId = nil
                        showOnlyForks = false
                        selectedRuntimeKindFilter = nil
                    }
                }
            }
            Section {
                Button("Add server") { appState.showServerPicker = true }
                    .accessibilityIdentifier("sessions.addServerButton")
            }
        } label: {
            Image(systemName: hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .foregroundStyle(hasActiveFilters ? LitterTheme.textPrimary : LitterTheme.textSecondary)
        }
        .accessibilityLabel("Filter sessions")
    }

    @ViewBuilder
    private func menuLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var notConnectedLine: some View {
        Button {
            appState.showServerPicker = true
        } label: {
            Text("no servers connected · connect")
                .litterMeta()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LitterSpace.margin)
                .padding(.bottom, LitterSpace.s)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessions.connectButton")
    }

    private var sessionSearchField: some View {
        HStack(spacing: LitterSpace.s) {
            TextField("Search sessions", text: $sessionSearchQuery)
                .litterFont(size: 17)
                .foregroundStyle(LitterTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
            if !sessionSearchQuery.isEmpty {
                Button("clear") { sessionSearchQuery = "" }
                    .litterMeta()
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LitterSpace.m)
        .frame(height: 40)
        .background(LitterTheme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, LitterSpace.margin)
        .padding(.top, LitterSpace.s)
        .padding(.bottom, LitterSpace.s)
    }

    private func isPinned(_ key: ThreadKey) -> Bool {
        pinnedKeys.contains(PinnedThreadKey(threadKey: key))
    }

    private func togglePin(_ thread: AppSessionSummary) {
        let pin = PinnedThreadKey(threadKey: thread.key)
        if pinnedKeys.contains(pin) {
            if let onUnpin { onUnpin(thread.key) } else { SavedThreadsStore.remove(pin) }
            pinnedKeys.remove(pin)
        } else {
            if let onPin { onPin(thread.key) } else { SavedThreadsStore.add(pin) }
            pinnedKeys.insert(pin)
        }
    }

    private var canLoadMoreSessions: Bool {
        sessionsModel.derivedData.allThreads.count >= Int(sessionHydrationLimit)
    }

    /// Automatic pagination: a row within `loadMoreThresholdRows` of the end
    /// appeared, so fetch the next page.
    private func loadMoreIfNeeded(rowIndex: Int, rowCount: Int) {
        guard canLoadMoreSessions, !isSessionLoadInFlight,
              rowIndex >= rowCount - SessionListRules.loadMoreThresholdRows else { return }
        loadNextPage()
    }

    private func loadNextPage() {
        guard !isSessionLoadInFlight else { return }
        sessionHydrationLimit += Self.sessionHydrationPageSize
        refreshSessions()
    }

    private func sessionList(derived: SessionsDerivedData) -> some View {
        let now = Date()
        let threads = derived.filteredThreads
        let indexByKey = Dictionary(threads.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = SessionListSection.group(
            threads,
            now: now,
            isPinned: { isPinned($0.key) },
            updatedAt: { ephemeralStateByThreadKey[$0.key]?.updatedAt ?? $0.updatedAtDate },
            isActive: { ephemeralStateByThreadKey[$0.key]?.hasTurnActive ?? $0.hasActiveTurn }
        )
        return ScrollViewReader { proxy in
            List {
                ForEach(groups, id: \.section) { group in
                    QuietSectionLabelRow(section: group.section)
                        .quietListRow()
                    ForEach(group.items) { thread in
                        sessionRow(thread, now: now)
                            .quietListRow()
                            .id(thread.key)
                            .onAppear {
                                loadMoreIfNeeded(rowIndex: indexByKey[thread.key] ?? 0, rowCount: threads.count)
                            }
                    }
                }
                if canLoadMoreSessions {
                    loadMoreSessionsRow
                        .quietListRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .environment(\.defaultMinListRowHeight, 0)
            .contentMargins(.bottom, LitterSpace.xl, for: .scrollContent)
            .transaction { $0.animation = nil }
            .onAppear {
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: pendingActiveSessionScroll) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: derived.filteredThreadKeys) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func sessionRowContextMenu(_ thread: AppSessionSummary) -> some View {
        Button {
            togglePin(thread)
        } label: {
            Label(isPinned(thread.key) ? "Unpin" : "Pin", systemImage: isPinned(thread.key) ? "pin.slash" : "pin")
        }

        Button {
            renamingThreadKey = thread.key
            renameCurrentTitle = thread.sessionTitle
            renameDraft = ""
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            Task { await forkThread(thread) }
        } label: {
            Label("Fork", systemImage: "arrow.triangle.branch")
        }

        Button(role: .destructive) {
            archiveTargetKey = thread.key
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func sessionRow(_ thread: AppSessionSummary, now: Date) -> some View {
        let ephemeral = ephemeralStateByThreadKey[thread.key]
        let hasTurnActive = ephemeral?.hasTurnActive ?? thread.hasActiveTurn
        let updatedAt = ephemeral?.updatedAt ?? thread.updatedAtDate
        var meta = [QuietMetaPart(thread.serverDisplayName)]
        if let project = sessionProjectName(thread.cwd) { meta.append(QuietMetaPart(project)) }
        if thread.isSubagent {
            meta.append(QuietMetaPart(thread.agentDisplayLabel ?? "agent"))
        } else if thread.isFork {
            meta.append(QuietMetaPart("fork"))
        }
        if resumingKey == thread.key {
            meta.append(QuietMetaPart("opening"))
        } else if hasTurnActive {
            meta.append(QuietMetaPart("working"))
        } else {
            meta.append(QuietMetaPart(sessionAgeLabel(updatedAt, now: now)))
        }

        return QuietSessionRow(title: thread.sessionTitle, meta: meta)
            .onTapGesture {
                guard resumingKey == nil else { return }
                Task { await resumeSession(thread) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sessions.sessionRow")
            .hoverEffect(.highlight)
            .contextMenu { sessionRowContextMenu(thread) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    togglePin(thread)
                } label: {
                    Label(isPinned(thread.key) ? "Unpin" : "Pin", systemImage: isPinned(thread.key) ? "pin.slash" : "pin")
                }
                .tint(LitterTheme.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    archiveTargetKey = thread.key
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    Task { await forkThread(thread) }
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
                .tint(LitterTheme.textMuted)
            }
    }

    private func scheduleActiveSessionScrollIfNeeded() {
        guard activeThreadKey != nil else { return }
        pendingActiveSessionScroll = true
    }

    private func scrollToActiveSessionIfNeeded(derived: SessionsDerivedData, proxy: ScrollViewProxy) {
        guard pendingActiveSessionScroll, let activeKey = activeThreadKey else { return }
        pendingActiveSessionScroll = false
        guard derived.filteredThreads.contains(where: { $0.key == activeKey }) else { return }
        proxy.scrollTo(activeKey, anchor: .center)
    }

    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    private func loadSessionsIfNeeded(force: Bool = false) async {
        guard autoLoadSessions else { return }
        guard force || !hasLoadedInitialSessions else { return }
        await loadSessions()
    }

    private func refreshSessions() {
        Task {
            await loadSessions()
        }
    }

    private var loadMoreSessionsRow: some View {
        Button(action: loadNextPage) {
            Text(isLoading ? "loading more…" : "load more")
                .litterMeta()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: SessionListRules.sectionLabelHeight + 12)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityIdentifier("sessions.loadMore")
    }

    private func loadSessions() async {
        let signpostID = OSSignpostID(log: sessionsScreenSignpostLog)
        os_signpost(.begin, log: sessionsScreenSignpostLog, name: "LoadSessions", signpostID: signpostID)
        defer { os_signpost(.end, log: sessionsScreenSignpostLog, name: "LoadSessions", signpostID: signpostID) }

        guard !connectedServerIds.isEmpty else {
            isLoading = false
            return
        }
        guard !isSessionLoadInFlight else {
            return
        }
        isSessionLoadInFlight = true
        defer { isSessionLoadInFlight = false }

        isLoading = true
        let serverIds = selectedServerFilterId.map { [$0] } ?? connectedServerIds
        let runtimeKinds = selectedRuntimeKindFilter.map { [$0] }
        let hydrationLimit = sessionHydrationLimit
        let client = appModel.client
        let failures = await withTaskGroup(of: String?.self) { group in
            for serverId in serverIds {
                group.addTask {
                    do {
                        try await client.listThreads(
                            serverId: serverId,
                            params: AppListThreadsRequest(limit: hydrationLimit, sortKey: .updatedAt, sortDirection: .desc, runtimeKinds: runtimeKinds)
                        )
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            return await group.reduce(into: [String]()) { errors, error in
                if let error { errors.append(error) }
            }
        }
        if failures.count == serverIds.count {
            sessionActionErrorMessage = failures.first
        }
        await appModel.refreshSnapshot()

        // Seed recent directories from loaded sessions.
        if let snapshot = appModel.snapshot {
            for server in snapshot.servers {
                let entries = snapshot.sessionSummaries
                    .filter { $0.key.serverId == server.serverId && !$0.cwd.isEmpty }
                    .map { summary in
                        let date = summary.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantPast
                        return RecentDirectoryEntry(
                            serverId: server.serverId,
                            path: summary.cwd,
                            lastUsedAt: date,
                            useCount: 0
                        )
                    }
                if !entries.isEmpty {
                    RecentDirectoryStore.shared.mergeSessionDirectories(entries, for: server.serverId)
                }
            }
        }

        hasLoadedInitialSessions = true
        isLoading = false
    }

    private func resumeSession(_ thread: AppSessionSummary) async {
        guard resumingKey == nil else { return }
        resumingKey = thread.key
        defer { resumingKey = nil }
        sessionActionErrorMessage = nil
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        let resumeKey = await appModel.hydrateThreadPermissions(for: thread.key, appState: appState)
            ?? thread.key
        appModel.activateThread(resumeKey)
        onOpenConversation(resumeKey)

        do {
            let nextKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: thread.cwd
            )
            if !thread.cwd.isEmpty {
                RecentDirectoryStore.shared.record(path: thread.cwd, for: thread.key.serverId)
            }
            if nextKey != resumeKey {
                appModel.activateThread(nextKey)
                onOpenConversation(nextKey)
            }
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
    }

    private func startNewSession(serverId: String, cwd: String) async {
        guard !isStartingNewSession else { return }
        isStartingNewSession = true
        defer { isStartingNewSession = false }
        sessionActionErrorMessage = nil
        do {
            guard try await appModel.ensureLocalAuthForThreadStart(serverId: serverId) else {
                return
            }
            await conversationWarmup.prewarmIfNeeded()
            workDir = cwd
            appState.currentCwd = cwd
            let startedKey = try await appModel.client.startThread(
                serverId: serverId,
                params: launchConfig().threadStartRequest(
                    cwd: cwd,
                    dynamicTools: appModel.localGenerativeUiToolSpecs(for: serverId)
                )
            )
            RecentDirectoryStore.shared.record(path: cwd, for: serverId)
            SavedThreadsStore.add(.init(threadKey: startedKey))
            appModel.store.setActiveThread(key: startedKey)
            await appModel.refreshThreadSnapshot(key: startedKey)

            // startThread already created the thread and applied it to the store;
            // prefer the snapshot key if available, otherwise use the returned key
            // directly instead of calling ensureThreadLoaded (which does expensive
            // retry loops with thread/read + thread/list RPCs).
            let resolvedKey = appModel.snapshot?.threadSnapshot(for: startedKey)?.key ?? startedKey
            onOpenConversation(resolvedKey)
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
    }

    private func forkThread(_ thread: AppSessionSummary) async {
        guard !isForkingActiveThread else { return }
        isForkingActiveThread = true
        defer { isForkingActiveThread = false }
        do {
            let sourceKey = await appModel.hydrateThreadPermissions(for: thread.key, appState: appState)
                ?? thread.key
            let nextKey = try await appModel.client.forkThread(
                serverId: sourceKey.serverId,
                params: launchConfig(for: sourceKey).threadForkRequest(
                    threadId: sourceKey.threadId,
                    cwdOverride: thread.cwd
                )
            )
            appModel.store.setActiveThread(key: nextKey)
            await appModel.refreshThreadSnapshot(key: nextKey)
            workDir = thread.cwd
            appState.currentCwd = thread.cwd
            onOpenConversation(nextKey)
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
    }

    private func launchConfig(for threadKey: ThreadKey? = nil) -> AppThreadLaunchConfig {
        let selectedModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelectedModel = !selectedModel.isEmpty
        return AppThreadLaunchConfig(
            agentRuntimeKind: hasSelectedModel ? appState.selectedAgentRuntimeKind : nil,
            model: hasSelectedModel ? selectedModel : nil,
            approvalPolicy: appState.launchApprovalPolicy(for: threadKey),
            sandbox: appState.launchSandboxMode(for: threadKey),
            developerInstructions: nil,
            persistExtendedHistory: true
        )
    }

    private func submitRename() async {
        guard let key = renamingThreadKey else { return }
        let nextTitle = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextTitle.isEmpty else { return }
        do {
            try await appModel.renameThread(
                serverId: key.serverId,
                threadId: key.threadId,
                title: nextTitle
            )
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
        renamingThreadKey = nil
        renameCurrentTitle = ""
        renameDraft = ""
    }

    private func confirmArchiveSession() async {
        guard let key = archiveTargetKey else { return }
        do {
            _ = try await appModel.client.archiveThread(
                serverId: key.serverId,
                params: AppArchiveThreadRequest(threadId: key.threadId)
            )
            if appModel.snapshot?.activeThread == nil {
                workDir = ""
                appState.currentCwd = ""
            }
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
        archiveTargetKey = nil
    }

}

#if DEBUG
#Preview("Sessions Screen") {
    LitterPreviewScene(
        appModel: LitterPreviewData.makeSidebarAppModel(),
        appState: LitterPreviewData.makeAppState()
    ) {
        NavigationStack {
            SessionsScreen(autoLoadSessions: false, onOpenConversation: { _ in })
        }
    }
}
#endif
