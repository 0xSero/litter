import SwiftUI

/// Scrollable list of every thread across connected servers, sorted by
/// recency, filtered by the current query. Tapping a row calls `onAdd`.
/// Shows an indicator on rows already on the home list.
struct ThreadSearchResultsView: View {
    let sessions: [HomeDashboardRecentSession]
    let pinnedThreadKeys: Set<SavedThreadsStore.PinnedKey>
    let query: String
    let runtimeKinds: [AgentRuntimeKind]
    @Binding var selectedRuntimeKind: AgentRuntimeKind?
    var isLoading: Bool = false
    let onRefresh: () async -> Void
    let onAdd: (HomeDashboardRecentSession) -> Void
    let onRemove: (HomeDashboardRecentSession) -> Void
    /// Padding applied inside the scroll view so content can scroll under
    /// the floating top/bottom chrome. Caller passes the same values the
    /// tasks list uses so the search view feels like a drop-in replacement.
    var contentInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    /// Tracks which fork lineages the user has expanded inline. Keyed by the
    /// lineage's root `ThreadKey`. Empty by default — clusters render
    /// collapsed.
    @State private var expandedClusters: Set<ThreadKey> = []

    private var filtered: [HomeDashboardRecentSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.filter { session in
            if let selectedRuntimeKind, session.agentRuntimeKind != selectedRuntimeKind {
                return false
            }
            guard !trimmed.isEmpty else { return true }
            return session.sessionTitle.lowercased().contains(trimmed)
            || session.cwd.lowercased().contains(trimmed)
            || session.serverDisplayName.lowercased().contains(trimmed)
            || session.preview.lowercased().contains(trimmed)
        }
    }

