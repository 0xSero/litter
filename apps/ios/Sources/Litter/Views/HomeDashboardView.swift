import SwiftUI
import UIKit
import os

/// Which chrome layer the dashboard renders with.
///
///  - `.full`: the app's landing page — animated logo in the principal
///    toolbar item, zoom toggle, and the full `HomeBottomBar` composer
///    docked along the bottom. This is what iPhone compact and Catalyst
///    non-split use today.
///  - `.sidebar`: the trimmed projection used in the iPad / Catalyst
///    `NavigationSplitView` sidebar. Branding, zoom, and the bottom
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
    let onPinThread: (ThreadKey) -> Void
    let onUnpinThread: (ThreadKey) -> Void
    let onHideThread: (ThreadKey) -> Void
    /// Sidebar-only: fired when the user taps the "+" in the toolbar.
    var onNewThread: (() -> Void)? = nil
    /// Resume a single thread so the connection has a live listener. Dashboard
    /// orchestrates the parallel calls and tracks per-row state so the left
    /// indicator can reflect it.
    var onHydrateThread: ((ThreadKey, Bool) async -> Void)? = nil
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
    @AppStorage("homeZoomLevel") private var zoomLevel = 2

    /// Bounded ease for zoom level transitions. `.easeInOut` completes
    /// deterministically in `duration` (unlike `.smooth` which is a
    /// spring that can overshoot its nominal time). Short enough to
    /// feel responsive, long enough to see the height change.
    static let zoomAnimation: Animation = .easeInOut(duration: 0.22)

    /// Direction of the toolbar zoom toggle: +1 walks up, -1 walks down.
    /// Flips at the 1/4 boundaries so the button bounces 1→2→3→4→3→2→1.
    @State private var zoomDirection: Int = 1
    @State private var renameServerTarget: HomeDashboardServer?
    @State private var renameServerText = ""
    @State private var isShowingMountedFolders = false
    @State private var inputMode: HomeInputMode = .collapsed
    @State private var searchQuery = ""
    @State private var selectedSearchRuntimeKind: AgentRuntimeKind?
    @State private var hydratingKeys: Set<String> = []
    @State private var isLoadingThreadListing = false
    @State private var suppressComposerCollapse = false

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

    private func autoHydrateIfNeeded() {
        guard let onHydrateThread else { return }
        // Gate on the explicit resumed bit rather than hydrated stats. With
        // paginated threads, loaded items and attached live listeners are now
        // separate states.
        let visible = visibleSessions
        let byPinnedKey = Dictionary(uniqueKeysWithValues: visible.map {
            (SavedThreadsStore.PinnedKey(threadKey: $0.key), $0)
        })
        let pinnedFirst = pinnedThreadKeys.compactMap { byPinnedKey[$0] }
        for session in pinnedFirst where !session.isResumed {
            let id = hydrationId(session.key)
            guard !hydratingKeys.contains(id) else { continue }
            hydratingKeys.insert(id)
            Task {
                await onHydrateThread(session.key, true)
                await MainActor.run {
                    _ = hydratingKeys.remove(id)
                }
            }
        }
    }

    private var visibleSessions: [HomeDashboardRecentSession] {
        let serverId = selectedMachineServerId
        guard let serverId, !serverId.isEmpty else { return recentSessions }
        return recentSessions.filter { $0.serverId == serverId }
    }

    private var zoomIcon: String {
        switch zoomLevel {
        case 1: return "list.bullet"
        case 2: return "list.dash"
        case 3: return "list.bullet.rectangle"
        default: return "list.bullet.rectangle.fill"
        }
    }

    var body: some View {
        canvas
            .onAppear { onInputModeChange?(inputMode) }
            .onChange(of: inputMode) { _, nextMode in
                onInputModeChange?(nextMode)
                if nextMode != .search {
                    selectedSearchRuntimeKind = nil
                }
            }
            .task { await TipJarStore.shared.loadProducts() }
            .onAppear { autoHydrateIfNeeded() }
            .onChange(of: visibleSessions.map { hydrationId($0.key) }) { _, _ in
                autoHydrateIfNeeded()
            }
            .onChange(of: pinnedThreadKeys) { _, _ in
                autoHydrateIfNeeded()
            }
            // Clear a cancelled key once the snapshot says the turn is
            // actually gone. Gives the dot a brief red period while the
            // cancel is in flight, then reverts to normal indicator logic.
            .onChange(of: visibleSessions.map { "\(hydrationId($0.key)):\($0.hasTurnActive)" }) { _, _ in
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                Button(action: onShowSettings) {
                    Image(systemName: "gearshape")
                        .foregroundColor(LitterTheme.textSecondary)
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.settingsButton")
                if let onShowApps {
                    Button(action: onShowApps) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .accessibilityLabel("Apps")
                }
                if let onShowTerminal {
                    Button(action: onShowTerminal) {
                        Image(systemName: "terminal")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .accessibilityLabel("Terminal")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            if chrome == .sidebar {
                AnimatedLogo(size: 44)
            } else {
                HStack(spacing: 4) {
                    SupporterKittyBadges(tierIndices: 0..<2)
                    AnimatedLogo(size: 64)
                    SupporterKittyBadges(tierIndices: 2..<4)
                }
            }
        }
        if chrome == .full {
            ToolbarItem(placement: .topBarTrailing) {
                zoomButton
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onNewThread?()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(LitterTheme.accent)
                }
                .accessibilityLabel("New thread")
            }
        }
    }

    private var zoomButton: some View {
        Button {
            // Four levels: 1 SCAN → 2 GLANCE → 3 READ → 4 DEEP.
            // Bounce through them: 1→2→3→4→3→2→1.
            let ladder = [1, 2, 3, 4]
            let currentIdx = ladder.firstIndex(of: zoomLevel) ?? 0
            var nextIdx = currentIdx + zoomDirection
            if nextIdx >= ladder.count {
                zoomDirection = -1
                nextIdx = currentIdx + zoomDirection
            } else if nextIdx < 0 {
                zoomDirection = 1
                nextIdx = currentIdx + zoomDirection
            }
            withAnimation(Self.zoomAnimation) {
                zoomLevel = ladder[max(0, min(ladder.count - 1, nextIdx))]
            }
        } label: {
            Image(systemName: zoomIcon)
                .foregroundColor(LitterTheme.textSecondary)
        }
        .accessibilityLabel("Zoom")
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
                emptyHomeFatCat
                    .transition(.opacity)
            }
        }
        .overlayPreferenceValue(CoachmarkAnchorKey.self) { anchors in
            if showOnboardingCoachmarks {
                OnboardingCoachmarksView(anchors: anchors)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showOnboardingCoachmarks)
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
        .frame(maxWidth: .infinity)
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

    private var bottomChrome: some View {
        VStack(alignment: .trailing, spacing: 6) {
            DebugBuildLabel()
                .padding(.trailing, 14)
            if inputMode == .composer {
                HStack(spacing: 8) {
                    Spacer()
                    HomeModelChip(
                        serverId: composerServerId,
                        disabled: selectedLaunchableServer == nil,
                        onSheetStateChange: { isPresented in
                            suppressComposerCollapse = isPresented
                        }
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
                onThreadCreated: onThreadCreated
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
        // UIKit-backed scroll view owns pinch, pan, and row swipes
        // directly. Previously SwiftUI's `ScrollView` + `MagnifyGesture`
        // both consumed the same pan deltas, producing vertical jitter
        // during a pinch even with `.scrollDisabled(isPinching)`. The
        // UIKit host uses the Clear.app pattern: pinch anchored on the
        // finger midpoint in content coordinates + frame-only height
        // animation per row (SwiftUI does zero per-tick work during a
        // pinch).
        ZStack {
            if visibleSessions.isEmpty {
                ScrollView { emptyState.padding(.top, 48).padding(.bottom, 140) }
                    .scrollContentBackground(.hidden)
            } else {
                HomeSessionsScrollView(
                    sessions: visibleSessions,
                    pinnedThreadKeys: Set(pinnedThreadKeys),
                    hydratingKeys: hydratingKeys,
                    cancellingKeys: cancellingKeys,
                    openingKey: openingRecentSessionKey,
                    zoomLevel: $zoomLevel,
                    showCatFooter: chrome == .full,
                    topInset: 48,
                    bottomInset: chrome == .full ? 140 : 24,
                    callbacks: HomeSessionsScrollView.Callbacks(
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
                    )
                )
                // Extend the scroll view edge-to-edge so content can
                // scroll under the semi-transparent top/bottom chrome.
                // The `topInset`/`bottomInset` we pass already carve
                // out safe resting space for the rows.
                .ignoresSafeArea()
            }
        }
    }

    /// The "no sessions yet" copy has been replaced by the coachmark
    /// overlay (mounted on `canvas` via `.overlayPreferenceValue`), which
    /// draws arrows from each label to the actual button positions. This
    /// branch just reserves vertical space for the scroll view.
    private var emptyState: some View {
        Color.clear.frame(height: 1)
    }

    /// Fat cat illustration shown on the empty home screen. Positioned in
    /// the middle vertical band — between the addServer label (y≈0.20) and
    /// the search/newThread labels (y≈0.62/0.70) — so it never collides
    /// with the coachmark arrows or labels. Plays the entrance APNG once
    /// then crossfades to the looping APNG, matching the cat footer.
    private var emptyHomeFatCat: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let w = proxy.size.width
            let catWidth = min(max(180, w * 0.55), 260)
            let catHeight = catWidth * 202.0 / 360.0
            EmptyHomeFatCatView()
                .frame(width: catWidth, height: catHeight)
                .position(x: w / 2, y: h * 0.42)
        }
    }
}

private struct EmptyHomeFatCatView: View {
    @State private var showingLoop = false

    private let entranceURL = Bundle.main.url(forResource: "home_cat_entrance", withExtension: "webp")
    private let loopURL = Bundle.main.url(forResource: "home_cat", withExtension: "webp")

    var body: some View {
        CatTransmissionPressView {
            if let imageURL = showingLoop ? loopURL : (entranceURL ?? loopURL) {
                AlphaAnimatedImageView(
                    fileURL: imageURL,
                    repeatCount: showingLoop ? 0 : 1,
                    onFinished: showingLoop ? nil : { showingLoop = true }
                )
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Session Canvas Layout

private enum SessionCanvasLayout {
    static let horizontalPadding: CGFloat = 14
    static let markerWidth: CGFloat = 14
    static let markerSpacing: CGFloat = 8
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
        let anchors: [CGFloat] = [3, 6, 10, 12]
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
        max(12, LitterFont.conversationBodyPointSize - 3)
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
        #if DEBUG
        // PERF-0a HomeCard proxy: SessionCanvasLine is instantiated once per
        // session by HomeSessionRowContent (HomeSessionsScrollView.swift, out of
        // scope). Caveats: (a) undercounts outer-chrome-only re-evals;
        // (b) PiPContentView also instantiates it — PERF-0b must keep PiP off.
        let _ = RenderIsolationCounters.trace(RenderIsolationCounters.Site.homeCard)
        #endif
        HStack(alignment: .top, spacing: 0) {
            Group {
                if isOpening {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(LitterTheme.accent)
                } else {
                    statusIndicator
                }
            }
            .frame(width: SessionCanvasLayout.markerWidth, height: 16)
            .padding(.trailing, SessionCanvasLayout.markerSpacing)
            .padding(.top, 2)

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
                        .foregroundStyle(isActive ? LitterTheme.accent : LitterTheme.textPrimary)
                        .modifier(SessionShimmerEffect(active: isActive))
                        .fixedSize(horizontal: false, vertical: true)
                    if let lineage = session.lineage, lineage.hasMultipleBranches {
                        forkRune(lineage: lineage)
                    }
                    Spacer(minLength: 6)
                    if zoomLevel == 1 {
                        Text(timeAgo)
                            .litterFont(size: 10, weight: .regular)
                            .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
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
        .background(alignment: .leading) {
            if isActive {
                LitterTheme.accent.opacity(0.3).frame(width: 2)
            }
        }
        .background(isActive ? LitterTheme.accent.opacity(0.02) : Color.clear)
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
        .animation(.easeInOut(duration: 0.25), value: isActive)
        .accessibilityIdentifier("home.recentSessionCard")
    }

    // MARK: - Zoom 2: meta line

    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(timeAgo)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
            // Only show the tool label + pulsing dots when a tool call
            // is actually executing. During pure LLM thinking/streaming
            // we fall through to the server + workspace metadata, same
            // as when the turn is idle.
            if isActive && isToolCallRunning {
                Text("\u{00b7}")
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                toolActivityLabel
                SessionPulsingDots()
                statChips
            } else {
                Text("\u{00b7}")
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                Text(session.serverDisplayName)
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.7))
                if let workspace = HomeDashboardSupport.workspaceLabel(for: session.cwd) {
                    Text("\u{00b7}")
                        .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                    Text(workspace)
                        .foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
                }
                statChips
            }
        }
        .litterFont(size: 10, weight: .regular)
        .lineLimit(1)
        .padding(.top, 2)
    }

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

    private var modelBadgeLine: some View {
        HStack(spacing: 4) {
            Text(timeAgo)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
            Text("\u{00b7}")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
            Image(systemName: "server.rack")
                .litterFont(size: 8)
                .foregroundStyle(LitterTheme.accent.opacity(0.5))
            Text(session.serverDisplayName)
                .foregroundStyle(LitterTheme.accent.opacity(0.6))
            let m = session.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty {
                Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                HomeRuntimeIcon(kind: session.agentRuntimeKind)
                Text(m)
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.7))
            }
            if let lineage = session.lineage, lineage.hasMultipleBranches {
                Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                branchChip(lineage: lineage)
            } else if session.isFork {
                Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                Text("fork")
                    .foregroundStyle(LitterTheme.warning.opacity(0.8))
            }
            if session.isSubagent, let agent = session.agentLabel {
                Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                Text(agent)
                    .foregroundStyle(LitterTheme.accent.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .litterFont(size: 10, weight: .regular)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, 1)
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
            HStack(spacing: 12) {
                if turnCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.turn.down.right")
                            .litterFont(size: 8)
                        RollingMetricText("\(turnCount)")
                    }
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
                }
                if toolCallCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .litterFont(size: 8)
                        RollingMetricText("\(toolCallCount)")
                    }
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
                }
                if let stats, hasDiff {
                    HStack(spacing: 5) {
                        RollingMetricText("+\(stats.diffAdditions)")
                            .foregroundStyle(LitterTheme.accent.opacity(0.75))
                        RollingMetricText("-\(stats.diffDeletions)")
                            .foregroundStyle(LitterTheme.danger.opacity(0.65))
                    }
                }
                if let start = session.lastTurnStart {
                    TurnStopwatchChip(start: start, end: session.lastTurnEnd)
                }
                if let tu = session.tokenUsage, let window = tu.contextWindow, window > 0 {
                    let pct = Int((Double(tu.totalTokens) / Double(window)) * 100)
                    RollingMetricText("\(pct)%")
                        .foregroundStyle(pct > 80 ? LitterTheme.warning.opacity(0.85) : LitterTheme.textMuted.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .litterFont(size: 10, weight: .regular)
            .padding(.top, 4)
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
                        Rectangle()
                            .fill(LitterTheme.border.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.vertical, 8)
                    }
                }
                if hasMetrics {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 14) {
                            statCell(icon: "chevron.left.forwardslash.chevron.right",
                                     value: files > 0 ? "\(files)" : nil,
                                     valueColor: LitterTheme.textPrimary,
                                     label: "files")
                            statCell(icon: nil,
                                     valuePrefix: nil,
                                     value: pct.map { "\($0)%" },
                                     valueColor: (pct ?? 0) > 80 ? LitterTheme.warning : LitterTheme.warning.opacity(0.85),
                                     label: "context")
                        }
                        HStack(alignment: .top, spacing: 14) {
                            statCell(icon: nil,
                                     value: adds > 0 ? "+\(adds.formatted(.number.grouping(.automatic)))" : nil,
                                     valueColor: LitterTheme.accent,
                                     label: "added")
                            statCell(icon: "snowflake",
                                     value: totalTokens.map { Self.formatTokens($0) },
                                     valueColor: LitterTheme.textPrimary,
                                     label: "tok")
                        }
                        HStack(alignment: .top, spacing: 14) {
                            statCell(icon: nil,
                                     value: rems > 0 ? "-\(rems.formatted(.number.grouping(.automatic)))" : nil,
                                     valueColor: LitterTheme.danger.opacity(0.85),
                                     label: "removed")
                            statCell(icon: "clock",
                                     value: durationSeconds.map { Self.formatDuration($0) },
                                     valueColor: LitterTheme.textPrimary,
                                     label: "duration")
                        }
                    }
                }
            }
            .litterFont(size: 12, weight: .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(LitterTheme.border.opacity(0.5))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(LitterTheme.border.opacity(0.5))
                    .frame(height: 0.5)
            }
            .padding(.top, 8)
        }
    }

    /// Goal banner that sits inside the dashboard panel at z4. Shows
    /// the small "GOAL" small-caps label, a status dot tinted by the
    /// goal's lifecycle, and the objective text (allowed to wrap).
    @ViewBuilder
    private func goalBanner(goal: AppThreadGoal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("GOAL")
                    .litterFont(size: 9, weight: .semibold)
                    .tracking(1.2)
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.65))
                Text(goalStatusLabel(goal.status))
                    .litterFont(size: 9, weight: .semibold)
                    .tracking(0.6)
                    .foregroundStyle(goalStatusTint(goal.status).opacity(0.85))
            }
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(goalStatusTint(goal.status))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                Text(goal.objective)
                    .litterFont(size: 12, weight: .regular)
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.95))
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
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.65))
                    .litterFont(size: 11, weight: .regular)
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
                Circle()
                    .fill(goalStatusTint(goal.status))
                    .frame(width: 5, height: 5)
                Text(goal.objective)
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if goal.tokensUsed > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "circle.hexagongrid")
                            .litterFont(size: 8)
                        RollingMetricText(formatGoalTokens(goal.tokensUsed))
                    }
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
                }
                if goal.timeUsedSeconds > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "clock")
                            .litterFont(size: 8)
                        RollingMetricText(formatGoalSeconds(goal.timeUsedSeconds))
                    }
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
                }
            }
            .litterFont(size: 10, weight: .regular)
            .padding(.top, 1)
        }
    }

    private func goalStatusTint(_ status: AppThreadGoalStatus) -> Color {
        switch status {
        case .active: return LitterTheme.accent
        case .paused: return LitterTheme.textMuted
        case .blocked, .usageLimited, .budgetLimited: return LitterTheme.warning
        case .complete: return LitterTheme.success
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
                .foregroundStyle(LitterTheme.textSecondary.opacity(0.95))
                .litterFont(size: LitterFont.conversationBodyPointSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .background(LitterTheme.accent.opacity(0.06))
                .overlay(alignment: .leading) {
                    LitterTheme.accent.opacity(0.55).frame(width: 2)
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                )
                .padding(.top, 6)
        }
    }

    // MARK: - Zoom 4: "Recent activity" section header
    //
    // A small monospace label above the tool log so the icon list is
    // unambiguously "what just happened" rather than blending into the
    // user message preview above or the response preview below.

    @ViewBuilder
    private var activityHeader: some View {
        Text("RECENT ACTIVITY")
            .litterFont(size: 9, weight: .semibold)
            .tracking(1.2)
            .foregroundStyle(LitterTheme.textMuted.opacity(0.65))
            .padding(.top, 10)
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
                .litterFont(size: 10, weight: .regular)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isActive {
                HStack(spacing: 5) {
                    Circle()
                        .fill(LitterTheme.accent)
                        .frame(width: 4, height: 4)
                    Text("Working")
                        .litterFont(size: 9, weight: .semibold)
                        .foregroundStyle(LitterTheme.accent.opacity(0.85))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(
                    Capsule()
                        .stroke(LitterTheme.accent.opacity(0.4), lineWidth: 0.5)
                )
                .clipShape(Capsule())
                .fixedSize()
            }
        }
        .padding(.top, 6)
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
                .foregroundStyle(LitterTheme.accent.opacity(0.6))
                .frame(minWidth: 20, alignment: .leading)
            Text(formatToolDetail(entry))
                .foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
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


    // MARK: - Status Indicator

    private var dotState: StatusDotState {
        if isCancelling { return .error }
        if isActive { return .active }
        if isHydrating { return .pending }
        if session.isResumed { return .ok }
        return .idle
    }

    private var statusIndicator: some View {
        StatusDot(state: dotState)
    }

    // MARK: - Fork lineage affordances

    /// Compact rune that trails the title at every zoom level. Single chip,
    /// single number — `2/3` reads as "branch 2 of 3 in this lineage".
    @ViewBuilder
    private func forkRune(lineage: ThreadLineage) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .litterFont(size: 8, weight: .semibold)
                .foregroundStyle(LitterTheme.textSecondary.opacity(0.85))
            Text("\(lineage.branchIndex)/\(lineage.branchTotal)")
                .litterFont(size: 9, weight: .semibold)
                .foregroundStyle(LitterTheme.accent)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .overlay(
            Capsule()
                .stroke(LitterTheme.border.opacity(0.6), lineWidth: 1)
        )
        .clipShape(Capsule())
        .accessibilityLabel("Branch \(lineage.branchIndex) of \(lineage.branchTotal)")
    }

    /// Inline meta-line replacement for the old `fork` warning text. Carries
    /// the same numeric info as the rune but reads as a chip in line with
    /// the server/model spans at zoom 2+.
    @ViewBuilder
    private func branchChip(lineage: ThreadLineage) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .litterFont(size: 7, weight: .semibold)
            Text("branch \(lineage.branchIndex)/\(lineage.branchTotal)")
        }
        .foregroundStyle(LitterTheme.accent.opacity(0.85))
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
            .litterFont(size: 9, weight: .regular)
            .padding(.bottom, 2)
        }
    }

    /// Zoom-4 sibling pills. Each pill is a branch in the lineage; the one
    /// matching `session.key` is highlighted. The pills double as branch
    /// pickers when wired up by the host.
    @ViewBuilder
    private var siblingPillsRow: some View {
        if let lineage = session.lineage, lineage.hasMultipleBranches {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
        HStack(spacing: 5) {
            Circle()
                .fill(isCurrent ? LitterTheme.accent : LitterTheme.textMuted.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(member.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .litterFont(size: 10, weight: isCurrent ? .semibold : .regular)
        .foregroundStyle(isCurrent ? LitterTheme.accent : LitterTheme.textSecondary.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(isCurrent ? LitterTheme.accent.opacity(0.12) : LitterTheme.surface.opacity(0.6))
        )
        .overlay(
            Capsule()
                .stroke(isCurrent ? LitterTheme.accent.opacity(0.6) : LitterTheme.border.opacity(0.6), lineWidth: 1)
        )
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
        HStack(spacing: 2) {
            Image(systemName: "stopwatch")
                .litterFont(size: 8)
            // Monospaced digits so "14s" and "15s" have the same width.
            // Without this, each tick changes the chip's intrinsic size,
            // which cascades into list row re-measure → RootGeometry
            // invalidation on every active card every second. Mono
            // digits freeze that width so the chip can update in-place.
            RollingMetricText(Self.format(seconds))
        }
        .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        let secs = total % 60
        return secs == 0 ? "\(mins)m" : "\(mins)m\(secs)s"
    }
}

private struct SessionPulsingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(LitterTheme.accent)
                    .frame(width: 3, height: 3)
                    .opacity(phase == i ? 1.0 : 0.25)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.15)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

private struct HomeRuntimeIcon: View {
    let kind: AgentRuntimeKind

    var body: some View {
        AgentIconView(kind: kind, size: 15)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel(kind.displayLabel)
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
                weight: .medium
            )
    }
}

private struct SessionShimmerEffect: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            // `TimelineView(.animation)` drives a time-based phase.
            // Every tick rebuilds the gradient stops — fine here
            // because the overlay is a single SwiftUI.LinearGradient
            // (cheap) and its body eval doesn't cascade upward thanks
            // to `compositingGroup` isolating the blend scope.
            //
            // `.blendMode(.sourceAtop)` + `.compositingGroup()`
            // constrains the white highlight to paint only on the
            // underlying glyphs' opaque pixels — so the shimmer
            // tracks the text shape without needing a mask.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t.truncatingRemainder(dividingBy: 2.0) / 2.0)

                content
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: max(0, phase - 0.2)),
                                .init(color: .white.opacity(0.7), location: phase),
                                .init(color: .white.opacity(0), location: min(1, phase + 0.2))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .blendMode(.sourceAtop)
                    }
                    .compositingGroup()
            }
        } else {
            content
        }
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
