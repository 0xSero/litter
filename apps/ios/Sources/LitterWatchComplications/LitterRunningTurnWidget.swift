import SwiftUI
import WidgetKit

/// Smart Stack widget mirroring the iPhone's Live Activity for the
/// currently running turn. Reads `running.turn.v1` from the App Group and
/// hides when no turn is running or the snapshot is stale.
///
/// Uses `accessoryRectangular` so it slots into the watchOS Smart Stack
/// alongside other apps' Live Activity surfaces.
struct LitterRunningTurnWidget: Widget {
    let kind = "LitterRunningTurnWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RunningTurnTimelineProvider()) { entry in
            LitterRunningTurnView(entry: entry)
                .widgetAccentable()
                .containerBackground(.clear, for: .widget)
        }
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
        .configurationDisplayName("Codex Running")
        .description("Mirrors the iPhone Live Activity for the active task.")
    }
}

struct LitterRunningTurnEntry: TimelineEntry {
    let date: Date
    /// `nil` snapshot tells the view to render a hidden/empty placeholder.
    let snapshot: RunningTurnSnapshot?

    static let placeholder = LitterRunningTurnEntry(
        date: .now,
        snapshot: RunningTurnSnapshot(
            taskId: "preview:t1",
            title: "fix auth token expiry",
            serverName: "macbook-pro",
            model: "gpt-5-codex",
            startedAtMs: Int64((Date.now.timeIntervalSince1970 - 42) * 1000),
            lastTool: "edit_file src/auth.go"
        )
    )

    static let empty = LitterRunningTurnEntry(date: .now, snapshot: nil)
}

/// Static timeline provider — re-reads the App Group on each refresh. When
/// a turn is running we tick once a minute for 30 minutes so the rendered
/// elapsed string updates without explicit reload calls.
struct RunningTurnTimelineProvider: TimelineProvider {
    typealias Entry = LitterRunningTurnEntry

    func placeholder(in context: Context) -> LitterRunningTurnEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (LitterRunningTurnEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LitterRunningTurnEntry>) -> Void) {
        let now = Date()
        let entry = currentEntry(at: now)

        guard let snapshot = entry.snapshot, !RunningTurnStore.isStale(snapshot, now: now) else {
            // No turn running — single empty entry, reload after 5m so we
            // pick up newly started turns reasonably quickly without burning
            // budget.
            let timeline = Timeline(
                entries: [LitterRunningTurnEntry(date: now, snapshot: nil)],
                policy: .after(now.addingTimeInterval(60 * 5))
            )
            completion(timeline)
            return
        }

        var entries: [LitterRunningTurnEntry] = []
        for step in 0..<30 {
            entries.append(LitterRunningTurnEntry(
                date: now.addingTimeInterval(TimeInterval(step) * 60),
                snapshot: snapshot
            ))
        }
        let timeline = Timeline(
            entries: entries,
            policy: .after(now.addingTimeInterval(60 * 30))
        )
        completion(timeline)
    }

    private func currentEntry(at now: Date = .now) -> LitterRunningTurnEntry {
        guard let snapshot = RunningTurnStore.current(),
              !RunningTurnStore.isStale(snapshot, now: now) else {
            return LitterRunningTurnEntry(date: now, snapshot: nil)
        }
        return LitterRunningTurnEntry(date: now, snapshot: snapshot)
    }
}

struct LitterRunningTurnView: View {
    let entry: LitterRunningTurnEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            inlineBody
        default:
            rectangularBody
        }
    }

    @ViewBuilder
    private var rectangularBody: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LitterComplicationTint.ginger)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Text("L")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                        )
                    Text("CODEX · \(elapsedLabel(for: snapshot))")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(LitterComplicationTint.ginger)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(LitterComplicationTint.ginger)
                        .frame(width: 4, height: 4)
                }
                Text(snapshot.title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(snapshot.lastTool ?? snapshot.serverName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .widgetURL(URL(string: "litter-watch://task/\(snapshot.taskId)"))
        } else {
            // Nothing running — keep the widget surface minimal so it slips
            // out of the Smart Stack rotation rather than spamming the user.
            Text("")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var inlineBody: some View {
        if let snapshot = entry.snapshot {
            Text("codex \(elapsedLabel(for: snapshot)) — \(snapshot.title)")
        } else {
            Text("codex idle")
        }
    }

    private func elapsedLabel(for snapshot: RunningTurnSnapshot) -> String {
        let elapsed = max(0, Int(entry.date.timeIntervalSince1970 - TimeInterval(snapshot.startedAtMs) / 1000.0))
        let capped = min(elapsed, 99 * 60 + 59)
        return String(format: "%d:%02d", capped / 60, capped % 60)
    }
}
