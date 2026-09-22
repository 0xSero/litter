import Foundation
import OSLog

/// Lightweight performance tracker using os_signpost for Instruments
/// profiling and LLog for stderr capture in debug builds.
/// All methods are no-ops when not in DEBUG builds.
enum PerfTracker {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.sigkitten.litter", category: "perf")

    /// Pending interval starts, keyed by `name` + caller key.
    ///
    /// A user-visible latency ("tap → destination rendered", "send → first
    /// streamed token") starts in one place and ends in another, usually
    /// across an `await`. `os_signpost(.begin)` and `.end` only pair into a
    /// duration when they share an `OSSignpostID`, so the id has to outlive
    /// the call that opened it. Keying on a string lets the end site name
    /// the same interaction the begin site named without threading a
    /// `OSSignpostID` through the view tree.
    private nonisolated(unsafe) static var pendingIntervals: [String: (id: OSSignpostID, name: StaticString, start: DispatchTime)] = [:]

    /// Time a synchronous block and emit a signpost + log line.
    @discardableResult
    static func time<T>(_ name: StaticString, _ block: () throws -> T) rethrows -> T {
        #if DEBUG
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        let start = DispatchTime.now()
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let ms = Double(elapsed) / 1_000_000
            os_signpost(.end, log: log, name: name, signpostID: signpostID)
            LLog.debug("perf", "\(name) took \(String(format: "%.2f", ms))ms")
        }
        #endif
        return try block()
    }

    /// Time an async block and emit a signpost + log line.
    @discardableResult
    static func timeAsync<T>(_ name: StaticString, _ block: () async throws -> T) async rethrows -> T {
        #if DEBUG
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        let start = DispatchTime.now()
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let ms = Double(elapsed) / 1_000_000
            os_signpost(.end, log: log, name: name, signpostID: signpostID)
            LLog.debug("perf", "\(name) took \(String(format: "%.2f", ms))ms")
        }
        #endif
        return try await block()
    }

    /// Stable interval key for a thread, shared by the begin and end sites.
    ///
    /// Includes the server id: two servers can expose the same thread id, and a
    /// key collision would pair one server's start with the other's end.
    static func intervalKey(_ key: ThreadKey) -> String {
        "\(key.serverId)/\(key.threadId)"
    }

    /// Start a linked interval that another call site will end.
    ///
    /// Use for user-visible latency that spans an `await` or a navigation
    /// transition: `beginInterval("OpenThread", key: threadId)` where the tap
    /// happens, `endInterval("OpenThread", key: threadId)` at the first
    /// render of the destination. Instruments reports the interval as one
    /// duration in the `perf` signpost track.
    ///
    /// Re-beginning the same key replaces the pending start: the older
    /// interval is dropped rather than ended, so a double tap cannot produce a
    /// bogus multi-second duration.
    static func beginInterval(_ name: StaticString, key: String) {
        #if DEBUG
        let compositeKey = "\(name)#\(key)"
        if pendingIntervals.removeValue(forKey: compositeKey) != nil {
            os_signpost(.event, log: log, name: "IntervalRestarted", "name=%{public}@ key=%{public}@", "\(name)", key)
        }
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID, "key=%{public}@", key)
        pendingIntervals[compositeKey] = (signpostID, name, DispatchTime.now())
        #endif
    }

    /// End an interval opened by `beginInterval` with the same name and key.
    ///
    /// A missing start is logged and ignored: the end site must never crash
    /// or fabricate a duration for an interaction that was not begun (for
    /// example when the app relaunched mid-interaction).
    static func endInterval(_ name: StaticString, key: String) {
        #if DEBUG
        let compositeKey = "\(name)#\(key)"
        guard let pending = pendingIntervals.removeValue(forKey: compositeKey) else {
            LLog.debug("perf", "\(name) end without begin key=\(key)")
            return
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - pending.start.uptimeNanoseconds
        let ms = Double(elapsed) / 1_000_000
        os_signpost(.end, log: log, name: name, signpostID: pending.id, "key=%{public}@", key)
        LLog.info("perf", "\(name) latency key=\(key) \(String(format: "%.2f", ms))ms")
        #endif
    }

    /// Emit a named event signpost (for marking points in time, not durations).
    ///
    /// `fields` is an `@autoclosure` so the caller's argument expression is
    /// **never evaluated** outside DEBUG builds. Before this, the dictionary
    /// literal (and any string interpolation inside it) was built on every
    /// call in every configuration, including Release.
    static func event(_ name: StaticString, _ fields: @autoclosure () -> [String: Any] = [:]) {
        #if DEBUG
        os_signpost(.event, log: log, name: name)
        let fields = fields()
        if !fields.isEmpty {
            LLog.debug("perf", "\(name) \(fields)")
        }
        #endif
    }
}
