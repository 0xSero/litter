import SwiftUI

/// Full diffs view for the focused task. One vertical page per changed file
/// (crown switches files), each page scrolls the unified-diff content with
/// colored additions/deletions/hunk markers.
///
/// The diffs are sourced from `WatchTask.diffs`, which the iPhone projects
/// from the canonical Rust-owned conversation snapshot — see
/// `WatchProjection.deriveDiffs` for the trimming policy.
struct DiffsScreen: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        // Always pull the freshest task from the store so the page stays
        // live if a new snapshot lands while we're on this screen.
        let task = store.focusedTask
        let diffs = task?.diffs ?? []

        Group {
            if diffs.isEmpty {
                WatchEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: "no diffs yet",
                    subtitle: task.map { "\($0.title) hasn't edited any files." }
                        ?? "edits will show up here once the task touches a file."
                )
            } else {
                TabView {
                    ForEach(diffs) { diff in
                        DiffPage(task: task, diff: diff, total: diffs.count, index: index(of: diff, in: diffs))
                            .tag(diff.id)
                    }
                }
                .tabViewStyle(.verticalPage)
            }
        }
        .containerBackground(theme.backgroundGradient, for: .navigation)
    }

    private func index(of diff: WatchFileDiff, in diffs: [WatchFileDiff]) -> Int {
        diffs.firstIndex(of: diff) ?? 0
    }
}

/// One file's diff. Layout: file header (path + +/-/kind), then a scrolling
/// list of monospaced lines colored by kind.
private struct DiffPage: View {
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize
    @Environment(\.isLuminanceReduced) private var isAOD
    let task: WatchTask?
    let diff: WatchFileDiff
    let total: Int
    let index: Int

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                header
                diffLines
                if diff.truncated {
                    truncationFooter
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kindIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(kindColor)
                Text(filename)
                    .font(WatchTheme.scaled(11, for: watchSize, weight: .bold))
                    .foregroundStyle(isAOD ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if let parent = parentPath, !parent.isEmpty {
                Text(parent)
                    .font(WatchTheme.mono(8))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            HStack(spacing: 6) {
                if diff.additions > 0 {
                    Text("+\(diff.additions)")
                        .font(WatchTheme.mono(9, weight: .bold))
                        .foregroundStyle(theme.success)
                }
                if diff.deletions > 0 {
                    Text("−\(diff.deletions)")
                        .font(WatchTheme.mono(9, weight: .bold))
                        .foregroundStyle(theme.danger)
                }
                Spacer(minLength: 0)
                if total > 1 {
                    Text("\(index + 1)/\(total)")
                        .font(WatchTheme.mono(9))
                        .foregroundStyle(theme.textMuted)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.surfaceLight.opacity(0.45))
        )
    }

    private var diffLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(line: line)
            }
        }
    }

    private var truncationFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .bold))
            Text("diff trimmed for watch")
                .font(WatchTheme.mono(9))
        }
        .foregroundStyle(theme.textMuted)
        .padding(.top, 2)
    }

    // MARK: - Header derivations

    private var filename: String {
        (diff.path as NSString).lastPathComponent
    }

    private var parentPath: String? {
        let parent = (diff.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    private var kindIcon: String {
        let lower = diff.kind.lowercased()
        if lower.contains("add") || lower.contains("create") { return "plus.square" }
        if lower.contains("delete") || lower.contains("remove") { return "minus.square" }
        return "pencil"
    }

    private var kindColor: Color {
        let lower = diff.kind.lowercased()
        if lower.contains("add") || lower.contains("create") { return theme.success }
        if lower.contains("delete") || lower.contains("remove") { return theme.danger }
        return theme.accent
    }

    // MARK: - Diff parsing

    private var parsedLines: [DiffLine] {
        parseDiff(diff.diff)
    }
}

/// One parsed line of a unified diff, tagged by syntactic kind so the row
/// view can pick the right color/background without re-checking prefixes.
private struct DiffLine: Hashable {
    enum Kind: Hashable {
        case addition
        case deletion
        case hunk
        case metadata
        case context
    }
    let text: String
    let kind: Kind
}

private func parseDiff(_ raw: String) -> [DiffLine] {
    raw
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { sub -> DiffLine in
            let text = sub.hasSuffix("\r") ? String(sub.dropLast()) : String(sub)
            return DiffLine(text: text, kind: classify(text))
        }
}

private func classify(_ text: String) -> DiffLine.Kind {
    if text.hasPrefix("@@") { return .hunk }
    if text.hasPrefix("+++") || text.hasPrefix("---") { return .metadata }
    if text.hasPrefix("+") { return .addition }
    if text.hasPrefix("-") { return .deletion }
    if text.hasPrefix("diff --git ")
        || text.hasPrefix("index ")
        || text.hasPrefix("new file mode ")
        || text.hasPrefix("deleted file mode ")
        || text.hasPrefix("rename from ")
        || text.hasPrefix("rename to ")
        || text.hasPrefix("similarity index ")
        || text.hasPrefix("Binary files ") {
        return .metadata
    }
    return .context
}

private struct DiffLineRow: View {
    @EnvironmentObject var theme: WatchThemeStore
    let line: DiffLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(WatchTheme.mono(9))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(background)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: return theme.success
        case .deletion: return theme.danger
        case .hunk:     return theme.accentStrong
        case .metadata: return theme.textMuted
        case .context:  return theme.textPrimary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return theme.success.opacity(0.14)
        case .deletion: return theme.danger.opacity(0.14)
        case .hunk:     return theme.accentStrong.opacity(0.14)
        case .metadata: return Color.clear
        case .context:  return Color.clear
        }
    }
}
