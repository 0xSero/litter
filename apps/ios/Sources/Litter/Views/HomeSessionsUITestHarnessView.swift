import Observation
import SwiftUI

#if DEBUG
/// Exercises the production list and its gestures with synthetic data. Detail
/// navigation is local to this harness; it does not test transport or hydration.
@MainActor
struct HomeSessionsUITestHarnessView: View {
    @State private var sessions = Self.seedSessions
    @State private var zoomLevel = 2
    @State private var path: [HomeDashboardRecentSession] = []
    @State private var probe = HomeSessionsHarnessProbe()
    @State private var pinned: Set<SavedThreadsStore.PinnedKey> = []
    @State private var opens = 0
    @State private var replies = 0
    @State private var hides = 0
    @State private var lastAction = "none"

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 8) {
                Text("Synthetic component test · no server requests")
                    .font(.caption)
                HStack {
                    ForEach(1...4, id: \.self) { level in
                        Button("Zoom \(level)") { zoomLevel = level }
                            .accessibilityIdentifier("homeHarness.zoom.\(level)")
                    }
                }
                HStack {
                    Button("Top") { probe.view?.debugScroll(to: 0) }
                        .accessibilityIdentifier("homeHarness.top")
                    Button("Session 900") { probe.view?.debugScroll(to: 900) }
                        .accessibilityIdentifier("homeHarness.deep")
                    Button("End") { probe.view?.debugScroll(to: sessions.count - 1) }
                        .accessibilityIdentifier("homeHarness.end")
                }
                HStack {
                    metric("Zoom", value: zoomLevel, id: "zoom")
                    metric("Mounted", value: probe.mounted, id: "mounted")
                    metric("Total", value: probe.total, id: "total")
                }
                Text("Visible: \(probe.firstVisible)")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("homeHarness.visible")
                    .accessibilityValue(probe.firstVisible)
                Text("Opened \(opens) · replies \(replies) · hidden \(hides)")
                    .font(.caption)
                    .accessibilityIdentifier("homeHarness.actions")
                Text(lastAction)
                    .font(.caption)
                    .accessibilityIdentifier("homeHarness.lastAction")

                HomeSessionsScrollView(
                    sessions: sessions,
                    pinnedThreadKeys: pinned,
                    hydratingKeys: [],
                    cancellingKeys: [],
                    openingKey: nil,
                    zoomLevel: $zoomLevel,
                    showCatFooter: false,
                    topInset: 0,
                    bottomInset: 16,
                    callbacks: .init(
                        onOpen: { session in
                            opens += 1
                            lastAction = "opened \(session.key.threadId)"
                            path.append(session)
                        },
                        onReply: { session in
                            replies += 1
                            lastAction = "reply \(session.key.threadId)"
                        },
                        onHide: { key in
                            hides += 1
                            lastAction = "hidden \(key.threadId)"
                            sessions.removeAll { $0.key == key }
                        },
                        onPin: { key in
                            pinned.insert(.init(serverId: key.serverId, threadId: key.threadId))
                            lastAction = "pinned \(key.threadId)"
                        },
                        onUnpin: { key in
                            pinned.remove(.init(serverId: key.serverId, threadId: key.threadId))
                            lastAction = "unpinned \(key.threadId)"
                        },
                        onCancelTurn: { lastAction = "cancel \($0.key.threadId)" },
                        onDelete: { session in
                            sessions.removeAll { $0.key == session.key }
                            lastAction = "deleted \(session.key.threadId)"
                        },
                        onFork: { lastAction = "fork \($0.key.threadId)" },
                        onShowPiP: { lastAction = "picture in picture \($0.key.threadId)" }
                    ),
                    debugViewAttached: { probe.attach($0) }
                )
                .accessibilityIdentifier("homeHarness.list")
            }
            .padding(.top, 8)
            .background(LitterTheme.backgroundGradient)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HomeDashboardRecentSession.self) { session in
                VStack(spacing: 16) {
                    Text(session.sessionTitle)
                        .accessibilityIdentifier("homeHarness.detail")
                    Text("Local fixture detail. Use the native Back button or edge swipe.")
                    Text("Production list callback → SwiftUI navigation; no transport.")
                        .font(.caption)
                }
                .padding()
                .navigationTitle("Session detail")
            }
        }
    }

    private func metric(_ label: String, value: Int, id: String) -> some View {
        Text("\(label): \(value)")
            .font(.caption.monospacedDigit())
            .accessibilityIdentifier("homeHarness.\(id)")
            .accessibilityValue(String(value))
    }

    private static let seedSessions: [HomeDashboardRecentSession] = (0..<1_000).map { index in
        HomeDashboardRecentSession(
            key: ThreadKey(serverId: "fixture-\(index % 10)", threadId: "session-\(index)"),
            serverId: "fixture-\(index % 10)",
            serverDisplayName: "Fixture \(index % 10)",
            agentRuntimeKind: .codex,
            isLocal: false,
            sessionTitle: String(format: "Session %04d", index),
            preview: "Synthetic performance fixture \(index)",
            cwd: "/fixtures/project-\(index % 20)",
            model: "fixture-model",
            agentLabel: nil,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 - index)),
            hasTurnActive: false,
            isResumed: true,
            isSubagent: false,
            isFork: false,
            forkedFromId: nil,
            lineage: nil,
            lastResponsePreview: "## Fixture \(index)\n\n" + String(repeating: "A rendered response with **bold text** and `inline code`.\n\n", count: index % 5 + 1),
            lastResponseTurnId: "turn-\(index)",
            lastUserMessage: "Inspect fixture \(index)",
            lastToolLabel: nil,
            stats: nil,
            tokenUsage: nil,
            goal: nil,
            recentToolLog: [],
            lastTurnStart: nil,
            lastTurnEnd: nil
        )
    }
}

@MainActor
@Observable
private final class HomeSessionsHarnessProbe {
    @ObservationIgnored weak var view: HomeSessionsScrollUIView?
    @ObservationIgnored private var readScheduled = false
    var mounted = 0
    var total = 0
    var firstVisible = "none"

    func attach(_ view: HomeSessionsScrollUIView) {
        self.view = view
        view.debugStateDidChange = { [weak self] in self?.scheduleRead() }
        scheduleRead()
    }

    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readScheduled = false
            guard let view = self.view else { return }
            self.mounted = view.debugMountedRowCount
            self.total = view.debugSessionCount
            self.firstVisible = view.debugVisibleThreadKeys.first?.threadId ?? "none"
        }
    }
}
#endif
