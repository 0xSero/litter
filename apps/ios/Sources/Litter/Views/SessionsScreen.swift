import SwiftUI
import os

private let sessionsScreenSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "SessionsScreen"
)

struct SessionsScreen: View {
    private static let sessionListPageLimit: UInt32 = 80

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
    @State private var collapsedWorkspaceGroupIDs: Set<String> = []
    @State private var collapsedSessionNodeKeys: Set<ThreadKey> = []
    @State private var pendingActiveSessionScroll = false
    @State private var sessionSearchDebounceTask: Task<Void, Never>?
    @State private var hasLoadedInitialSessions = false
    @State private var isSessionLoadInFlight = false
    private let autoLoadSessions: Bool
    private let onOpenConversation: (ThreadKey) -> Void
    private let onInfo: (() -> Void)?
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(
        autoLoadSessions: Bool = true,
        onOpenConversation: @escaping (ThreadKey) -> Void,
        onInfo: (() -> Void)? = nil
    ) {
        self.autoLoadSessions = autoLoadSessions
        self.onOpenConversation = onOpenConversation
        self.onInfo = onInfo
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
                    HStack(spacing: 4) {
                        if let onInfo {
                            Button(action: onInfo) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(LitterTheme.accent)
                            }
                        }
                        refreshToolbarButton
                    }
                }
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
            .onChange(of: derived.workspaceGroupIDs) { _, ids in
                let idSet: Set<String> = Set(ids)
                collapsedWorkspaceGroupIDs = collapsedWorkspaceGroupIDs.intersection(idSet)
            }
            .onChange(of: derived.allThreadKeys) { _, keys in
                let keySet: Set<ThreadKey> = Set(keys)
                collapsedSessionNodeKeys = collapsedSessionNodeKeys.intersection(keySet)
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

    private func screenLayout(derived: SessionsDerivedData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            newSessionButton
            Divider().background(LitterTheme.separator)
            serversRow
            Divider().background(LitterTheme.separator)

            if derived.allThreads.isEmpty {
                Spacer()
                if isLoading {
                    ProgressView().tint(LitterTheme.accent).frame(maxWidth: .infinity)
                } else {
                    Text("No sessions yet")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textMuted)
                        .frame(maxWidth: .infinity)
                }
                Spacer()
            } else {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LitterTheme.accent)
                        Text("Loading more sessions...")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textMuted)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider().background(LitterTheme.separator)
                }
                runtimeKindPillRow
                sessionSearchBar
                sessionFilterRow
                Divider().background(LitterTheme.separator)
                if derived.filteredThreads.isEmpty {
                    Spacer()
                    Text("No matches for \"\(trimmedSessionSearchQuery)\"")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textMuted)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    sessionList(derived: derived)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
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

    private var workspaceSortMode: WorkspaceSortMode {
        get { WorkspaceSortMode(rawValue: appState.sessionsWorkspaceSortModeRaw) ?? .mostRecent }
        nonmutating set { appState.sessionsWorkspaceSortModeRaw = newValue.rawValue }
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

    private var newSessionButton: some View {
        Button {
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
        } label: {
            HStack {
                if isStartingNewSession {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LitterTheme.textOnAccent)
                } else {
                    Image(systemName: "plus")
                        .litterFont(.subheadline, weight: .medium)
                    Text("New Session")
                        .litterFont(.subheadline)
                }
            }
            .foregroundColor(LitterTheme.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(LitterTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(isStartingNewSession)
        // Mac builds (Catalyst + iOS-on-Mac) bind Cmd+N at the menu
        // level via `MacCommands`; the in-view shortcut would either
        // double-bind (Catalyst) or be the only binding (iOS-on-Mac
        // doesn't get menus, so we keep it on then).
        .keyboardShortcut(LitterPlatform.isCatalyst ? nil : KeyboardShortcut("n", modifiers: [.command]))
        .accessibilityIdentifier("sessions.newSessionButton")
        .padding(isRegularSurface ? 12 : 16)
    }

    private var isRegularSurface: Bool {
        LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass)
    }

    private var refreshToolbarButton: some View {
        Button(action: refreshSessions) {
            Group {
                if isLoading && hasLoadedInitialSessions {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LitterTheme.accent)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .litterFont(.subheadline, weight: .semibold)
                        .foregroundColor(connectedServers.isEmpty ? LitterTheme.textMuted : LitterTheme.accent)
                }
            }
        }
        .disabled(isLoading || connectedServers.isEmpty)
        .accessibilityLabel("Refresh sessions")
        .accessibilityIdentifier("sessions.refreshButton")
    }

    private var serversRow: some View {
        let connected = connectedServers
        let activeThread = sessionsModel.derivedData.allThreads.first(where: { $0.key == activeThreadKey })
        let activeThreadEphemeralState = activeThread.flatMap { ephemeralStateByThreadKey[$0.key] }

        return ViewThatFits(in: .horizontal) {
            serversRowContent(
                connected: connected,
                activeThread: activeThread,
                activeThreadEphemeralState: activeThreadEphemeralState,
                useSpacer: true
            )
            ScrollView(.horizontal, showsIndicators: false) {
                serversRowContent(
                    connected: connected,
                    activeThread: activeThread,
                    activeThreadEphemeralState: activeThreadEphemeralState,
                    useSpacer: false
                )
            }
        }
        .padding(.horizontal, isRegularSurface ? 12 : 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func serversRowContent(
        connected: [HomeDashboardServer],
        activeThread: AppSessionSummary?,
        activeThreadEphemeralState: SessionsModel.ThreadEphemeralState?,
        useSpacer: Bool
    ) -> some View {
        HStack(spacing: 10) {
            if connected.isEmpty {
                Image(systemName: "xmark.circle")
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(width: 20)
                Text("Not connected")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textMuted)
                    .fixedSize(horizontal: true, vertical: false)
                if useSpacer { Spacer() }
                Button("Connect") {
                    appState.showServerPicker = true
                }
                .accessibilityIdentifier("sessions.connectButton")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.accent)
                .hoverEffect(.highlight)
            } else {
                Image(systemName: "server.rack")
                    .foregroundColor(LitterTheme.accent)
                    .frame(width: 20)
                Text("\(connected.count) server\(connected.count == 1 ? "" : "s")")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                if useSpacer { Spacer() }
                Button("Add") {
                    appState.showServerPicker = true
                }
                .accessibilityIdentifier("sessions.addServerButton")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.accent)
                .hoverEffect(.highlight)
                if let activeThread {
                    Button {
                        Task { await forkThread(activeThread) }
                    } label: {
                        if isForkingActiveThread {
                            ProgressView()
                                .controlSize(.small)
                                .tint(LitterTheme.accent)
                        } else {
                            Text("Fork")
                        }
                    }
                    .disabled(isForkingActiveThread || (activeThreadEphemeralState?.hasTurnActive ?? activeThread.hasActiveTurn))
                    .litterFont(.caption)
                    .foregroundColor((activeThreadEphemeralState?.hasTurnActive ?? activeThread.hasActiveTurn) ? LitterTheme.textMuted : LitterTheme.accent)
                    .hoverEffect(.highlight)
                }
            }
        }
    }

    private var runtimeKindPillRow: some View {
        // Only show pills when the current sessions list actually contains
        // multiple runtimes — a single-runtime user (Codex-only) doesn't
        // need to filter, and the row would just be visual noise.
        let runtimeKinds = Set(sessionsModel.derivedData.allThreads.map(\.agentRuntimeKind))
        return Group {
            if runtimeKinds.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        runtimeKindPill(label: "All", icon: "square.grid.2x2", kind: nil)
                        ForEach(orderedRuntimeKinds(present: runtimeKinds), id: \.self) { kind in
                            runtimeKindPill(
                                label: runtimeKindLabel(kind),
                                icon: runtimeKindIcon(kind),
                                kind: kind
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func runtimeKindPill(label: String, icon: String, kind: AgentRuntimeKind?) -> some View {
        let isActive = selectedRuntimeKindFilter == kind
        return Button {
            selectedRuntimeKindFilter = kind
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .litterFont(size: 10, weight: .semibold)
                Text(label)
                    .lineLimit(1)
            }
            .litterFont(.caption)
            .foregroundColor(isActive ? LitterTheme.textOnAccent : LitterTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? LitterTheme.accent : LitterTheme.surface.opacity(0.65))
            .overlay(
                Capsule()
                    .stroke(isActive ? LitterTheme.accent : LitterTheme.border.opacity(0.7), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func orderedRuntimeKinds(present: Set<AgentRuntimeKind>) -> [AgentRuntimeKind] {
        AgentRuntimeKind.presentationOrder.filter { present.contains($0) }
    }

    private func runtimeKindLabel(_ kind: AgentRuntimeKind) -> String {
        kind.titleDisplayLabel
    }

    private func runtimeKindIcon(_ kind: AgentRuntimeKind) -> String {
        // The filter pill renders an SF Symbol; the alleycat manifest
        // ships a PNG, not an SF Symbol name, so we use a generic
        // fallback here. Richer rendering of the actual agent icon
        // happens via `AgentIconView` everywhere else in the app.
        _ = kind
        return "person.fill"
    }

    private var sessionSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(LitterTheme.textMuted)
                .litterFont(.caption)

            TextField("Search sessions", text: $sessionSearchQuery)
                .litterFont(.footnote)
                .foregroundColor(LitterTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

            if !sessionSearchQuery.isEmpty {
                Button {
                    sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(LitterTheme.textMuted)
                        .litterFont(size: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LitterTheme.surface.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitterTheme.border.opacity(0.85), lineWidth: 1)
        )
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sessionFilterRow: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All servers") { selectedServerFilterId = nil }
                ForEach(connectedServerOptions, id: \.id) { option in
                    Button(option.name) { selectedServerFilterId = option.id }
                }
            } label: {
                filterChip(
                    title: selectedServerFilterTitle,
                    isActive: selectedServerFilterId != nil,
                    icon: "server.rack"
                )
            }
            .buttonStyle(.plain)

            Button {
                showOnlyForks.toggle()
            } label: {
                filterChip(
                    title: "Forks",
                    isActive: showOnlyForks,
                    icon: "arrow.triangle.branch"
                )
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(WorkspaceSortMode.allCases) { mode in
                    Button(mode.title) { workspaceSortMode = mode }
                }
            } label: {
                filterChip(
                    title: workspaceSortMode.title,
                    isActive: workspaceSortMode != .mostRecent,
                    icon: "arrow.up.arrow.down"
                )
            }
            .buttonStyle(.plain)

            if selectedServerFilterId != nil || showOnlyForks {
                Button("Clear") {
                    selectedServerFilterId = nil
                    showOnlyForks = false
                }
                .litterFont(.caption)
                .foregroundColor(LitterTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var selectedServerFilterTitle: String {
        guard let selectedServerFilterId else { return "All servers" }
        return connectedServerOptions.first(where: { $0.id == selectedServerFilterId })?.name ?? "All servers"
    }

    private func filterChip(title: String, isActive: Bool, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .litterFont(size: 10, weight: .semibold)
            Text(title)
                .lineLimit(1)
        }
        .litterFont(.caption)
        .foregroundColor(isActive ? LitterTheme.textOnAccent : LitterTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? LitterTheme.accent : LitterTheme.surface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? LitterTheme.accent : LitterTheme.border.opacity(0.7), lineWidth: 1)
        )
        .cornerRadius(7)
    }

    private func workspaceGroupHeader(_ group: WorkspaceSessionGroup) -> some View {
        let isCollapsed = collapsedWorkspaceGroupIDs.contains(group.id)

        return Button {
            if isCollapsed {
                collapsedWorkspaceGroupIDs.remove(group.id)
            } else {
                collapsedWorkspaceGroupIDs.insert(group.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .litterFont(size: 10, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(width: 12)

                Image(systemName: "folder")
                    .litterFont(size: 11, weight: .semibold)
                    .foregroundColor(LitterTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.workspaceTitle)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textPrimary)
                        .lineLimit(1)

                    Text(group.serverHost)
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textMuted)
                        .lineLimit(1)

                    Text(abbreviateHomePath(group.workspacePath))
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LitterTheme.border.opacity(0.75))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func sessionList(derived: SessionsDerivedData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(derived.workspaceSections) { section in
                        if let title = section.title {
                            Text(title)
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                                .padding(.horizontal, 2)
                        }

                        ForEach(section.groups) { group in
                            workspaceGroupHeader(group)

                            if !collapsedWorkspaceGroupIDs.contains(group.id) {
                                ForEach(visibleSessionRows(for: group)) { row in
                                    let thread = row.thread
                                    let isCollapsed = collapsedSessionNodeKeys.contains(thread.key)

                                    sessionRow(
                                        thread,
                                        isActive: thread.key == activeThreadKey,
                                        derived: derived,
                                        ephemeralState: ephemeralStateByThreadKey[thread.key],
                                        depth: row.depth,
                                        hasChildren: row.hasChildren,
                                        isCollapsed: isCollapsed,
                                        onToggleNode: {
                                            guard row.hasChildren else { return }
                                            if isCollapsed {
                                                collapsedSessionNodeKeys.remove(thread.key)
                                            } else {
                                                collapsedSessionNodeKeys.insert(thread.key)
                                            }
                                        },
                                        onSelectSession: {
                                            guard resumingKey == nil else { return }
                                            Task { await resumeSession(thread) }
                                        }
                                    )
                                    .id(thread.key)
                                    .contextMenu {
                                        sessionRowContextMenu(thread)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            Task { await forkThread(thread) }
                                        } label: {
                                            Label("Fork", systemImage: "arrow.triangle.branch")
                                        }
                                        .tint(LitterTheme.accent)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            archiveTargetKey = thread.key
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
            }
            .onAppear {
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: pendingActiveSessionScroll) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: derived.filteredThreadKeys) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: collapsedWorkspaceGroupIDs) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: collapsedSessionNodeKeys) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func sessionRowContextMenu(_ thread: AppSessionSummary) -> some View {
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

    private func sessionRow(
        _ thread: AppSessionSummary,
        isActive: Bool,
        derived: SessionsDerivedData,
        ephemeralState: SessionsModel.ThreadEphemeralState?,
        depth: Int,
        hasChildren: Bool,
        isCollapsed: Bool,
        onToggleNode: @escaping () -> Void,
        onSelectSession: @escaping () -> Void
    ) -> some View {
        let parent = derived.parentByKey[thread.key]
        let hasTurnActive = ephemeralState?.hasTurnActive ?? thread.hasActiveTurn
        let updatedAt = ephemeralState?.updatedAt ?? thread.updatedAtDate

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: CGFloat(depth) * 8)
                    if hasChildren {
                        Button(action: onToggleNode) {
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .litterFont(size: 9, weight: .semibold)
                                .foregroundColor(LitterTheme.textSecondary)
                                .frame(width: 10, height: 10)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 10, height: 10)
                    }
                }
                .padding(.top, 2)

                HStack(alignment: .top, spacing: 6) {
                    if hasTurnActive {
                        PulsingDot().padding(.top, 3)
                    } else if thread.isSubagent {
                        subagentStatusIndicator(thread.subagentStatus).padding(.top, 3)
                    } else {
                        Circle().fill(LitterTheme.textMuted.opacity(0.4)).frame(width: 8, height: 8).padding(.top, 3)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            FormattedText(text: thread.sessionTitle, lineLimit: 2)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("sessions.sessionTitle")

                            if thread.isSubagent {
                                HStack(spacing: 3) {
                                    Image(systemName: "person.2.fill")
                                        .litterFont(size: 8, weight: .semibold)
                                    Text(thread.agentDisplayLabel ?? "Agent")
                                        .litterFont(.caption2)
                                }
                                .foregroundColor(LitterTheme.textOnAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(LitterTheme.success)
                                .cornerRadius(4)
                            } else if thread.isFork {
                                Text("Fork")
                                    .litterFont(.caption2)
                                    .foregroundColor(LitterTheme.textOnAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(LitterTheme.accent)
                                    .cornerRadius(4)
                            }

                            Spacer(minLength: 0)

                            if resumingKey == thread.key {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(LitterTheme.accent)
                            }
                        }

                        HStack(spacing: 4) {
                            Text(relativeDate(updatedAt))
                                .foregroundColor(LitterTheme.textSecondary)
                            if let provider = thread.sessionModelLabel {
                                Text("•")
                                    .foregroundColor(LitterTheme.textMuted)
                                Text(provider)
                                    .foregroundColor(LitterTheme.textMuted)
                            }
                            if let parent {
                                Text("•")
                                    .foregroundColor(LitterTheme.textMuted)
                                Text("from \(parent.sessionTitle)")
                                    .foregroundColor(LitterTheme.textMuted)
                            }
                        }
                        .litterFont(.caption2)
                        .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("sessions.sessionRow")
                .onTapGesture(perform: onSelectSession)
            }

            if isActive {
                lineageSummary(for: thread, derived: derived)
            }
        }
        .padding(.leading, 1)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LitterTheme.surfaceLight.opacity(0.55))
            }
        }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
    }

    private func lineageSummary(for thread: AppSessionSummary, derived: SessionsDerivedData) -> some View {
        let parent = derived.parentByKey[thread.key]
        let siblings = derived.siblingsByKey[thread.key] ?? []
        let children = derived.childrenByKey[thread.key] ?? []
        let hasLineage = parent != nil || !siblings.isEmpty || !children.isEmpty

        return Group {
            if hasLineage {
                VStack(alignment: .leading, spacing: 5) {
                    Divider().background(LitterTheme.border.opacity(0.7))

                    HStack(spacing: 6) {
                        if let parent {
                            Button {
                                Task { await resumeSession(parent) }
                            } label: {
                                lineageChip(title: "Parent", count: 1, isInteractive: true)
                            }
                            .buttonStyle(.plain)
                        }

                        if !siblings.isEmpty {
                            Menu {
                                ForEach(siblings) { sibling in
                                    Button(sibling.sessionTitle) {
                                        Task { await resumeSession(sibling) }
                                    }
                                }
                            } label: {
                                lineageChip(title: "Siblings", count: siblings.count, isInteractive: true)
                            }
                        }

                        if !children.isEmpty {
                            Menu {
                                ForEach(children) { child in
                                    Button(child.sessionTitle) {
                                        Task { await resumeSession(child) }
                                    }
                                }
                            } label: {
                                lineageChip(title: "Children", count: children.count, isInteractive: true)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func lineageChip(title: String, count: Int, isInteractive: Bool) -> some View {
        Text("\(title) \(count)")
            .litterFont(.caption2)
            .foregroundColor(isInteractive ? LitterTheme.accent : LitterTheme.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(LitterTheme.surface.opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isInteractive ? LitterTheme.accent.opacity(0.5) : LitterTheme.border.opacity(0.5), lineWidth: 1)
            )
            .cornerRadius(5)
    }

    @ViewBuilder
    private func subagentStatusIndicator(_ status: AppSubagentStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .litterFont(size: 8)
                .foregroundColor(LitterTheme.success)
                .frame(width: 8, height: 8)
        case .errored:
            Image(systemName: "exclamationmark.circle.fill")
                .litterFont(size: 8)
                .foregroundColor(LitterTheme.danger)
                .frame(width: 8, height: 8)
        case .shutdown:
            Image(systemName: "stop.circle.fill")
                .litterFont(size: 8)
                .foregroundColor(LitterTheme.textMuted)
                .frame(width: 8, height: 8)
        case .interrupted:
            Image(systemName: "pause.circle.fill")
                .litterFont(size: 8)
                .foregroundColor(LitterTheme.warning)
                .frame(width: 8, height: 8)
        case .pendingInit, .running, .unknown:
            Circle()
                .fill(LitterTheme.textMuted.opacity(0.4))
                .frame(width: 8, height: 8)
        }
    }

    private func visibleSessionRows(for group: WorkspaceSessionGroup) -> [SessionTreeRow] {
        var rows: [SessionTreeRow] = []

        func append(nodes: [SessionTreeNode], depth: Int) {
            for node in nodes {
                let hasChildren = !node.children.isEmpty
                rows.append(
                    SessionTreeRow(
                        thread: node.thread,
                        depth: depth,
                        hasChildren: hasChildren
                    )
                )

                if hasChildren && !collapsedSessionNodeKeys.contains(node.thread.key) {
                    append(nodes: node.children, depth: depth + 1)
                }
            }
        }

        append(nodes: group.treeRoots, depth: 0)
        return rows
    }

    private func scheduleActiveSessionScrollIfNeeded() {
        guard activeThreadKey != nil else { return }
        pendingActiveSessionScroll = true
    }

    private func scrollToActiveSessionIfNeeded(derived: SessionsDerivedData, proxy: ScrollViewProxy) {
        guard pendingActiveSessionScroll, let activeKey = activeThreadKey else { return }

        guard let activeThread = derived.filteredThreads.first(where: { $0.key == activeKey }) else {
            pendingActiveSessionScroll = false
            return
        }

        let activeWorkspaceGroupID = derived.workspaceGroupIDByThreadKey[activeThread.key] ?? workspaceGroupID(for: activeThread)
        if collapsedWorkspaceGroupIDs.contains(activeWorkspaceGroupID) {
            collapsedWorkspaceGroupIDs.remove(activeWorkspaceGroupID)
            return
        }

        if let collapsedAncestor = ancestorThreadKeys(for: activeKey, derived: derived)
            .reversed()
            .first(where: { collapsedSessionNodeKeys.contains($0) }) {
            collapsedSessionNodeKeys.remove(collapsedAncestor)
            return
        }

        pendingActiveSessionScroll = false
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(activeKey, anchor: .center)
        }
    }

    private func ancestorThreadKeys(for key: ThreadKey, derived: SessionsDerivedData) -> [ThreadKey] {
        var ancestors: [ThreadKey] = []
        var visited: Set<ThreadKey> = []
        var cursor: AppSessionSummary? = derived.parentByKey[key]

        while let thread = cursor, !visited.contains(thread.key) {
            ancestors.append(thread.key)
            visited.insert(thread.key)
            cursor = derived.parentByKey[thread.key]
        }

        return ancestors
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
        let client = appModel.client
        let failures = await withTaskGroup(of: String?.self) { group in
            for serverId in serverIds {
                group.addTask {
                    do {
                        try await client.listThreads(
                            serverId: serverId,
                            params: AppListThreadsRequest(limit: Self.sessionListPageLimit, sortKey: .updatedAt, sortDirection: .desc, runtimeKinds: runtimeKinds)
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
        sessionActionErrorMessage = nil
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        let resumeKey = await appModel.hydrateThreadPermissions(for: thread.key, appState: appState)
            ?? thread.key
        appModel.activateThread(resumeKey)
        resumingKey = nil
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

    private func relativeDate(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct SessionTreeRow: Identifiable {
    let thread: AppSessionSummary
    let depth: Int
    let hasChildren: Bool

    var id: ThreadKey { thread.key }
}

struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(LitterTheme.accent)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
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
