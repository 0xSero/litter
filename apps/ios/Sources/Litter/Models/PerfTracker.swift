import Foundation
import OSLog

/// Lightweight performance tracker using os_signpost for Instruments
/// profiling and LLog for stderr capture in debug builds.
/// All methods are no-ops when not in DEBUG builds.
enum PerfTracker {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.sigkitten.litter", category: "perf")

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
            LLog.debug("perf", "\(name) took \(String(format: ".2f", ms))ms")
        }
        #endif
        return try await block()
    }

    /// Emit a named event signpost (for marking points in time, not durations).
    static func event(_ name: StaticString, _ fields: [String: Any] = [:]) {
        #if DEBUG
        os_signpost(.event, log: log, name: name)
        if !fields.isEmpty {
            LLog.debug("perf", "\(name) \(fields)")
        }
        #endif
    }
}
