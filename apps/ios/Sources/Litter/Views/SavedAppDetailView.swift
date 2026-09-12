import SwiftUI

/// Fullscreen host for a single saved app. Loads the widget HTML + persisted
/// state from Rust on appear, renders through `WidgetWebView` in app-mode so
/// the `loadAppState` / `saveAppState` JS bridge is wired. State saves flow
/// through the onMessage handler into `SavedAppsStore.saveState`, which
/// debounces the write.
struct SavedAppDetailView: View {
    let appId: String

    @Environment(\.dismiss) private var dismiss
    @State private var store = SavedAppsStore.shared
    @State private var payload: SavedAppWithPayload?
    @State private var loadAttempted = false
    @State private var renameText: String = ""
    @State private var showRenameSheet = false
    @State private var showUpdateOverlay = false
    @State private var isUpdating = false
    @State private var updateError: String?
    @State private var updateSuccessMessage: String?
    @State private var reloadTick = 0
    @State private var pollingTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false
    /// In-memory ephemeral thread id for this saved-app view. Rust owns
    /// the thread; we just cache the id so consecutive `structuredResponse`
    /// calls in this view reuse the same hidden thread. Dies with the
    /// view — that's the whole point (Option B in the plan).
    @State private var cachedStructuredThreadId: String?
    /// Whether this app's origin thread still exists, mirrored out of
    /// `AppModel.shared.snapshot` by `snapshotObserver`. The old
    /// `threadExists(_:)` scanned `snapshot.threads` from `body` (via
    /// `topBar(for:)`), which re-rendered — and re-scanned — at the ~8 fps
    /// streaming snapshot cadence.
    @State private var originThreadExists = false
    @State private var snapshotObserver = AppSnapshotObserver()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let payload {
                ZStack {
                    WidgetWebView(
                        widgetHTML: payload.widgetHtml,
                        isFinalized: true,
                        allowsScrollAndZoom: true,
                        onMessage: handleMessage,
                        onStructuredRequest: handleStructuredRequest,
                        appMode: true,
                        initialAppState: payload.stateJson,
                        schemaVersion: Int(payload.app.schemaVersion)
                    )
                    .id("\(appId)-\(reloadTick)")
                    // Keep the initial content below the floating header
                    // buttons so they don't overlap on load. Users can
                    // still scroll content up under them — only the
                    // initial anchor respects the bar.
                    .safeAreaPadding(.top, 54)
                    .ignoresSafeArea(edges: [.bottom, .horizontal])

                    if isUpdating {
                        shimmerOverlay
                    }
                }

                topBar(for: payload.app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if loadAttempted {
                brokenAppPlaceholder
            } else {
                ProgressView()
                    .tint(LitterTheme.accent)
            }

            if showUpdateOverlay {
                SavedAppUpdateOverlay(
                    isUpdating: $isUpdating,
                    errorMessage: $updateError,
                    onSubmit: { prompt in
                        Task { await runUpdate(prompt: prompt) }
                    },
                    onDismiss: {
                        showUpdateOverlay = false
                        updateError = nil
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let message = updateSuccessMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .litterFont(.footnote, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(LitterTheme.surfaceLight.opacity(0.9))
                        .clipShape(Capsule())
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear(perform: reloadPayload)
        .task {
            // Keeps the "View Conversation" affordance honest: the observer
            // re-runs the lookup on every (coalesced) snapshot revision, so a
            // thread appearing/disappearing while this view is open still
            // shows/hides the button.
            snapshotObserver.start(appModel: AppModel.shared) { refreshOriginThreadExists() }
        }
        .onChange(of: payload?.app.originThreadId) { _, _ in
            refreshOriginThreadExists()
        }
        .onDisappear {
            snapshotObserver.stop()
            pollingTask?.cancel()
            pollingTask = nil
        }
        .onChange(of: isUpdating) { _, updating in
            if updating {
                startPollingForUpdate()
            } else {
                pollingTask?.cancel()
                pollingTask = nil
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
                .presentationDetents([.medium])
        }
        .alert(
            "Delete \"\(payload?.app.title ?? "")\"?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? store.delete(id: appId)
                dismiss()
            }
        } message: {
            Text("This removes the app, its saved HTML, and its persisted state.")
        }
    }

    /// While a saved-app update is in flight, poll the on-disk HTML
    /// every 500ms. When the model-driven `apply_patch` lands a new
    /// version, reassign `payload` so `WidgetWebView` picks up the
    /// change through its existing morphdom debouncer. The final
    /// reassign after the RPC completes is handled by `reloadPayload`
    /// in `runUpdate`.
    private func startPollingForUpdate() {
        pollingTask?.cancel()
        let id = appId
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                guard let fresh = store.getWithPayload(id: id) else { continue }
                if fresh.widgetHtml != payload?.widgetHtml {
                    payload = fresh
                }
            }
        }
    }

    private func topBar(for app: SavedApp) -> some View {
        GlassMorphContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .litterFont(size: 17, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(GlassCircleModifier())
                .accessibilityLabel("Back")

                Button {
                    renameText = app.title
                    showRenameSheet = true
                } label: {
                    Text(app.title)
                        .litterFont(.headline, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(GlassCapsuleModifier(interactive: true))

                Spacer(minLength: 0)

                Menu {
                    Button {
                        renameText = app.title
                        showRenameSheet = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .litterFont(size: 17, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .modifier(GlassCircleModifier())
                .accessibilityLabel("App options")

                if let threadId = app.originThreadId, originThreadExists {
                    Button {
                        SavedAppsNavigation.shared.requestConversation(threadId: threadId)
                        dismiss()
                    } label: {
                        Image(systemName: "text.bubble.fill")
                            .litterFont(size: 15, weight: .semibold)
                            .foregroundColor(LitterTheme.textPrimary)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .modifier(GlassCircleModifier())
                    .accessibilityLabel("View Conversation")
                }

                Button {
                    showUpdateOverlay = true
                    updateError = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .litterFont(size: 12, weight: .semibold)
                        Text("Update")
                            .litterFont(size: 13, weight: .semibold)
                    }
                    .foregroundColor(LitterTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(GlassCapsuleModifier(interactive: true))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(LitterTheme.accent.opacity(0.45), lineWidth: 0.8)
                        .allowsHitTesting(false)
                )
                .disabled(isUpdating)
                .opacity(isUpdating ? 0.6 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Called from `snapshotObserver` and on payload changes — never from
    /// `body`. Writes `@State` only on a real change.
    private func refreshOriginThreadExists() {
        let exists: Bool
        if let threadId = payload?.app.originThreadId,
           let threads = AppModel.shared.snapshot?.threads {
            exists = threads.contains(where: { $0.key.threadId == threadId })
        } else {
            exists = false
        }
        if originThreadExists != exists {
            originThreadExists = exists
        }
    }

    private var shimmerOverlay: some View {
        // Subtle dim + shimmer over the running widget while the update is in
        // flight. The widget itself stays interactive; the shimmer is purely
        // a visual hint that a regeneration is happening in the background.
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            ShimmerStrip()
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .padding(.top, 0)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    private var brokenAppPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .litterFont(.largeTitle)
                .foregroundColor(LitterTheme.warning)
            Text("This app's files are missing")
                .litterFont(.title3, weight: .semibold)
                .foregroundColor(.white)
            Text("Delete it to clear the entry.")
                .litterFont(.footnote)
                .foregroundColor(.white.opacity(0.7))

            Button(role: .destructive) {
                try? store.delete(id: appId)
                dismiss()
            } label: {
                Text("Delete App")
                    .litterFont(.body, weight: .semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(LitterTheme.danger.opacity(0.2))
                    .clipShape(Capsule())
                    .foregroundColor(LitterTheme.danger)
            }
        }
        .padding(32)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename App")
                .litterFont(.title3, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)

            TextField("Title", text: $renameText)
                .litterFont(size: 15)
                .padding(10)
                .background(LitterTheme.surfaceLight.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundColor(LitterTheme.textPrimary)

            HStack {
                Button("Cancel") { showRenameSheet = false }
                    .foregroundColor(LitterTheme.textSecondary)
                Spacer()
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { showRenameSheet = false; return }
                    _ = try? store.rename(id: appId, title: trimmed)
                    showRenameSheet = false
                    reloadPayload()
                }
                .foregroundColor(LitterTheme.accent)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
        .padding(20)
        .background(LitterTheme.surface.ignoresSafeArea())
    }

    // MARK: - Actions

    private func reloadPayload() {
        payload = store.getWithPayload(id: appId)
        loadAttempted = true
        reloadTick &+= 1
    }

    private func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["_type"] as? String else { return }
        switch type {
        case "saveAppState":
            guard let value = dict["value"] as? String else { return }
            let schema = (dict["schema"] as? Int).map(UInt32.init) ?? (payload?.app.schemaVersion ?? 1)
            store.saveState(id: appId, stateJson: value, schemaVersion: schema)
        default:
            break
        }
    }

    private func handleStructuredRequest(
        requestId: String,
        prompt: String,
        responseFormatJSON: String,
        respond: @escaping (String, String?, String?) -> Void
    ) {
        guard let serverId = SavedAppDetailView.resolveActiveServerId() else {
            respond(requestId, nil, "No connected server available")
            return
        }
        let cached = cachedStructuredThreadId
        Task.detached {
            let result = await AppModel.shared.client.structuredResponse(
                serverId: serverId,
                cachedThreadId: cached,
                prompt: prompt,
                outputSchemaJson: responseFormatJSON
            )
            switch result {
            case .success(let threadId, let responseJson):
                await MainActor.run {
                    cachedStructuredThreadId = threadId
                }
                respond(requestId, responseJson, nil)
            case .error(let message):
                respond(requestId, nil, message)
            }
        }
    }

    private func runUpdate(prompt: String) async {
        guard let serverId = SavedAppDetailView.resolveActiveServerId() else {
            updateError = "No connected server available"
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        do {
            _ = try await store.requestUpdate(id: appId, serverId: serverId, prompt: prompt)
            showUpdateOverlay = false
            updateError = nil
            reloadPayload()
            withAnimation { updateSuccessMessage = "Updated" }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { updateSuccessMessage = nil }
            }
        } catch {
            updateError = error.localizedDescription
        }
    }

    @MainActor
    private static func resolveActiveServerId() -> String? {
        let snapshot = AppModel.shared.snapshot
        // Prefer the active thread's server; fall back to any known server
        // id. If nothing is connected, the update will fail loudly in the
        // overlay.
        if let serverId = snapshot?.activeThread?.serverId { return serverId }
        return snapshot?.servers.first?.serverId
    }
}

/// Thin animated shimmer strip used at the top of the widget during an
/// in-flight update. Repeats a gradient wipe indefinitely; the parent
/// decides when to show/hide it.
private struct ShimmerStrip: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    LitterTheme.accent.opacity(0.0),
                    LitterTheme.accent.opacity(0.9),
                    LitterTheme.accent.opacity(0.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width)
            .offset(x: phase * geo.size.width)
            .onAppear {
                withAnimation(
                    .linear(duration: 1.2).repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
        }
    }
}
