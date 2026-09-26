import SwiftUI
import UIKit

/// Which chrome layer the dashboard renders with.
///
///  - `.full`: the app's landing page — cat mark in the principal
///    toolbar item and the full `HomeBottomBar` composer docked along the
///    bottom. This is what iPhone compact and Catalyst
///    non-split use today.
///  - `.sidebar`: the trimmed projection used in the iPad / Catalyst
///    `NavigationSplitView` sidebar. Branding and the bottom
///    composer are stripped; toolbar trailing gains a "+" that fires
///    `onNewThread` so the detail pane can host the hero composer.
enum HomeDashboardChrome {
    case full
    case sidebar
}

struct HomeDashboardView: View {
    var chrome: HomeDashboardChrome = .full
    let recentSessions: [HomeDashboardRecentSession]
    let allSessions: [HomeDashboardRecentSession]
    let pinnedThreadKeys: [SavedThreadsStore.PinnedKey]
    let connectedServers: [HomeDashboardServer]
    let projects: [AppProject]
    let selectedServerId: String?
    let selectedProject: AppProject?
    let openingRecentSessionKey: ThreadKey?
    /// Precomputed by HomeDashboardModel so `.onChange` doesn't
    /// re-allocate + stringify the visible list on every body eval.
    let visibleHydrationSignature: String
    let visibleActivitySignature: String
    /// Precomputed server snapshot lookup so HomeModelChip and other home
    /// views don't read `appModel.snapshot` in body.
    var serverSnapshotsById: [String: AppServerSnapshot] = [:]
    let onOpenRecentSession: @MainActor (HomeDashboardRecentSession) async -> Void
    let onSelectServer: (HomeDashboardServer) -> Void
    let onAddServer: () -> Void
    let onOpenProjectPicker: () -> Void
    let onThreadCreated: (ThreadKey) -> Void
    let onShowSettings: () -> Void
    /// Optional: surface an "Apps" button alongside Settings. Wired by the
    /// hosting navigation when a "Saved Apps" launcher should be exposed.
    var onShowApps: (() -> Void)? = nil
    var onShowTerminal: (() -> Void)? = nil
    var onBrowseSessions: (() -> Void)? = nil
    let onPinThread: (ThreadKey) -> Void
    let onUnpinThread: (ThreadKey) -> Void
    let onHideThread: (ThreadKey) -> Void
    /// Sidebar-only: fired when the user taps the "+" in the toolbar.
    var onNewThread: (() -> Void)? = nil
    /// Resume a single thread so the connection has a live listener. Dashboard
    /// orchestrates the parallel calls and tracks per-row state so the left
    /// indicator can reflect it.
    var onHydrateThread: ((ThreadKey, Bool) async -> Void)? = nil
    /// Changes when servers connect or pins change; visible rows that could
    /// not hydrate earlier are retried.
    var hydrationRetrySignature: String = ""
    /// See `HomeDashboardModel.isSessionListSettled`.
    var isSessionListSettled: Bool = true
    var onDeleteThread: ((ThreadKey) async -> Void)? = nil
    var onReconnectServer: ((HomeDashboardServer) -> Void)? = nil
    var onRestartAppServer: ((HomeDashboardServer) -> Void)? = nil
    var onDisconnectServer: ((String) -> Void)? = nil
    var onRenameServer: ((String, String) -> Void)? = nil
    var onOpenRecording: ((URL) -> Void)? = nil
    /// Fires when the user commits a quick reply from the swipe action.
    /// Caller should call `appModel.startTurn` against the thread.
    var onSendReply: (@MainActor (ThreadKey, String) async -> Void)? = nil
    /// Cancels the active turn on the given thread. Caller looks up the
    /// thread's `activeTurnId` and calls `appModel.client.interruptTurn`.
    var onCancelThread: (@MainActor (ThreadKey) async -> Void)? = nil
    /// Long-press → "Fork" on a home session card. Caller forks the
    /// thread server-side (head fork, no rollback) and navigates to the
    /// new thread.
    var onForkThread: (@MainActor (HomeDashboardRecentSession) async -> Void)? = nil
    var onInputModeChange: ((HomeInputMode) -> Void)? = nil

    @State private var deleteTargetThread: HomeDashboardRecentSession?
    @State private var replyTargetThread: HomeDashboardRecentSession?
    /// Tracks threads the user just cancelled so their status dot can show
    /// red until the snapshot confirms the turn is no longer active.
    @State private var cancellingKeys: Set<String> = []
    /// Visibility-driven, bounded hydration (see `SessionListRules`).
    @State private var hydrator = SessionViewportHydrator()
    @State private var renameServerTarget: HomeDashboardServer?
    @State private var renameServerText = ""
    @State private var isShowingMountedFolders = false
    @State private var inputMode: HomeInputMode = .collapsed
    @State private var searchQuery = ""
    @State private var selectedSearchRuntimeKind: AgentRuntimeKind?
    @State private var isLoadingThreadListing = false
    @State private var suppressComposerCollapse = false
    @State private var isShowingModelPicker = false
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false

    private var launchableServers: [HomeDashboardServer] {
        connectedServers.filter(\.canLaunchSessions)
    }