    /// Group filtered sessions into lineage clusters. Singletons (no
    /// `lineage` or one filtered member) render as today; multi-member
    /// lineages collapse into one expandable cluster row. Cluster order
    /// preserves recency by anchoring on each cluster's first appearance
    /// in the already-sorted `filtered` list.
    private var clusters: [ThreadSearchCluster] {
        var bucket: [ThreadKey: [HomeDashboardRecentSession]] = [:]
        var firstAppearance: [ThreadKey: Int] = [:]
        for (idx, session) in filtered.enumerated() {
            let root = session.lineage?.rootKey ?? session.key
            if firstAppearance[root] == nil { firstAppearance[root] = idx }
            bucket[root, default: []].append(session)
        }
        return bucket
            .map { rootKey, members in
                ThreadSearchCluster(
                    rootKey: rootKey,
                    members: members.sorted { $0.updatedAt > $1.updatedAt }
                )
            }
            .sorted {
                (firstAppearance[$0.rootKey] ?? .max) < (firstAppearance[$1.rootKey] ?? .max)
            }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Color.clear.frame(height: contentInsets.top)
                runtimeFilterRow
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(LitterTheme.accent)
                        Text("Loading threads…")
                            .litterFont(.footnote)
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                    .padding(.vertical, 24)
                } else if filtered.isEmpty {
                    Text(sessions.isEmpty ? "No threads yet" : "No matches")
                        .litterFont(.footnote)
                        .foregroundStyle(LitterTheme.textMuted)
                        .padding(.vertical, 24)
                } else {
                    ForEach(clusters) { cluster in
                        if cluster.members.count == 1, let only = cluster.members.first {
                            ThreadSearchRow(
                                session: only,
                                isPinned: pinnedThreadKeys.contains(SavedThreadsStore.PinnedKey(threadKey: only.key)),
                                onAdd: { onAdd(only) },
                                onRemove: { onRemove(only) }
                            )
                            Divider().opacity(0.2)
                        } else {
                            ThreadSearchClusterRow(
                                cluster: cluster,
                                pinnedThreadKeys: pinnedThreadKeys,
                                isExpanded: expandedClusters.contains(cluster.rootKey),
                                onToggleExpanded: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if expandedClusters.contains(cluster.rootKey) {
                                            expandedClusters.remove(cluster.rootKey)
                                        } else {
                                            expandedClusters.insert(cluster.rootKey)
                                        }
                                    }
                                },
                                onPin: onAdd,
                                onUnpin: onRemove
                            )
                            Divider().opacity(0.2)
                        }
                    }
                }
                Color.clear.frame(height: contentInsets.bottom)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await onRefresh()
        }
    }

    @ViewBuilder
    private var runtimeFilterRow: some View {
        if runtimeKinds.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    runtimeFilterPill(label: "All", kind: nil)
                    ForEach(runtimeKinds, id: \.self) { kind in
                        runtimeFilterPill(label: kind.titleDisplayLabel, kind: kind)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private func runtimeFilterPill(label: String, kind: AgentRuntimeKind?) -> some View {
        let isActive = selectedRuntimeKind == kind
        return Button {
            selectedRuntimeKind = kind
        } label: {
            HStack(spacing: 6) {
                if let kind {
                    AgentIconView(kind: kind, size: 12)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .litterFont(size: 10, weight: .semibold)
                }
                Text(label)
                    .lineLimit(1)
            }
            .litterFont(.caption)
            .foregroundStyle(isActive ? LitterTheme.textOnAccent : LitterTheme.textSecondary)
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
}

private struct ThreadSearchRow: View {
    let session: HomeDashboardRecentSession
    let isPinned: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: { isPinned ? onRemove() : onAdd() }) {
            HStack(alignment: .center, spacing: 10) {
                ThreadSearchRuntimeIcon(kind: session.agentRuntimeKind)
                VStack(alignment: .leading, spacing: 2) {
                    FormattedText(text: session.sessionTitle, lineLimit: 1)
                        .litterFont(size: 13, weight: .semibold)
                        .foregroundStyle(LitterTheme.textPrimary)
                    HStack(spacing: 4) {
                        Text(session.serverDisplayName)
                            .foregroundStyle(LitterTheme.accent.opacity(0.7))
                        if let workspace = HomeDashboardSupport.workspaceLabel(for: session.cwd) {
                            Text("\u{00b7}")
                                .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                            Text(workspace)
                                .foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
                        }
                        Text("\u{00b7}")
                            .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                        Text(relativeDate(Int64(session.updatedAt.timeIntervalSince1970)))
                            .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
                    }
                    .litterMonoFont(size: 10, weight: .regular)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isPinned ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isPinned ? LitterTheme.accent : LitterTheme.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ThreadSearchRuntimeIcon: View {
    let kind: AgentRuntimeKind

    var body: some View {
        AgentIconView(kind: kind, size: 16)
            .accessibilityLabel(kind.displayLabel)
    }
}

/// One lineage's worth of search rows. `members` is sorted by `updatedAt`
/// desc, so `members.first` is the cluster's "head" (most recently active
/// branch) — that's what the collapsed row surfaces.
struct ThreadSearchCluster: Identifiable {
    let rootKey: ThreadKey
    let members: [HomeDashboardRecentSession]

    var id: ThreadKey { rootKey }
}

/// Cluster row that collapses N sibling threads into a single visual unit.
/// Tapping the branches pill expands the children inline — each child has
/// its own pin button, so the user can still pin a specific branch.
private struct ThreadSearchClusterRow: View {
    let cluster: ThreadSearchCluster
    let pinnedThreadKeys: Set<SavedThreadsStore.PinnedKey>
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onPin: (HomeDashboardRecentSession) -> Void
    let onUnpin: (HomeDashboardRecentSession) -> Void

    /// The cluster head represents the lineage's identity. Prefer the root
    /// thread (the original) so the head reads stable: forks come and go,
    /// the root is canonical. Fall back to the most-recent member when the
    /// root isn't loaded into the snapshot.
    private var head: HomeDashboardRecentSession? {
        cluster.members.first(where: { $0.key == cluster.rootKey })
            ?? cluster.members.first
    }

    /// Latest activity across the whole lineage — root or any fork. Used
    /// for the head row's "Nh ago" so the head reflects whether the
    /// lineage is fresh, even though its title is the (possibly older) root.
    private var headLatestUpdatedAt: Date {
        cluster.members.map(\.updatedAt).max() ?? Date(timeIntervalSince1970: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let head { headRow(for: head) }
            if isExpanded {
                childrenList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isExpanded ? LitterTheme.surface.opacity(0.3) : Color.clear)
    }

    private func headRow(for session: HomeDashboardRecentSession) -> some View {
        let isPinned = pinnedThreadKeys.contains(SavedThreadsStore.PinnedKey(threadKey: session.key))
        return HStack(alignment: .center, spacing: 10) {
            ThreadSearchRuntimeIcon(kind: session.agentRuntimeKind)
            VStack(alignment: .leading, spacing: 2) {
                FormattedText(text: session.sessionTitle, lineLimit: 1)
                    .litterFont(size: 13, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
                HStack(spacing: 4) {
                    Text(session.serverDisplayName)
                        .foregroundStyle(LitterTheme.accent.opacity(0.7))
                    if let workspace = HomeDashboardSupport.workspaceLabel(for: session.cwd) {
                        Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                        Text(workspace).foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
                    }
                    Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                    Text(relativeDate(Int64(headLatestUpdatedAt.timeIntervalSince1970)))
                        .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
                }
                .litterMonoFont(size: 10, weight: .regular)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            branchesPill
            pinButton(isPinned: isPinned, size: 16) {
                isPinned ? onUnpin(session) : onPin(session)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var branchesPill: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .litterFont(size: 9, weight: .semibold)
                Text("\(cluster.members.count)")
                    .litterMonoFont(size: 11, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .litterFont(size: 8, weight: .semibold)
            }
            .foregroundStyle(LitterTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(LitterTheme.accent.opacity(isExpanded ? 0.18 : 0.12))
            )
            .overlay(
                Capsule().stroke(LitterTheme.accent.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.members.count) branches")
    }

    private var childrenList: some View {
        // Skip the cluster's head — it's already shown by `headRow`. Showing
        // it again in the branches list reads as a duplicate. The root and
        // every other sibling stay visible so any branch is still pinnable.
        let headKey = head?.key
        let otherMembers = cluster.members.filter { $0.key != headKey }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(otherMembers) { member in
                let isPinned = pinnedThreadKeys.contains(SavedThreadsStore.PinnedKey(threadKey: member.key))
                let isRoot = member.key == cluster.rootKey
                Button(action: { isPinned ? onUnpin(member) : onPin(member) }) {
                    HStack(alignment: .center, spacing: 10) {
                        Rectangle()
                            .fill(LitterTheme.accent.opacity(0.4))
                            .frame(width: 10, height: 1)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                FormattedText(text: branchLabel(for: member, isRoot: isRoot), lineLimit: 1)
                                    .litterFont(size: 12.5, weight: isPinned ? .semibold : .regular)
                                    .foregroundStyle(isPinned ? LitterTheme.accent : LitterTheme.textPrimary.opacity(0.92))
                                if isRoot {
                                    Text("root")
                                        .litterMonoFont(size: 9, weight: .regular)
                                        .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
                                }
                            }
                            Text(relativeDate(Int64(member.updatedAt.timeIntervalSince1970)))
                                .litterMonoFont(size: 10, weight: .regular)
                                .foregroundStyle(LitterTheme.textMuted.opacity(0.75))
                        }
                        Spacer(minLength: 6)
                        pinButton(isPinned: isPinned, size: 14) {
                            isPinned ? onUnpin(member) : onPin(member)
                        }
                    }
                    .padding(.leading, 36)
                    .padding(.trailing, 14)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LitterTheme.accent.opacity(0.3))
                .frame(width: 2)
                .padding(.leading, 30)
        }
    }

    private func pinButton(isPinned: Bool, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isPinned ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isPinned ? LitterTheme.accent : LitterTheme.textSecondary.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    /// Codex auto-titles threads from the *first* user message, which is
    /// shared up to the fork point — so two siblings often have identical
    /// titles. Inside a cluster the user needs a distinguisher: the
    /// most-recent user message (the divergent prompt) when it actually
    /// differs from the title. Fall back to the title for the root and
    /// for forks whose latest prompt hasn't diverged yet.
    private func branchLabel(for member: HomeDashboardRecentSession, isRoot: Bool) -> String {
        if isRoot { return member.sessionTitle }
        let lastUser = (member.lastUserMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if lastUser.isEmpty { return member.sessionTitle }
        let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if normalize(lastUser) == normalize(member.sessionTitle) {
            return member.sessionTitle
        }
        return lastUser
    }
}
