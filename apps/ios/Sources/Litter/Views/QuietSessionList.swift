import AVKit
import Observation
import SwiftUI

// MARK: - Session list virtualization rules
//
// Shared by Home (`HomeSessionsList`) and All Sessions (`SessionsScreen`).
// Android must match these numbers.
//
//  * Rendering: a `List` (UICollectionView, cell reuse). Only on-screen rows
//    plus the collection view's own prefetch window are built and measured;
//    nothing is laid out per session up front.
//  * Row height: fixed 62 pt at text scale 1.0 (title 17 + one mono meta
//    line), multiplied by the user's text scale. Section label rows are a
//    fixed 32 pt. Fixed heights mean a row never changes size when its
//    content updates, so live updates never move other rows.
//  * Prefetch distance: 10 rows. When row i becomes visible, rows i..i+10 are
//    eligible for hydration.
//  * Hydration: only rows that are visible or within the prefetch distance,
//    at most 4 concurrent hydrations, FIFO; a queued row that scrolls away
//    before it starts is dropped.
//  * Pagination: page size 50. The next page is requested automatically
//    when a row within 10 rows of the end appears (and a "load more" row
//    remains as a fallback). Pages grow the per-server list limit.
//  * Updates: data changes apply in place without animation; no insertion
//    or height animations on first load, cache → live, or refresh.
enum SessionListRules {
    static let rowHeight: CGFloat = 62
    static let sectionLabelHeight: CGFloat = 32
    static let prefetchRows = 10
    static let maxConcurrentHydrations = 4
    static let pageSize: UInt32 = 50
    static let loadMoreThresholdRows = 10

    static func rowHeight(textScale: CGFloat) -> CGFloat {
        (rowHeight * max(1, textScale)).rounded()
    }
}

// MARK: - Sections

/// Lowercase mono section labels, in display order.
enum SessionListSection: Int, CaseIterable, Hashable {
    case pinned
    case now
    case today
    case yesterday
    case thisWeek
    case older

    var label: String {
        switch self {
        case .pinned: return "pinned"
        case .now: return "now"
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this week"
        case .older: return "older"
        }
    }

    /// A session is "now" while it is working or touched in the last 15 min.
    static func timeSection(
        updatedAt: Date,
        isActive: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> SessionListSection {
        let age = now.timeIntervalSince(updatedAt)
        if isActive || age < 15 * 60 { return .now }
        if calendar.isDate(updatedAt, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(updatedAt, inSameDayAs: yesterday) {
            return .yesterday
        }
        if age < 7 * 24 * 60 * 60 { return .thisWeek }
        return .older
    }

    /// Groups `items` into sections, keeping the incoming order within each
    /// section. Empty sections are omitted.
    static func group<Item>(
        _ items: [Item],
        now: Date,
        isPinned: (Item) -> Bool = { _ in false },
        updatedAt: (Item) -> Date,
        isActive: (Item) -> Bool
    ) -> [(section: SessionListSection, items: [Item])] {
        var buckets: [SessionListSection: [Item]] = [:]
        for item in items {
            let section: SessionListSection = isPinned(item)
                ? .pinned
                : timeSection(updatedAt: updatedAt(item), isActive: isActive(item), now: now)
            buckets[section, default: []].append(item)
        }
        return allCases.compactMap { section in
            guard let items = buckets[section], !items.isEmpty else { return nil }
            return (section, items)
        }
    }
}

/// Compact age for the meta line: "2m", "3h", "1d", "2w", then a date.
func sessionAgeLabel(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    if days < 60 { return "\(days / 7)w" }
    return sessionAgeDateFormatter.string(from: date).lowercased()
}

private let sessionAgeDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
}()

/// Last path component of a working directory ("~/code/litter" → "litter").
func sessionProjectName(_ cwd: String) -> String? {
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "/" else { return nil }
    let last = (trimmed as NSString).lastPathComponent
    return last.isEmpty ? nil : last
}

// MARK: - Row

struct QuietMetaPart: Hashable {
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }
}