    private var selectedMachineServerId: String? {
        let trimmed = selectedServerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var composerServerId: String? {
        selectedProject?.serverId
            ?? selectedMachineServerId
            ?? launchableServers.first(where: { !$0.isLocal })?.id
            ?? launchableServers.first?.id
    }

    private var selectedLaunchableServer: HomeDashboardServer? {
        let serverId = composerServerId
        guard let serverId else { return nil }
        return launchableServers.first { $0.id == serverId }
    }

    var onSearchThreads: (@Sendable (_ query: String, _ runtimeKind: AgentRuntimeKind?, _ serverId: String?, _ forceRepair: Bool) async -> Void)? = nil

    private var isSearchExpanded: Bool { inputMode == .search }

    private var searchSessions: [HomeDashboardRecentSession] {
        let serverId = selectedMachineServerId
        guard let serverId, !serverId.isEmpty else { return allSessions }
        return allSessions.filter { $0.serverId == serverId }
    }

    private var searchServers: [HomeDashboardServer] {
        let serverId = selectedMachineServerId
        guard let serverId, !serverId.isEmpty else { return connectedServers }
        return connectedServers.filter { $0.id == serverId }
    }

    private var availableSearchRuntimeKinds: [AgentRuntimeKind] {
        let kinds = Set(
            searchServers.flatMap { server in
                server.agentRuntimes
                    .filter(\.available)
                    .map(\.kind)
            }
        )
        return AgentRuntimeKind.presentationOrder.filter { kinds.contains($0) }
    }

    private var searchLoadID: String {
        [
            isSearchExpanded ? "open" : "closed",
            selectedMachineServerId ?? "all",
            searchQuery,
            selectedSearchRuntimeKind?.displayLabel ?? "all"
        ].joined(separator: "|")
    }

    private func hydrationId(_ key: ThreadKey) -> String {
        "\(key.serverId)/\(key.threadId)"
    }

    /// Row `index` of `visibleSessions` is on screen: request hydration
    /// for it and the next `SessionListRules.prefetchRows` rows. Only
    /// pinned rows without a live listener are hydrated, as before.
    private func requestHydration(fromRow index: Int) {
        let visible = visibleSessions
        guard !visible.isEmpty, index < visible.count else { return }
        let pinned = Set(pinnedThreadKeys)
        let upper = min(visible.count, index + SessionListRules.prefetchRows + 1)
        let keys = visible[index..<upper]
            .filter { !$0.isResumed && pinned.contains(SavedThreadsStore.PinnedKey(threadKey: $0.key)) }
            .map(\.key)
        hydrator.request(keys)
    }

    /// Re-evaluate hydration for rows currently on screen (servers came
    /// online, pins changed, list content changed).
    private func rehydrateVisibleRows(resetAttempts: Bool) {
        if resetAttempts { hydrator.resetAttempts() }
        let visible = visibleSessions
        let visibleIndices = visible.indices.filter { hydrator.visibleKeys.contains(visible[$0].key) }
        guard let first = visibleIndices.first, let last = visibleIndices.last else { return }
        let pinned = Set(pinnedThreadKeys)
        let upper = min(visible.count, last + SessionListRules.prefetchRows + 1)
        let keys = visible[first..<upper]
            .filter { !$0.isResumed && pinned.contains(SavedThreadsStore.PinnedKey(threadKey: $0.key)) }
            .map(\.key)
        hydrator.request(keys)
    }

    private var visibleSessions: [HomeDashboardRecentSession] {
        let serverId = selectedMachineServerId
        guard let serverId, !serverId.isEmpty else { return recentSessions }
        return recentSessions.filter { $0.serverId == serverId }
    }

    var body: some View {
        canvas
            .onAppear {
                PerfTracker.event("HomeDashboardView.appear", ["uptimeMs": ProcessInfo.processInfo.systemUptime * 1000])
                onInputModeChange?(inputMode)
            }
            .onChange(of: inputMode) { _, nextMode in
                onInputModeChange?(nextMode)
                if nextMode != .search {
                    selectedSearchRuntimeKind = nil
                }
            }
            .task { await TipJarStore.shared.loadProducts() }
            .onAppear {
                hydrator.hydrate = { key in await onHydrateThread?(key, true) }
            }
            .onChange(of: visibleHydrationSignature) { _, _ in
                rehydrateVisibleRows(resetAttempts: false)
            }
            .onChange(of: hydrationRetrySignature) { _, _ in
                rehydrateVisibleRows(resetAttempts: true)
            }
            // Clear a cancelled key once the snapshot says the turn is
            // actually gone. Gives the dot a brief red period while the
            // cancel is in flight, then reverts to normal indicator logic.
            .onChange(of: visibleActivitySignature) { _, _ in
                let stillActive = Set(
                    visibleSessions
                        .filter { $0.hasTurnActive }
                        .map { hydrationId($0.key) }
                )
                cancellingKeys.formIntersection(stillActive)
            }
            .task(id: searchLoadID) {
                guard isSearchExpanded, let onSearchThreads else { return }
                let query = searchQuery
                let runtimeKind = selectedSearchRuntimeKind
                let serverId = selectedMachineServerId
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                }
                await MainActor.run { isLoadingThreadListing = true }
                await onSearchThreads(query, runtimeKind, serverId, false)
                guard !Task.isCancelled else { return }
                await MainActor.run { isLoadingThreadListing = false }
            }
            .onChange(of: availableSearchRuntimeKinds) { _, kinds in
                if let selectedSearchRuntimeKind, !kinds.contains(selectedSearchRuntimeKind) {
                    self.selectedSearchRuntimeKind = nil
                }
            }
            .background(dashboardBackground)
            .alert("Delete Session?", isPresented: Binding(
                get: { deleteTargetThread != nil },
                set: { if !$0 { deleteTargetThread = nil } }
            )) {
                Button("Cancel", role: .cancel) { deleteTargetThread = nil }
                Button("Delete", role: .destructive) {
                    if let thread = deleteTargetThread {
                        Task { await onDeleteThread?(thread.key) }
                    }
                    deleteTargetThread = nil
                }
            } message: {
                Text("This will permanently delete \"\(deleteTargetThread?.sessionTitle ?? "this session")\".")
            }
            .alert("Rename server", isPresented: Binding(
                get: { renameServerTarget != nil },
                set: { if !$0 { renameServerTarget = nil } }
            )) {
                TextField("Server name", text: $renameServerText)
                Button("Cancel", role: .cancel) { renameServerTarget = nil }
                Button("Save") {
                    if let server = renameServerTarget {
                        let trimmed = renameServerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onRenameServer?(server.id, trimmed)
                        }
                    }
                    renameServerTarget = nil
                }
            }
            .sheet(item: $replyTargetThread) { thread in
                QuickReplySheet(
                    thread: thread,
                    onSend: { key, text in
                        await onSendReply?(key, text)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingMountedFolders) {
                MountedFoldersView()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(sidebarNavBarVisibility, for: .navigationBar)
            .toolbar { toolbarContent }
    }

    private var sidebarNavBarVisibility: Visibility { .visible }

    private func headerGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(LitterTheme.textSecondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Plain glyph buttons (44pt targets) directly on the background;
            // opted out of the iOS 26 shared glass capsule below.
            HStack(spacing: 0) {
                Button(action: onShowSettings) {
                    headerGlyph("gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.settingsButton")
                if let onBrowseSessions {
                    Button(action: onBrowseSessions) {
                        headerGlyph("clock.arrow.circlepath")
                    }
                    .accessibilityLabel("All Sessions")
                    .accessibilityIdentifier("home.allSessionsButton")
                }
                // Apps and Terminal become available after launch (saved
                // apps load, a server connects). Their slots are always
                // reserved so the header never re-lays out when they do.
                Button { onShowApps?() } label: {
                    headerGlyph("square.grid.2x2")
                }
                .accessibilityLabel("Apps")
                .opacity(onShowApps == nil ? 0 : 1)
                .disabled(onShowApps == nil)
                .accessibilityHidden(onShowApps == nil)
                Button { onShowTerminal?() } label: {
                    headerGlyph("terminal")
                }
                .accessibilityLabel("Terminal")
                .opacity(onShowTerminal == nil ? 0 : 1)
                .disabled(onShowTerminal == nil)
                .accessibilityHidden(onShowTerminal == nil)
            }
            .buttonStyle(.plain)
        }
        .litterPlainToolbarItem()
        ToolbarItem(placement: .principal) {
            if chrome == .sidebar {
                AnimatedLogo(size: 44)
            } else {
                // Supporter badges load from StoreKit after launch; the
                // fixed frame keeps the mark from sliding when they do.
                HStack(spacing: 4) {
                    SupporterKittyBadges(tierIndices: 0..<2)
                        .frame(width: 58, alignment: .trailing)
                    AnimatedLogo(size: 44)
                    SupporterKittyBadges(tierIndices: 2..<4)
                        .frame(width: 58, alignment: .leading)
                }
                .frame(height: 44)
            }
        }
        if chrome == .sidebar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onNewThread?()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(LitterTheme.textPrimary)
                }
                .accessibilityLabel("New thread")
            }
        }
    }

    /// The sidebar chrome on a Mac (Catalyst or iOS-on-Mac) sits inside
    /// SwiftUI's `NavigationSplitView` sidebar column, which renders
    /// Liquid Glass automatically. Painting the gradient on top would
    /// clobber that material, so we punch to `.clear` for that case
    /// only. Everywhere else the dashboard owns its own gradient backdrop.
    @ViewBuilder
    private var dashboardBackground: some View {
        if LitterPlatform.rendersAsMacApp && chrome == .sidebar {
            Color.clear
        } else {
            LitterTheme.backgroundGradient.ignoresSafeArea()
        }
    }

    private var canvas: some View {
        ZStack {
            // When search is open, replace the list entirely so we're not
            // fighting two scroll containers. When it's closed, the overlay
            // branch returns nothing and can't intercept scroll gestures.
            if isSearchExpanded {
                ZStack(alignment: .top) {
                    LitterTheme.backgroundGradient.ignoresSafeArea()
                    ThreadSearchResultsView(
                        sessions: searchSessions,
                        pinnedThreadKeys: Set(pinnedThreadKeys),
                        query: searchQuery,
                        runtimeKinds: availableSearchRuntimeKinds,
                        selectedRuntimeKind: $selectedSearchRuntimeKind,
                        isLoading: isLoadingThreadListing && searchSessions.isEmpty,
                        onRefresh: refreshSearchThreads,
                        onAdd: { session in
                            onPinThread(session.key)
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                inputMode = .collapsed
                            }
                            searchQuery = ""
                            selectedSearchRuntimeKind = nil
                        },
                        onRemove: { session in
                            onUnpinThread(session.key)
                        },
                        contentInsets: EdgeInsets(top: 48, leading: 0, bottom: chrome == .full ? 140 : 80, trailing: 0)
                    )
                }
                .transition(.opacity)
            } else {
                sessionsList
            }
        }
        .overlay(alignment: .top) { topChrome }
        .overlay(alignment: .bottom) {
            switch chrome {
            case .full:
                bottomChrome
            case .sidebar:
                sidebarBottomChrome
            }
        }
        .overlay {
            if showOnboardingCoachmarks {
                emptyHomeCat
            }
        }
        .overlayPreferenceValue(CoachmarkAnchorKey.self) { anchors in
            if showOnboardingCoachmarks {
                OnboardingCoachmarksView(anchors: anchors)
            }
        }
    }

    private func refreshSearchThreads() async {
        guard let onSearchThreads else { return }
        await MainActor.run { isLoadingThreadListing = true }
        await onSearchThreads(searchQuery, selectedSearchRuntimeKind, selectedMachineServerId, true)
        await MainActor.run { isLoadingThreadListing = false }
    }

    /// True whenever the visible session list is empty AND the user is in
    /// the default (collapsed) input mode — so the overlay doesn't fight the
    /// composer/search expansions, and disappears the moment a thread shows
    /// up in the current scope.
    private var showOnboardingCoachmarks: Bool {
        guard chrome == .full,
              isSessionListSettled,
              inputMode == .collapsed,
              !isSearchExpanded else { return false }
        return visibleSessions.isEmpty
    }

    // Search results are rendered directly in `canvas` as an inline
    // replacement for the sessions list when `isSearchExpanded` is true.

    private var topChrome: some View {
        ServerPillRow(
            servers: connectedServers,
            selectedServerId: selectedMachineServerId,
            onTap: onSelectServer,
            onReconnect: { server in onReconnectServer?(server) },
            onRestartAppServer: { server in onRestartAppServer?(server) },
            onRename: { server in
                renameServerText = server.displayName
                renameServerTarget = server
            },
            onRemove: { server in onDisconnectServer?(server.id) },
            onShowMountedFolders: { _ in isShowingMountedFolders = true },
            onAdd: onAddServer
        )
        // Fixed height from the first frame: pills and their status words
        // update in place instead of pushing content when servers arrive.
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    /// Sidebar chrome gets a compact search-only bar at the bottom —
    /// tapping the magnifying glass morphs it into a search field, which
    /// swaps the sessions list for `ThreadSearchResultsView` (the canvas
    /// already keys on `isSearchExpanded` regardless of chrome). The
    /// close button on the search field restores the sessions list.
    private var sidebarBottomChrome: some View {
        HomeBottomBar(
            mode: $inputMode,
            searchQuery: $searchQuery,
            project: nil,
            transcriptionServerId: nil,
            onThreadCreated: { _ in },
            compact: true
        )
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: Array(LitterTheme.headerScrim.reversed()),
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -30)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    /// Model pill for the home composer's bottom row; hidden until a
    /// launchable server is selected (the picker needs its catalog).
    private var composerModelPill: HomeComposerModelPill? {
        guard selectedLaunchableServer != nil else { return nil }
        let models = composerServerId.flatMap { serverSnapshotsById[$0] }?.availableModels ?? []
        return HomeComposerModelPill(
            label: HomeModelChip.modelLabel(appState: appState, models: models),
            detail: HomeModelChip.modelDetail(appState: appState, fastMode: fastMode),
            open: { isShowingModelPicker = true }
        )
    }

    private var bottomChrome: some View {
        VStack(alignment: .trailing, spacing: 6) {
            DebugBuildLabel()
                .padding(.trailing, 14)
            if inputMode == .composer {
                HStack(spacing: 8) {
                    Spacer()
                    // Invisible host: owns the model picker sheet and the
                    // per-server model sync. The model itself shows as a
                    // pill inside the composer (`composerModelPill`).
                    HomeModelChip(
                        serverId: composerServerId,
                        disabled: selectedLaunchableServer == nil,
                        server: composerServerId.flatMap { serverSnapshotsById[$0] },
                        onSheetStateChange: { isPresented in
                            suppressComposerCollapse = isPresented
                        },
                        showsLabel: false,
                        presentation: $isShowingModelPicker
                    )
                    ProjectChip(
                        project: selectedProject,
                        disabled: launchableServers.isEmpty,
                        onTap: onOpenProjectPicker
                    )
                }
                .padding(.horizontal, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HomeBottomBar(
                mode: $inputMode,
                searchQuery: $searchQuery,
                collapseSuppressed: suppressComposerCollapse,
                project: selectedProject,
                transcriptionServerId: composerServerId,
                onThreadCreated: onThreadCreated,
                modelPill: composerModelPill
            )
        }
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: Array(LitterTheme.headerScrim.reversed()),
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -30)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    private var sessionsList: some View {
        ZStack {
            if visibleSessions.isEmpty {
                Color.clear
            } else {
                HomeSessionsList(
                    sessions: visibleSessions,
                    pinnedThreadKeys: Set(pinnedThreadKeys),
                    offlineServerIds: Set(connectedServers.filter { !$0.canLaunchSessions }.map(\.id)),
                    hydratingKeys: hydrator.inFlight,
                    cancellingKeys: cancellingKeys,
                    openingKey: openingRecentSessionKey,
                    topInset: 48,
                    bottomInset: chrome == .full ? 140 : 24,
                    callbacks: HomeSessionsList.Callbacks(
                        onOpen: { session in
                            guard openingRecentSessionKey == nil else { return }
                            Task { await onOpenRecentSession(session) }
                        },
                        onReply: { session in replyTargetThread = session },
                        onHide: { key in onHideThread(key) },
                        onPin: { key in onPinThread(key) },
                        onUnpin: { key in onUnpinThread(key) },
                        onCancelTurn: { session in
                            cancellingKeys.insert(hydrationId(session.key))
                            Task { await onCancelThread?(session.key) }
                        },
                        onDelete: { session in deleteTargetThread = session },
                        onFork: { session in
                            Task { await onForkThread?(session) }
                        },
                        onShowPiP: { session in
                            StreamingPiPController.shared.start(for: session.key)
                        }
                    ),
                    onRowAppear: { index in
                        if index < visibleSessions.count {
                            hydrator.rowAppeared(visibleSessions[index].key)
                        }
                        requestHydration(fromRow: index)
                    },
                    onRowDisappear: { key in hydrator.rowDisappeared(key) }
                )
                // Extend edge-to-edge so rows scroll under the translucent
                // top/bottom chrome; content margins carve out rest space.
                .ignoresSafeArea()
            }
        }
    }

    /// Abstract cat mark on the empty Home, in the band between the
    /// add-server coachmark (y≈0.20) and the search/new-thread labels
    /// (y≈0.62/0.70). One short fade, no animated image decode. Long-press
    /// still plays the cat transmission easter egg.
    private var emptyHomeCat: some View {
        GeometryReader { proxy in
            CatTransmissionPressView {
                CatMark(width: 112, fadeIn: true)
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
        }
    }
}

// MARK: - Session Canvas Layout

private enum SessionCanvasLayout {
    static let horizontalPadding: CGFloat = LitterSpace.margin
}


// MARK: - Session Canvas Line

struct SessionCanvasLine: View {
    let session: HomeDashboardRecentSession
    let isOpening: Bool
    let isHydrating: Bool
    let isCancelling: Bool
    /// Committed integer zoom level — drives which zoom-gated layers
    /// are visible and the preview cap. UIKit controls the visible
    /// *container* height during a pinch; this view is purely a
    /// function of the integer display zoom.
    let zoomLevel: Int

    // No `@Environment(AppModel.self)` — the card is purely prop-driven.
    // That was the core of the streaming AttributeGraph hotspot: reading
    // `appModel.snapshot` from 20 cards created 20 subscription edges, each
    // invalidated per streaming-delta bump. `session` reaches us through
    // `HomeDashboardModel.refreshState`'s debounced observation path, so
    // propagation fans out to one observer (the parent), not twenty.

    /// Vertical padding around the card content. Matches the iOS zoom
    /// anchors `[3, 6, 10, 12]` for levels 1–4.
    fileprivate static func verticalPadding(for zoom: Int) -> CGFloat {
        let anchors: [CGFloat] = [10, 14, 16, 20]
        let idx = max(0, min(anchors.count - 1, zoom - 1))
        return anchors[idx]
    }

    private var isActive: Bool { session.hasTurnActive }
    private var timeAgo: String { relativeDate(Int64(session.updatedAt.timeIntervalSince1970)) }
    private var s: AppConversationStats? { session.stats }
    private var toolCallCount: UInt32 { s?.toolCallCount ?? 0 }
    private var turnCount: UInt32 { s?.turnCount ?? 0 }

    /// True when the most recent tool-capable item is still running.
    /// Derived from the Rust-side `recent_tool_log`, which records tool
    /// entries in chronological order — the last entry's status reflects
    /// the most recent tool. Tool-call activity is only updated on item
    /// upserts (not streaming deltas), so the log is always fresh for this
    /// check.
    private var isToolCallRunning: Bool {
        guard let last = session.recentToolLog.last else { return false }
        let s = last.status.lowercased()
        return s == "pending" || s == "inprogress"
    }

    /// Keep home-screen tool activity subordinate to assistant/user text.
    /// The home card's response preview uses conversation-body sizing, so
    /// the tool log should step down a tier rather than compete with it.
    private var toolLogFontSize: CGFloat {
        max(LitterSpace.minText, LitterFont.conversationBodyPointSize - 3)
    }

    // ────────────────────────────────────────────────────
    // Zoom levels — each must feel distinct:
    //
    //  1  SCAN     title + age (right). Max density for scanning a backlog.
    //  2  GLANCE   + identity strip (time · server · model · branch).
    //  3  READ     + telemetry strip (counts · adds/rems · ⏱ · ctx%) +
    //              user message (quoted) + 1 tool-log entry.
    //  4  DEEP     + lineage breadcrumb + 3 tool-log entries + response
    //              preview + sibling pills + cwd footer w/ Working pill.
    //
    // Identity (text) and telemetry (numbers) live on separate lines so a
    // 390 px iPhone row never has to truncate one to fit the other.
    // ────────────────────────────────────────────────────

    var body: some View {
        // Litter Quiet row: title, then one mono metadata line. No status
        // dot, shimmer or accent fill; a busy or failing session says so in
        // the metadata line as a single word.
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Lineage breadcrumb (zoom 4 only). Always present in the
                // tree so zoom transitions just animate its height; matches
                // the visibleWhen pattern used for the rest of the layers.
                lineageBreadcrumb
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .visibleWhen(zoomLevel >= 4 && (session.lineage?.ancestors.isEmpty == false))

                // Title row: title + fork rune (if branched) on the left,
                // a relative-age chip pinned to the right at zoom 1 so the
                // SCAN row carries recency info without crowding identity.
                // Higher zooms surface age inside `modelBadgeLine` and drop
                // the chip here so we never duplicate.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    FormattedText(text: session.sessionTitle, lineLimit: zoomLevel >= 4 ? 4 : 2)
                        .modifier(MarkdownMatchedTitleFont())
                        .foregroundStyle(LitterTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lineage = session.lineage, lineage.hasMultipleBranches {
                        forkRune(lineage: lineage)
                    }
                    Spacer(minLength: 6)
                    if isOpening {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(LitterTheme.textMuted)
                    } else if zoomLevel == 1 {
                        Text(stateWord ?? timeAgo)
                            .litterMeta(stateWordColor)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Detail below — gets full width. As zoom grows, additional
                // rows are revealed by the container's layout animation.
                // Inner VStack is pinned to full width so removals collapse
                // vertically only — otherwise the container sizes to the
                // widest child and short rows visually shrink to the left.
                // Every zoom-gated layer is *always* in the view tree;
                // per-zoom visibility is controlled via
                // `.visibleWhen(...)` which squashes the view to zero
                // height + zero opacity when hidden. SwiftUI still runs
                // layout for these views at every zoom (cost paid on
                // scroll, not on zoom change), but zoom transitions no
                // longer materialize new subtrees — they just animate
                // frame heights. Simpler, smoother zoom; uniform scroll
                // cost across zoom levels.
                VStack(alignment: .leading, spacing: 0) {
                    // Zoom-gated visibility — binary on committed
                    // `zoomLevel`. The UIKit host (HomeSessionsScrollView)
                    // sets zoomLevel=4 during a pinch so every layer is
                    // present and the UIKit frame clip reveals it
                    // progressively.
                    //
                    // Stacking order is the row's reading order:
                    //   identity  →  goal  →  telemetry  →  user msg  →
                    //   activity  →  response  →  branches  →  cwd
                    // Identity (time/server/model) and telemetry (counts/%/
                    // adds/rems) are intentionally on separate lines so a
                    // 390 px row never has to choose between truncating the
                    // server name and dropping a stat.
                    modelBadgeLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 2)
                    // Goal at z2/z3 renders standalone. At z4 it folds
                    // into `telemetryDashboard` (banner above the grid)
                    // so the dashed-bordered panel is the single home for
                    // both the objective and the metrics.
                    goalLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 2 && zoomLevel < 4 && session.goal != nil)
                    telemetryStrip
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 3)
                    userMessageLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 3)
                    activityHeader
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 4 && !session.recentToolLog.isEmpty)
                    // Zoom 4 takes the whole screen — show the full
                    // recent_tool_log (Rust caps at 8 already) so Edit
                    // entries don't get pushed off the visible suffix
                    // by newer Bash commands. Zoom 3 keeps it tight at
                    // 1 entry so multiple sessions can fit on screen.
                    toolLog(maxEntries: zoomLevel >= 4 ? 8 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 3)
                    responsePreview
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 4)
                    siblingPillsRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel >= 4 && (session.lineage?.hasMultipleBranches == true))
                    cwdFooter
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visibleWhen(zoomLevel == 4 && !session.cwd.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SessionCanvasLayout.horizontalPadding)
        .padding(.bottom, Self.verticalPadding(for: zoomLevel))
        .contentShape(Rectangle())
        .clipped()
        // Zoom transitions animate when triggered via `withAnimation`
        // (zoom button, pinch-end snap). Live pinch updates bypass
        // this — they set state directly so the card tracks the
        // finger without overshooting. We deliberately don't attach
        // `.animation(_:value: zoomLevel)` here because that would
        // wrap every zoomLevel change (including mid-pinch threshold
        // crossings) in an implicit animation and fight the live
        // tracking.
        .accessibilityIdentifier("home.recentSessionCard")
    }

    // MARK: - Zoom 2: meta line

    /// Inline stat chips: tool calls, turns, context %
    @ViewBuilder
    private var statChips: some View {
        if toolCallCount > 0 || turnCount > 0 {
            Text("\u{00b7}")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
        }
        if toolCallCount > 0 {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .litterFont(size: 8)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
            RollingMetricText("\(toolCallCount)")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
        }
        if turnCount > 0 {
            Image(systemName: "arrow.turn.down.right")
                .litterFont(size: 8)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
            RollingMetricText("\(turnCount)")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
        }
        if let tu = session.tokenUsage, let window = tu.contextWindow, window > 0 {
            let pct = Int((Double(tu.totalTokens) / Double(window)) * 100)
            Text("\u{00b7}")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
            RollingMetricText("\(pct)%")
                .foregroundStyle(pct > 80 ? LitterTheme.warning.opacity(0.8) : LitterTheme.textMuted.opacity(0.8))
        }
    }

    @ViewBuilder
    private var toolActivityLabel: some View {
        if let toolLabel = session.lastToolLabel {
            let parts = toolLabel.split(separator: " ", maxSplits: 1)
            let name = String(parts.first ?? "")
            toolIconView(for: name)
                .foregroundStyle(LitterTheme.accent)
            if parts.count > 1 {
                Text(String(parts.last ?? ""))
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text("thinking")
                .foregroundStyle(LitterTheme.accent)
        }
    }

    // MARK: - Zoom 2+: identity strip (time · server · model · branch)
    //
    // This row owns *only* identity. Telemetry (counts, %, adds/rems,
    // stopwatch) lives below in `telemetryStrip` so a 390 px iPhone row
    // never has to choose between truncating the server name and showing
    // a stat. At zoom 2 the strip stands alone (no telemetry yet); at
    // zoom 3+ it sits on top of the telemetry strip.

    /// One word for a state worth noticing. Healthy idle sessions show
    /// their age instead.
    private var stateWord: String? {
        if isCancelling { return "cancelling" }
        if isActive { return "working" }
        if isHydrating { return "loading" }
        return nil
    }

    private var stateWordColor: Color {
        isCancelling ? LitterTheme.warning : LitterTheme.meta
    }

    /// "server · model · 14m" in mono metadata, with the age replaced by a
    /// state word while the session is busy.
    private var modelBadgeLine: some View {
        let model = session.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 0) {
            Text(session.serverDisplayName)
            if !model.isEmpty {
                Text(" · ")
                Text(model)
            }
            Text(" · ")
            Text(stateWord ?? timeAgo)
                .foregroundStyle(stateWordColor)
            if let lineage = session.lineage, lineage.hasMultipleBranches {
                Text(" · ")
                branchChip(lineage: lineage)
            } else if session.isFork {
                Text(" · ")
                Text("fork")
            }
            if session.isSubagent, let agent = session.agentLabel {
                Text(" · ")
                Text(agent)
            }
            Spacer(minLength: 0)
        }
        .litterMeta()
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Zoom 3+: telemetry strip (counts · adds/rems · stopwatch · ctx%)
    //
    // The numeric line. Lives on its own row so identity above can render
    // full-width without competing for space. Wraps gracefully if the
    // device is narrow or the text scale is large — the only soft contract
    // is that nothing here truncates with an ellipsis.

    @ViewBuilder
    private var telemetryStrip: some View {
        if zoomLevel >= 4 {
            telemetryDashboard
        } else {
            telemetryRow
        }
    }

    /// Zoom 3: tight horizontal strip — chips flow left, no labels, no
    /// borders. Density-friendly so multiple sessions still fit on
    /// screen at this zoom.
    @ViewBuilder
    private var telemetryRow: some View {
        let stats = s
        let hasDiff = (stats?.diffAdditions ?? 0) > 0 || (stats?.diffDeletions ?? 0) > 0
        let hasContextPct: Bool = {
            guard let tu = session.tokenUsage, let window = tu.contextWindow else { return false }
            return window > 0
        }()
        let hasAny = turnCount > 0 || toolCallCount > 0 || hasDiff || session.lastTurnStart != nil || hasContextPct

        if hasAny {
            HStack(spacing: LitterSpace.m) {
                if turnCount > 0 {
                    RollingMetricText("\(turnCount) turns")
                }
                if toolCallCount > 0 {
                    RollingMetricText("\(toolCallCount) tools")
                }
                if let stats, hasDiff {
                    RollingMetricText("+\(stats.diffAdditions) -\(stats.diffDeletions)")
                }
                if let start = session.lastTurnStart {
                    TurnStopwatchChip(start: start, end: session.lastTurnEnd)
                }
                if let tu = session.tokenUsage, let window = tu.contextWindow, window > 0 {
                    let pct = Int((Double(tu.totalTokens) / Double(window)) * 100)
                    RollingMetricText("\(pct)%")
                        .foregroundStyle(pct > 80 ? LitterTheme.warning : LitterTheme.meta)
                }
                Spacer(minLength: 0)
            }
            .litterMeta()
            .padding(.top, LitterSpace.xs)
        }
    }

    /// Zoom 4: 2-column × 3-row dashboard between dashed rules. Each
    /// cell is `[icon] value label` — value bold/coloured, label dim.
    /// Cells with no data are placed as empty spaces so paired rows
    /// stay aligned. When the session has a goal, an objective banner
    /// folds into the top of the same dashed panel, and the tokens /
    /// duration cells prefer goal-derived numbers (the goal's budget
    /// burndown is more meaningful than session-wide totals).
    @ViewBuilder
    private var telemetryDashboard: some View {
        let stats = s
        let files = stats?.filesChanged ?? 0
        let pct: Int? = {
            guard let tu = session.tokenUsage, let window = tu.contextWindow, window > 0 else { return nil }
            return Int((Double(tu.totalTokens) / Double(window)) * 100)
        }()
        // Tokens: prefer goal.tokensUsed when goal is set, otherwise
        // session-wide totalTokens. Same swap for duration. Either way
        // the cell shows a single number, just from the most relevant
        // source for the current session state.
        let goal = session.goal
        let totalTokens: Int64? = {
            if let g = goal, g.tokensUsed > 0 { return g.tokensUsed }
            guard let tu = session.tokenUsage, tu.totalTokens > 0 else { return nil }
            return tu.totalTokens
        }()
        let durationSeconds: Int64? = {
            if let g = goal, g.timeUsedSeconds > 0 { return g.timeUsedSeconds }
            if let ms = stats?.sessionDurationMs, ms > 0 { return ms / 1000 }
            return nil
        }()
        let adds = stats?.diffAdditions ?? 0
        let rems = stats?.diffDeletions ?? 0

        let hasMetrics = files > 0 || adds > 0 || rems > 0 || pct != nil || totalTokens != nil || durationSeconds != nil
        let hasAny = hasMetrics || goal != nil
        if hasAny {
            VStack(alignment: .leading, spacing: 0) {
                if let goal {
                    goalBanner(goal: goal)
                    if hasMetrics {
                        // Mid-rule between objective and metrics so they
                        // read as two zones inside the same panel.
                        Color.clear.frame(height: LitterSpace.m)
                    }
                }
                if hasMetrics {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 14) {
                            statCell(icon: nil,
                                     value: files > 0 ? "\(files)" : nil,
                                     valueColor: LitterTheme.textPrimary,
                                     label: "files")
                            statCell(icon: nil,
                                     valuePrefix: nil,
                                     value: pct.map { "\($0)%" },
                                     valueColor: (pct ?? 0) > 80 ? LitterTheme.warning : LitterTheme.textPrimary,
                                     label: "context")
                        }
                        HStack(alignment: .top, spacing: 14) {
                            statCell(icon: nil,
                                     value: adds > 0 ? "+\(adds.formatted(.number.grouping(.automatic)))" : nil,
                                     valueColor: LitterTheme.textPrimary,
                                     label: "added")
                            statCell(icon: nil,
                                     value: totalTokens.map { Self.formatTokens($0) },
                                     valueColor: LitterTheme.textPrimary,
                                     label: "tok")
                        }
                        HStack(alignment: .top, spacing: 14) {
                            statCell(icon: nil,
                                     value: rems > 0 ? "-\(rems.formatted(.number.grouping(.automatic)))" : nil,
                                     valueColor: LitterTheme.textPrimary,
                                     label: "removed")
                            statCell(icon: nil,
                                     value: durationSeconds.map { Self.formatDuration($0) },
                                     valueColor: LitterTheme.textPrimary,
                                     label: "duration")
                        }
                    }
                }
            }
            .litterMeta(LitterTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, LitterSpace.s)
            .padding(.top, LitterSpace.xs)
        }
    }

    /// Goal banner that sits inside the dashboard panel at z4. Shows
    /// the small "GOAL" small-caps label, a status dot tinted by the
    /// goal's lifecycle, and the objective text (allowed to wrap).
    @ViewBuilder
    private func goalBanner(goal: AppThreadGoal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("goal ")
                    .foregroundStyle(LitterTheme.meta)
                Text(goalStatusLabel(goal.status).lowercased())
                    .foregroundStyle(goalStatusTint(goal.status))
            }
            .litterMeta()
            HStack(alignment: .top, spacing: LitterSpace.s) {
                Text(goal.objective)
                    .litterFont(size: 15, weight: .regular)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func goalStatusLabel(_ status: AppThreadGoalStatus) -> String {
        switch status {
        case .active: return "· ACTIVE"
        case .paused: return "· PAUSED"
        case .blocked: return "· BLOCKED"
        case .usageLimited: return "· USAGE"
        case .budgetLimited: return "· BUDGET"
        case .complete: return "· COMPLETE"
        }
    }

    /// Single dashboard cell: optional icon, value (bold/coloured),
    /// dim label. If `value` is nil the cell renders as an empty
    /// spacer so paired rows in the dashboard stay aligned.
    @ViewBuilder
    private func statCell(
        icon: String?,
        valuePrefix: String? = nil,
        value: String?,
        valueColor: Color,
        label: String
    ) -> some View {
        if let value {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .litterFont(size: 10)
                        .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
                        .frame(width: 14)
                }
                if let valuePrefix {
                    Text(valuePrefix)
                        .foregroundStyle(valueColor)
                }
                RollingMetricText(value)
                    .foregroundStyle(valueColor)
                Text(label)
                    .foregroundStyle(LitterTheme.meta)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Empty slot — keeps the column width stable so the paired
            // cell across the row doesn't shift when this one is missing.
            Color.clear.frame(height: 1).frame(maxWidth: .infinity)
        }
    }

    /// "86,012,400" → "86.0M", "12,400" → "12.4k", small values → "412".
    private static func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    /// "176560" → "49h 6m", "3320" → "55m 20s", "45" → "45s".
    private static func formatDuration(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let total = Int(seconds)
        let minutes = total / 60
        let remainSecs = total % 60
        if total < 3600 {
            return remainSecs == 0 ? "\(minutes)m" : "\(minutes)m \(remainSecs)s"
        }
        let hours = total / 3600
        let remainMins = (total % 3600) / 60
        return remainMins == 0 ? "\(hours)h" : "\(hours)h \(remainMins)m"
    }

    // MARK: - Zoom 2+: goal line

    /// Single-line goal row with status pill, objective, and usage chips
    /// (tokens + elapsed seconds). Mirrors the in-conversation goal card
    /// without the gauge — the home card stays scan-friendly.
    @ViewBuilder
    private var goalLine: some View {
        if let goal = session.goal {
            HStack(spacing: 6) {
                Text(goal.objective)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if goal.tokensUsed > 0 {
                    RollingMetricText(formatGoalTokens(goal.tokensUsed))
                        .foregroundStyle(LitterTheme.meta)
                }
                if goal.timeUsedSeconds > 0 {
                    RollingMetricText(formatGoalSeconds(goal.timeUsedSeconds))
                        .foregroundStyle(LitterTheme.meta)
                }
            }
            .litterMeta()
            .padding(.top, 2)
        }
    }

    private func goalStatusTint(_ status: AppThreadGoalStatus) -> Color {
        switch status {
        case .active, .paused, .complete: return LitterTheme.meta
        case .blocked, .usageLimited, .budgetLimited: return LitterTheme.warning
        }
    }

    private func formatGoalTokens(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private func formatGoalSeconds(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let total = Int(seconds)
        let minutes = total / 60
        let remainSecs = total % 60
        if total < 3600 {
            return remainSecs == 0 ? "\(minutes)m" : "\(minutes)m \(remainSecs)s"
        }
        let hours = total / 3600
        let remainMins = (total % 3600) / 60
        return remainMins == 0 ? "\(hours)h" : "\(hours)h \(remainMins)m"
    }

    // MARK: - Zoom 3+: last user message (quoted, single line)

    @ViewBuilder
    private var userMessageLine: some View {
        let message = (session.lastUserMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = session.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty && message != title {
            // Quoted block: accent left rule + faint accent fill so the
            // last user message reads as content rather than meta. Sits
            // between telemetry (above) and the tool log / response
            // preview (below) and visually breaks the two apart.
            FormattedText(text: message, lineLimit: zoomLevel >= 4 ? 3 : 1)
                .foregroundStyle(LitterTheme.textSecondary)
                .litterFont(size: LitterFont.conversationBodyPointSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, LitterSpace.m)
                .overlay(alignment: .leading) {
                    LitterTheme.userRule.frame(width: 2)
                }
                .padding(.top, LitterSpace.s)
        }
    }

    // MARK: - Zoom 4: "Recent activity" section header
    //
    // A small monospace label above the tool log so the icon list is
    // unambiguously "what just happened" rather than blending into the
    // user message preview above or the response preview below.

    @ViewBuilder
    private var activityHeader: some View {
        Text("recent activity")
            .litterSectionLabel()
            .padding(.top, LitterSpace.m)
    }

    // MARK: - Zoom 4: cwd footer (paired with working pill if active)
    //
    // Workspace path on the left, a small "Working…" pill on the right
    // when the session has a live turn. Both are peer-status info — they
    // belong on one line, not stacked.

    @ViewBuilder
    private var cwdFooter: some View {
        HStack(spacing: 8) {
            Text(PathDisplay.display(session.cwd, isLocal: session.isLocal))
                .litterMeta()
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isActive {
                Text("working")
                    .litterMeta()
                    .fixedSize()
            }
        }
        .padding(.top, LitterSpace.s)
    }

    // MARK: - Zoom 3+: tool call log

    @ViewBuilder
    private func toolLog(maxEntries: Int) -> some View {
        // Rust-side `recent_tool_log` (see `extract_conversation_activity`
        // in shared/rust-bridge/.../boundary.rs) already derives this; the
        // iOS copy that used to live here was the dominant AttributeGraph
        // subscription during streaming. Entries come through newest-last;
        // take the tail to show the most recent `maxEntries`.
        let entries = Array(session.recentToolLog.suffix(maxEntries))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    toolRowView(entry)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func toolRowView(_ entry: AppToolLogEntry) -> some View {
        HStack(spacing: 8) {
            toolIconView(for: entry.tool)
                .foregroundStyle(LitterTheme.meta)
                .frame(minWidth: 20, alignment: .leading)
                .accessibilityHidden(true)
            Text(formatToolDetail(entry))
                .foregroundStyle(LitterTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // Keep tool activity smaller than the assistant response preview so
        // the response remains the primary content on the card.
        .litterFont(size: toolLogFontSize)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Render the tool detail text. For `Edit` we use the same
    /// `workspaceTitle(for:)` helper the conversation timeline uses for
    /// FileChange items — gives `Edited MainActivity.kt` rather than
    /// the full absolute path, which is unreadable in a 390 px row.
    private func formatToolDetail(_ entry: AppToolLogEntry) -> String {
        switch entry.tool {
        case "Edit":
            return "Edited \(workspaceTitle(for: entry.detail))"
        default:
            return entry.detail
        }
    }

    /// Pick the display glyph/icon for a Rust tool-log entry. `AppToolLogEntry.tool`
    /// is a short category name the reducer emits (`"Bash"`, `"Edit"`, `"MCP"`,
    /// `"Tool"`, `"Explore"`, `"WebSearch"`). MCP and generic tools read better
    /// as SF Symbols than as abbreviated text; the rest render as a single
    /// character.
    @ViewBuilder
    private func toolIconView(for tool: String) -> some View {
        switch tool {
        case "MCP":
            Image(systemName: "desktopcomputer")
                .litterFont(size: toolLogFontSize - 1, weight: .semibold)
        case "Tool":
            Image(systemName: "wrench.and.screwdriver")
                .litterFont(size: toolLogFontSize - 1, weight: .semibold)
        case "Bash":
            Text("$").litterFont(size: toolLogFontSize - 1, weight: .semibold)
        case "Edit":
            Text("✎").litterFont(size: toolLogFontSize - 1, weight: .semibold)
        case "Explore", "WebSearch":
            // Use an SF Symbol to match the size/weight of the other
            // Image-based icons (MCP/Tool); the "⌕" glyph renders
            // larger than `$` / `✎` at the same point size because
            // Unicode metrics for that character put the visual mass
            // over a bigger box.
            Image(systemName: "magnifyingglass")
                .litterFont(size: toolLogFontSize - 1, weight: .semibold)
        default:
            Text(tool.prefix(1).uppercased())
                .litterFont(size: toolLogFontSize - 1, weight: .semibold)
        }
    }

    // MARK: - Zoom 4: last response preview

    @ViewBuilder
    private var responsePreview: some View {
        // Source the preview from `session.lastResponsePreview` rather than
        // walking `hydratedConversationItems` live. The Rust reducer
        // refreshes the session summary on every item delta, but the home
        // dashboard's observation path is debounced at 120ms in
        // `HomeDashboardModel.scheduleObservedRefresh` — so the preview
        // naturally updates at ~8Hz instead of forcing `LitterMarkdownView`
        // to re-parse markdown on every streaming token (30–60Hz). The old
        // live-walk path made the streaming card the dominant frame-time
        // cost after all the other scroll fixes landed.
        //
        // Crossfade key is the `source_turn_id` of the assistant message
        // that produced `lastResponsePreview`. Keying on `stats.turnCount`
        // would flip the id the moment the user submits a new prompt —
        // before any new assistant text exists — so the preview would
        // fade out (and back in with the same previous text) on every
        // send. Using the assistant's turn id keeps the old answer
        // visible until a new assistant reply actually arrives.
        let markdown = (session.lastResponsePreview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let blockId = session.lastResponseTurnId ?? "empty"
        if markdown.count > 20 {
            // ViewThatFits picks the first child whose natural size fits
            // the proposed container. The container is capped at
            // `responsePreviewMaxHeight`, so:
            //   - Short markdown (natural ≤ cap): the fixed-size rendering
            //     wins, frame shrinks to natural height → no blank space.
            //   - Long markdown (natural > cap): the first child is too
            //     tall, so ViewThatFits falls through to the scroll-based
            //     fallback — scroll is disabled but `defaultScrollAnchor(.bottom)`
            //     keeps the tail visible, and the frame stays at cap.
            // This pattern is the clean SwiftUI answer for "shrink to
            // content OR cap-with-tail-visible"; the earlier
            // `fixedSize + frame(maxHeight:, alignment: .bottom)` combo
            LitterMarkdownView(
                markdown: markdown,
                selectionEnabled: false
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(blockId)
            // Top-alignment so long markdown clips at the bottom
            // (where the fade mask hides the cut) rather than
            // center-clipping and revealing the middle. Replaces the
            // prior `ViewThatFits` + disabled-ScrollView pair.
            .frame(maxHeight: responsePreviewMaxHeight, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black.opacity(0.55), location: 0),
                        .init(color: .black.opacity(0.85), location: 0.10),
                        .init(color: .black, location: 0.22)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.top, 4)
        }
    }

    /// Height cap for the response preview. Zoom 3 keeps it tight
    /// (25% of screen) so rows stay scan-able in a dense list. Zoom 4
    /// is uncapped — the full assistant reply renders at its natural
    /// height so the user can actually read it.
    private var responsePreviewMaxHeight: CGFloat {
        if zoomLevel >= 4 { return .infinity }
        let screenHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? 800
        return screenHeight * 0.25
    }


    // MARK: - Fork lineage affordances

    /// Compact rune that trails the title at every zoom level. Single chip,
    /// single number — `2/3` reads as "branch 2 of 3 in this lineage".
    @ViewBuilder
    private func forkRune(lineage: ThreadLineage) -> some View {
        Text("\(lineage.branchIndex)/\(lineage.branchTotal)")
            .litterMeta()
            .fixedSize()
            .accessibilityLabel("Branch \(lineage.branchIndex) of \(lineage.branchTotal)")
    }

    /// Inline meta-line replacement for the old `fork` warning text. Carries
    /// the same numeric info as the rune but reads as a chip in line with
    /// the server/model spans at zoom 2+.
    @ViewBuilder
    private func branchChip(lineage: ThreadLineage) -> some View {
        Text("branch \(lineage.branchIndex)/\(lineage.branchTotal)")
    }

    /// Zoom-4 lineage breadcrumb. Renders ancestors root → ... → parent so
    /// the user knows where in the fork tree they are. Self is rendered as
    /// the title beneath, so we don't repeat it here.
    @ViewBuilder
    private var lineageBreadcrumb: some View {
        if let lineage = session.lineage, !lineage.ancestors.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(lineage.ancestors.enumerated()), id: \.offset) { idx, ancestor in
                    if idx > 0 {
                        Text(" › ")
                            .foregroundStyle(LitterTheme.textMuted.opacity(0.55))
                    }
                    Text(ancestor.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(LitterTheme.textMuted.opacity(0.85))
                }
                Text(" ›")
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.55))
                Spacer(minLength: 0)
            }
            .litterMeta()
            .padding(.bottom, LitterSpace.xs)
        }
    }

    /// Zoom-4 sibling pills. Each pill is a branch in the lineage; the one
    /// matching `session.key` is highlighted. The pills double as branch
    /// pickers when wired up by the host.
    @ViewBuilder
    private var siblingPillsRow: some View {
        if let lineage = session.lineage, lineage.hasMultipleBranches {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LitterSpace.m) {
                    ForEach(lineage.members, id: \.key) { member in
                        siblingPill(member: member, isCurrent: member.key == session.key)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func siblingPill(member: ThreadLineageMember, isCurrent: Bool) -> some View {
        Text(member.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .litterMeta(isCurrent ? LitterTheme.textPrimary : LitterTheme.meta)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Canvas Animation Components

/// Stopwatch chip rendered at the right of the modelBadgeLine. When
/// `end` is nil the turn is live and a `TimelineView` drives a 1 Hz
/// re-eval. When `end` is provided, the chip is static and shows the
/// calculated turn duration (`end - start`) — no in-memory freeze.
private struct TurnStopwatchChip: View {
    let start: Date
    let end: Date?

    var body: some View {
        if let end {
            chip(seconds: max(0, end.timeIntervalSince(start)))
        } else {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                chip(seconds: max(0, context.date.timeIntervalSince(start)))
            }
        }
    }

    @ViewBuilder
    private func chip(seconds: TimeInterval) -> some View {
        HStack(spacing: 0) {
            // Monospaced digits so "14s" and "15s" have the same width.
            // Without this, each tick changes the chip's intrinsic size,
            // which cascades into list row re-measure → RootGeometry
            // invalidation on every active card every second. Mono
            // digits freeze that width so the chip can update in-place.
            RollingMetricText(Self.format(seconds))
        }
        .foregroundStyle(LitterTheme.meta)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        let secs = total % 60
        return secs == 0 ? "\(mins)m" : "\(mins)m\(secs)s"
    }
}

/// Renders the task title at the same size the conversation view uses for
/// message bodies (`LitterFont.conversationBodyPointSize × textScale`) so
/// titles and user/assistant messages in the home list match the sizes you
/// see inside a conversation. Kept medium-weight (rather than bold) so the
/// title reads as a row heading without visually dominating the response.
private struct MarkdownMatchedTitleFont: ViewModifier {
    @Environment(\.textScale) private var textScale
    func body(content: Content) -> some View {
        content
            .litterFont(
                size: LitterFont.conversationBodyPointSize,
                weight: .regular
            )
    }
}

/// Collapses a view to zero size + zero opacity when hidden, keeping
/// it in the tree (layout still runs). Used on zoom-gated card layers
/// so zoom transitions animate a frame-height interpolation rather
/// than materializing a new subtree.
///
/// When visible we use `maxHeight: nil` (natural sizing). Using
/// `.infinity` here causes every visible layer to compete for leftover
/// space inside a fixed-height container — at zoom 4 the card is sized
/// to a full screen page, so the layers spread apart and create gaps
/// between sections. With `nil`, layers stay tight against each other
/// and any leftover space falls below the last visible layer instead.
extension View {
    func visibleWhen(_ visible: Bool) -> some View {
        self
            .frame(maxHeight: visible ? nil : 0, alignment: .top)
            .opacity(visible ? 1 : 0)
            .clipped()
            .allowsHitTesting(visible)
    }
}
