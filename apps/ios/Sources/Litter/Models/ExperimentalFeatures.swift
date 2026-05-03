import Foundation
import Observation

enum LitterFeature: String, CaseIterable, Identifiable {
    case realtimeVoice = "realtime_voice"
    case ipc = "ipc"
    case appleWatch = "apple_watch"
    case thinkingMinigame = "thinking_minigame"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realtimeVoice: return "Realtime"
        case .ipc: return "IPC"
        case .appleWatch: return "Apple Watch"
        case .thinkingMinigame: return "Thinking minigame"
        }
    }

    var description: String {
        switch self {
        case .realtimeVoice: return "Show the realtime voice launcher on the home screen."
        case .ipc: return "Attach to desktop IPC over SSH for faster sync, approvals, and resume. Requires reconnecting the server."
        case .appleWatch: return "Push server, task, and approval state to a paired Apple Watch. Requires the Litter watch app to be installed."
        case .thinkingMinigame: return "Tap the Thinking shimmer while the assistant generates to play a tiny generated minigame."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .realtimeVoice: return true
        case .ipc: return false
        case .thinkingMinigame: return false
        case .appleWatch:
            // Off by default in both Debug and Release. The projection pipeline
            // polls `AppModel.shared.snapshot` every 250ms on the main actor and
            // runs two full `WatchProjection.tasks(...)` sweeps per tick; on an
            // idle home screen that cost ~1.8s of main-thread CPU over a 23s
            // trace (Instruments, 2026-04). Release already had it off to avoid
            // WCSession startup without a companion binary embedded; Debug no
            // longer auto-enables either. Flip in Settings → Experimental
            // Features to test the watch pipeline locally.
            return false
        }
    }
}

@Observable
final class ExperimentalFeatures {
    static let shared = ExperimentalFeatures()

    @ObservationIgnored private let key = "litter.experimentalFeatures"
    private var overrides: [String: Bool]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    private func persistOverrides() {
        UserDefaults.standard.set(overrides, forKey: key)
    }

    func isEnabled(_ feature: LitterFeature) -> Bool {
        overrides[feature.rawValue] ?? feature.defaultEnabled
    }

    func setEnabled(_ feature: LitterFeature, _ value: Bool) {
        var map = overrides
        if value == feature.defaultEnabled {
            map.removeValue(forKey: feature.rawValue)
        } else {
            map[feature.rawValue] = value
        }
        overrides = map
        persistOverrides()
    }

    func ipcSocketPathOverride() -> String? {
        isEnabled(.ipc) ? nil : ""
    }
}