/// Litter Quiet session row: title (17) over one mono meta line
/// ("server · project · age"). Fixed height, no icons, dots or badges.
struct QuietSessionRow: View {
    let title: String
    let meta: [QuietMetaPart]
    var dimmed: Bool = false

    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title.isEmpty ? "Untitled session" : title)
                .litterFont(size: 17)
                .foregroundStyle(dimmed ? LitterTheme.textSecondary : LitterTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            metaLine
                .litterMeta()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SessionListRules.rowHeight(textScale: textScale))
        .contentShape(Rectangle())
    }

    private var metaLine: Text {
        var line = Text(verbatim: "")
        for (index, part) in meta.enumerated() where !part.text.isEmpty {
            if index > 0 { line = line + Text(verbatim: " · ") }
            var piece = Text(verbatim: part.text)
            if let color = part.color { piece = piece.foregroundColor(color) }
            line = line + piece
        }
        return line
    }
}

/// Fixed-height lowercase mono section label row.
struct QuietSectionLabelRow: View {
    let section: SessionListSection

    var body: some View {
        Text(section.label)
            .litterSectionLabel()
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: SessionListRules.sectionLabelHeight, alignment: .bottomLeading)
            .padding(.bottom, 2)
    }
}

extension View {
    /// Plain full-bleed list row styling shared by the session lists.
    func quietListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: LitterSpace.margin, bottom: 0, trailing: LitterSpace.margin))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Viewport hydration

/// Bounded, visibility-driven hydration queue. Rows report appear /
/// disappear; the owner requests keys for the visible row plus the prefetch
/// distance. At most `SessionListRules.maxConcurrentHydrations` run at once.
@MainActor
@Observable
final class SessionViewportHydrator {
    /// Keys currently hydrating (drives the "loading" meta word).
    private(set) var inFlight: Set<ThreadKey> = []
    @ObservationIgnored private var queue: [ThreadKey] = []
    @ObservationIgnored private var attempted: Set<ThreadKey> = []
    @ObservationIgnored private(set) var visibleKeys: Set<ThreadKey> = []
    @ObservationIgnored var hydrate: ((ThreadKey) async -> Void)?

    func rowAppeared(_ key: ThreadKey) {
        visibleKeys.insert(key)
    }

    /// A row that leaves the viewport before its hydration starts is
    /// dropped from the queue; in-flight work is left to finish.
    func rowDisappeared(_ key: ThreadKey) {
        visibleKeys.remove(key)
        queue.removeAll { $0 == key }
    }

    func request(_ keys: [ThreadKey]) {
        for key in keys where !attempted.contains(key) && !inFlight.contains(key) && !queue.contains(key) {
            queue.append(key)
        }
        pump()
    }

    /// Allow previously attempted keys to be tried again (e.g. after a
    /// server reconnects or the pin set changes).
    func resetAttempts() {
        attempted.removeAll()
    }

    private func pump() {
        guard let hydrate else { return }
        while inFlight.count < SessionListRules.maxConcurrentHydrations, !queue.isEmpty {
            let key = queue.removeFirst()
            attempted.insert(key)
            inFlight.insert(key)
            Task { @MainActor [weak self] in
                await hydrate(key)
                guard let self else { return }
                self.inFlight.remove(key)
                self.pump()
            }
        }
    }
}

// MARK: - Home list

/// Home sessions list: one plain virtualized list grouped by time section.
/// Replaces the per-session UIHostingController scroll host and its
/// zoom/pinch modes.
struct HomeSessionsList: View {
    struct Callbacks {
        var onOpen: (HomeDashboardRecentSession) -> Void
        var onReply: (HomeDashboardRecentSession) -> Void
        var onHide: (ThreadKey) -> Void
        var onPin: (ThreadKey) -> Void
        var onUnpin: (ThreadKey) -> Void
        var onCancelTurn: (HomeDashboardRecentSession) -> Void
        var onDelete: (HomeDashboardRecentSession) -> Void
        var onFork: (HomeDashboardRecentSession) -> Void
        var onShowPiP: (HomeDashboardRecentSession) -> Void
    }

