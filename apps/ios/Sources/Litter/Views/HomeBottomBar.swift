import SwiftUI

/// Home bottom bar. On phone it is always the home composer; in the
/// iPad/Mac sidebar it is a search button that morphs into a search row
/// (the parent renders results above it).
enum HomeInputMode: Hashable {
    case collapsed
    case search
}

struct HomeBottomBar: View {
    @Binding var mode: HomeInputMode
    @Binding var searchQuery: String
    let project: AppProject?
    let transcriptionServerId: String?
    let onThreadCreated: (ThreadKey) -> Void
    /// Model pill shown inside the composer's bottom row.
    var modelPill: HomeComposerModelPill? = nil
    /// Sidebar variant (iPad/Mac): search only, no composer. Used by the iPad + Catalyst
    /// sidebar chrome where there's no room (and no use) for a composer.
    var compact: Bool = false
    @FocusState private var searchFocused: Bool

    @Namespace private var ns

    private let searchID = "bottomSearch"
    private let buttonSize: CGFloat = 38

    var body: some View {
        // Phone: the composer is always on screen. Sidebar (iPad/Mac): only
        // the search button morphs into the search row.
        if compact {
            HStack(spacing: 0) {
                GlassMorphContainer(spacing: 14) {
                    if mode == .search {
                        searchRow
                    } else {
                        searchIconButton
                    }
                }
                .frame(maxWidth: mode == .search ? .infinity : nil)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, mode == .collapsed ? 14 : 0)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: mode)
        } else {
            composerRow
        }
    }

    private var searchIconButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            setMode(.search)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LitterTheme.textSecondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(RaisedCapsuleModifier())
        .glassMorphID(searchID, in: ns)
        .accessibilityLabel("Search threads")
        .coachmarkAnchor(.search)
    }

    // MARK: - Composer

    private var composerRow: some View {
        HomeComposerView(
            project: project,
            transcriptionServerId: transcriptionServerId,
            onThreadCreated: onThreadCreated,
            modelPill: modelPill
        )
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LitterTheme.textSecondary)

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
        .modifier(RaisedCapsuleModifier())
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
