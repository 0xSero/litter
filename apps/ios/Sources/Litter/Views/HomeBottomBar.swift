import SwiftUI

/// Three-state bottom bar for the home screen:
///
///   .collapsed → two large glass buttons (plus + search), right-aligned.
///   .composer  → the home composer, auto-focused; collapses back when the
///                user dismisses the keyboard and the composer is empty.
///   .search    → a focused search field that filters the thread list; the
///                parent renders the results overlay above it.
///
/// All three states share a `GlassMorphContainer` so iOS 26 liquid glass
/// actually blobs from the tapped button into the expanded surface. Older
/// iOS falls back to a matched-geometry frame tween.
enum HomeInputMode: Hashable {
    case collapsed
    case composer
    case search
}

struct HomeBottomBar: View {
    @Binding var mode: HomeInputMode
    @Binding var searchQuery: String
    var collapseSuppressed = false
    let project: AppProject?
    let transcriptionServerId: String?
    let onThreadCreated: (ThreadKey) -> Void
    /// Model pill shown inside the composer's bottom row.
    var modelPill: HomeComposerModelPill? = nil
    /// When `true`, the plus/composer pool is omitted and only the search
    /// button / search-row morph renders. Used by the iPad + Catalyst
    /// sidebar chrome where there's no room (and no use) for a composer.
    var compact: Bool = false
    @FocusState private var searchFocused: Bool
    @State private var composerOpenedAt: Date = .distantPast
    @State private var composerHasBeenActive = false

    @Namespace private var ns

    private let plusID = "bottomPlus"
    private let searchID = "bottomSearch"
    private let buttonSize: CGFloat = 44

    var body: some View {
        // Two isolated glass pools so the + and search buttons don't blob
        // into a single liquid-glass shape. Pool 1 handles plus ↔ composer,
        // pool 2 handles search ↔ searchRow. Without this, `searchRow`
        // expanding leftward from `searchIconButton` visually absorbs the +
        // button's glass — reading as if the + is the one morphing.
        ZStack {
            // Pool 1: plus button ↔ composer row. Omitted in compact mode.
            if !compact {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    GlassMorphContainer(spacing: 14) {
                        switch mode {
                        case .collapsed:
                            plusButton
                        case .composer:
                            composerRow
                        case .search:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: mode == .composer ? .infinity : nil)
                    if mode == .collapsed {
                        // Reserve the search button's slot so the + stays put.
                        Spacer().frame(width: buttonSize + 10 + 14)
                    }
                }
                .padding(.horizontal, mode == .collapsed ? 14 : 0)
            }

            // Pool 2: search button ↔ search row. In full-chrome mode the
            // button sits on the right (sharing the trailing edge with the
            // plus button); in compact/sidebar mode it anchors to the left
            // since there's no plus to coexist with.
            HStack(spacing: 0) {
                if !compact {
                    Spacer(minLength: 0)
                }
                GlassMorphContainer(spacing: 14) {
                    // In compact mode, `.composer` is unreachable via the
                    // bar itself — but the bound `mode` can transiently
                    // hold that value during chrome transitions. Treat it
                    // like `.collapsed` so the search button stays put.
                    if mode == .search {
                        searchRow
                    } else if compact || mode == .collapsed {
                        searchIconButton
                    } else {
                        EmptyView()
                    }
                }
                .frame(maxWidth: mode == .search ? .infinity : nil)
                if compact {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, mode == .collapsed ? 14 : 0)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: mode)
    }

    private var plusButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            setMode(.composer)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LitterTheme.accent)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .overlay(
            Capsule(style: .continuous)
                .stroke(LitterTheme.accent.opacity(0.5), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .glassMorphID(plusID, in: ns)
        .accessibilityLabel("New message")
        .coachmarkAnchor(.newThread)
    }

    private var searchIconButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            setMode(.search)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LitterTheme.textSecondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .overlay(
            Capsule(style: .continuous)
                .stroke(LitterTheme.textMuted.opacity(0.3), lineWidth: 0.6)
                .allowsHitTesting(false)
        )
        .glassMorphID(searchID, in: ns)
        .accessibilityLabel("Search threads")
        .coachmarkAnchor(.search)
    }

    // MARK: - Composer

    private var composerRow: some View {
        // Collapse back to the + button when the keyboard is dismissed and
        // the composer is empty (no text, no attachment, no voice activity).
        // Two guards keep the initial enter animation from collapsing early:
        //   (1) we only collapse after the composer has been *active* at
        //       least once (focus arrived at least one frame),
        //   (2) we also require ≥ 0.6s since open — SwiftUI's focus state
        //       can flicker during the spring animation.
        HomeComposerView(
            project: project,
            transcriptionServerId: transcriptionServerId,
            onThreadCreated: { key in
                onThreadCreated(key)
                setMode(.collapsed)
            },
            onActiveChange: { active in
                if active {
                    composerHasBeenActive = true
                    return
                }
                guard !collapseSuppressed else { return }
                guard composerHasBeenActive, mode == .composer else { return }
                let elapsed = Date().timeIntervalSince(composerOpenedAt)
                guard elapsed > 0.6 else { return }
                setMode(.collapsed)
            },
            autoFocus: true,
            modelPill: modelPill
        )
        .glassMorphID(plusID, in: ns)
        .onAppear {
            composerOpenedAt = Date()
            composerHasBeenActive = false
        }
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LitterTheme.accent)

            TextField("search threads", text: $searchQuery)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .litterMonoFont(size: 14, weight: .regular)
                .foregroundStyle(LitterTheme.textPrimary)
                .focused($searchFocused)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                searchQuery = ""
                setMode(.collapsed)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LitterTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: buttonSize)
        .modifier(GlassCapsuleModifier(interactive: false))
        .overlay(
            Capsule(style: .continuous)
                .stroke(LitterTheme.accent.opacity(0.5), lineWidth: 1.0)
                .allowsHitTesting(false)
        )
        .glassMorphID(searchID, in: ns)
        .padding(.horizontal, 14)
        .task {
            // Tiny yield so the text field is in the view tree, then focus
            // immediately. Keyboard rises in parallel with the glass morph.
            try? await Task.sleep(nanoseconds: 40_000_000)
            searchFocused = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !searchFocused { searchFocused = true }
        }
        .onDisappear { searchFocused = false }
    }

    private func setMode(_ next: HomeInputMode) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            mode = next
        }
    }
}
