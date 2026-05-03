import Foundation
import WidgetKit

/// Timeline entry shared by all three complications. Designed to round-trip
/// through the `group.com.sigkitten.litter` App Group — the iOS app writes
/// the current running-task snapshot into `UserDefaults` and complications
/// read it on each reload.
struct LitterComplicationEntry: TimelineEntry {
    enum Mode: String, Codable {
        case idle, running, offline
    }

    let date: Date
    let mode: Mode
    /// Wall-clock epoch ms when the running task's current turn started.
    /// Used to compute live runtime against `entry.date` in the timeline.
    let lastTurnStartMsEpoch: Int64?
    /// Stable task identifier (e.g. "macbook-pro:t1") used for `widgetURL` deep links.
    let taskId: String?
    /// Progress [0, 1] of the running task — used for circular arc + pips.
    let progress: Double
    /// Short human label shown on rectangular / corner faces.
    let title: String
    /// Current tool-call line, shown in the rectangular family only.
    let toolLine: String
    /// Count of connected servers (idle mode only).
    let serverCount: Int

    /// Runtime label as `m:ss` (or `mm:ss` past 10 minutes), capped at 99:59.
    func runtimeLabel(at now: Date) -> String {
        guard let startMs = lastTurnStartMsEpoch else { return "0:00" }
        let startSeconds = TimeInterval(startMs) / 1000.0
        let elapsed = max(0, Int(now.timeIntervalSince1970 - startSeconds))
        let capped = min(elapsed, 99 * 60 + 59)
        let m = capped / 60
        let s = capped % 60
        return String(format: "%d:%02d", m, s)
    }

    static let placeholder = LitterComplicationEntry(
        date: .now,
        mode: .running,
        lastTurnStartMsEpoch: Int64((Date.now.timeIntervalSince1970 - 42) * 1000),
        taskId: "preview:t1",
        progress: 0.4,
        title: "fix auth token expiry",
        toolLine: "edit_file src/auth.go",
        serverCount: 3
    )

    static let idlePlaceholder = LitterComplicationEntry(
        date: .now,
        mode: .idle,
        lastTurnStartMsEpoch: nil,
        taskId: nil,
        progress: 1,
        title: "3 servers ready",
        toolLine: "tap to open",
        serverCount: 3
    )
}

/// Reads complication data out of the shared App Group.
enum LitterComplicationStore {
    static let appGroup = "group.com.sigkitten.litter"
    private static let key = "complication.snapshot.v1"

    static func current() -> LitterComplicationEntry {
        guard
            let defaults = UserDefaults(suiteName: appGroup),
            let data = defaults.data(forKey: key),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return .placeholder
        }
        return LitterComplicationEntry(
            date: .now,
            mode: payload.mode,
            lastTurnStartMsEpoch: payload.lastTurnStartMsEpoch,
            taskId: payload.taskId,
            progress: payload.progress,
            title: payload.title,
            toolLine: payload.toolLine,
            serverCount: payload.serverCount
        )
    }

    /// Write a snapshot from the iOS container app. Called opportunistically
    /// on task start/step change/task end.
    static func write(_ entry: LitterComplicationEntry) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let payload = Payload(
            mode: entry.mode,
            lastTurnStartMsEpoch: entry.lastTurnStartMsEpoch,
            taskId: entry.taskId,
            progress: entry.progress,
            title: entry.title,
            toolLine: entry.toolLine,
            serverCount: entry.serverCount
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }

    private struct Payload: Codable {
        let mode: LitterComplicationEntry.Mode
        let lastTurnStartMsEpoch: Int64?
        let taskId: String?
        let progress: Double
        let title: String
        let toolLine: String
        let serverCount: Int
    }
}