    let sessions: [HomeDashboardRecentSession]
    let pinnedThreadKeys: Set<SavedThreadsStore.PinnedKey>
    let offlineServerIds: Set<String>
    let hydratingKeys: Set<ThreadKey>
    let cancellingKeys: Set<String>
    let openingKey: ThreadKey?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let callbacks: Callbacks
    /// Row `index` (in `sessions`) became visible.
    let onRowAppear: (Int) -> Void
    let onRowDisappear: (ThreadKey) -> Void

    var body: some View {
        let now = Date()
        let indexByKey = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.key, $0) })
        let groups = SessionListSection.group(
            sessions,
            now: now,
            updatedAt: \.updatedAt,
            isActive: \.hasTurnActive
        )
        List {
            ForEach(groups, id: \.section) { group in
                QuietSectionLabelRow(section: group.section)
                    .quietListRow()
                ForEach(group.items) { session in
                    row(session, now: now)
                        .quietListRow()
                        .onAppear { onRowAppear(indexByKey[session.key] ?? 0) }
                        .onDisappear { onRowDisappear(session.key) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.top, topInset, for: .scrollContent)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        // Content updates land in place; never animate row moves/inserts.
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("home.sessionsList")
    }

    private func stateWord(_ session: HomeDashboardRecentSession) -> QuietMetaPart? {
        let id = "\(session.key.serverId)/\(session.key.threadId)"
        if openingKey == session.key { return QuietMetaPart("opening") }
        if cancellingKeys.contains(id) { return QuietMetaPart("cancelling", color: LitterTheme.warning) }
        if session.hasTurnActive { return QuietMetaPart("working") }
        if offlineServerIds.contains(session.serverId) { return QuietMetaPart("offline", color: LitterTheme.danger) }
        if hydratingKeys.contains(session.key) { return QuietMetaPart("loading") }
        return nil
    }

    private func row(_ session: HomeDashboardRecentSession, now: Date) -> some View {
        var meta = [QuietMetaPart(session.serverDisplayName)]
        if let project = sessionProjectName(session.cwd) { meta.append(QuietMetaPart(project)) }
        if session.isFork { meta.append(QuietMetaPart("fork")) }
        if session.isSubagent, let agent = session.agentLabel { meta.append(QuietMetaPart(agent)) }
        meta.append(stateWord(session) ?? QuietMetaPart(sessionAgeLabel(session.updatedAt, now: now)))
        let pinned = pinnedThreadKeys.contains(SavedThreadsStore.PinnedKey(threadKey: session.key))

        return QuietSessionRow(
            title: session.sessionTitle,
            meta: meta,
            dimmed: offlineServerIds.contains(session.serverId)
        )
        .onTapGesture { callbacks.onOpen(session) }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home.recentSessionCard")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { callbacks.onReply(session) } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .tint(LitterTheme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { callbacks.onHide(session.key) } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            .tint(LitterTheme.textMuted)
            Button(role: .destructive) { callbacks.onDelete(session) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { callbacks.onReply(session) } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button { callbacks.onFork(session) } label: {
                Label("Fork", systemImage: "arrow.triangle.branch")
            }
            .disabled(session.hasTurnActive)
            if session.hasTurnActive {
                Button(role: .destructive) { callbacks.onCancelTurn(session) } label: {
                    Label("Cancel Turn", systemImage: "stop.circle")
                }
            }
            Button {
                if pinned { callbacks.onUnpin(session.key) } else { callbacks.onPin(session.key) }
            } label: {
                Label(
                    pinned ? "Remove from Home" : "Pin to Home",
                    systemImage: pinned ? "minus.circle" : "pin"
                )
            }
            if AVPictureInPictureController.isPictureInPictureSupported() {
                Button { callbacks.onShowPiP(session) } label: {
                    Label("Show in Picture in Picture", systemImage: "pip")
                }
            }
            Button { callbacks.onHide(session.key) } label: {
                Label("Hide from Home", systemImage: "eye.slash")
            }
            Button(role: .destructive) { callbacks.onDelete(session) } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }
}
