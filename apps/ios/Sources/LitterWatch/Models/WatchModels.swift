import Foundation

/// View-model types for the watch experience. Hydrated from the shared Rust
/// `MobileClient` store via WatchConnectivity — see `WatchCompanionBridge`
/// (iOS side) and `WatchSessionBridge` (watch side).
struct WatchTaskStep: Identifiable, Hashable, Codable {
    enum State: String, Hashable, Codable {
        case done, active, pending
    }

    var id = UUID()
    let tool: String
    let arg: String
    let state: State
}

struct WatchApproval: Hashable, Codable, Identifiable {
    /// JSON-RPC request id — echoed back when the user taps allow/deny.
    let id: String
    let command: String
    let target: String
    let diffSummary: String

    enum Kind: String, Codable {
        case command, fileChange, permissions, mcpElicitation
    }
    let kind: Kind
}

struct WatchTranscriptTurn: Identifiable, Hashable, Codable {
    enum Role: String, Hashable, Codable {
        case user, assistant, system
    }
    var id = UUID()
    let role: Role
    let text: String
    let faded: Bool
}

/// One file's worth of unified-diff content surfaced on the watch's diffs
/// screen. The phone trims `diff` to a hard byte budget before shipping so
/// the WatchConnectivity application-context payload stays well under the
/// 256 KB limit even when a task touches many files.
struct WatchFileDiff: Identifiable, Hashable, Codable {
    /// `path` is unique within a task — collapsed to "most recent diff per
    /// file" in the projection, so it doubles as a stable id.
    var id: String { path }
    let path: String
    /// Upstream kind label ("add", "modify", "delete", …); the UI uses this
    /// to pick an icon, not for parsing.
    let kind: String
    let additions: Int
    let deletions: Int
    /// Unified-diff text, possibly tail-truncated with a `…` sentinel line.
    let diff: String
    /// True when the phone trimmed the diff to stay under the size budget.
    /// The watch surfaces this as a small "truncated" hint.
    let truncated: Bool
}

/// A single conversation/thread row — the watch's equivalent of the iPhone
/// sessions list. Every Codex thread the phone knows about becomes a task
/// row. The list is sorted by recent activity.
struct WatchTask: Identifiable, Hashable, Codable {
    enum Status: String, Hashable, Codable {
        case running        // has an active turn
        case needsApproval  // has pending approval
        case idle           // completed, at rest
        case error
    }

    /// "{serverId}:{threadId}" — stable across snapshots.
    let id: String
    let threadId: String
    let serverId: String
    let serverName: String
    /// Thread title; falls back to the first user message if untitled.
    let title: String
    /// Short preview line — usually the most recent assistant turn or
    /// tool call; may be empty.
    let subtitle: String?
    let status: Status
    /// Relative time label — "2m", "1h", "yesterday", etc. Empty when
    /// there is no last-activity timestamp.
    let relativeTime: String
    /// Recent tool call steps (for the detail view). Empty for idle
    /// threads.
    let steps: [WatchTaskStep]
    /// The last few transcript turns of this thread, shipped inline so the
    /// detail/transcript view doesn't need a round-trip to populate.
    let transcript: [WatchTranscriptTurn]
    /// If this task has a pending approval, its request id.
    let pendingApprovalId: String?

    // MARK: - iPhone-parity row enrichment (all optional for back-compat)
    var model: String?
    var cwd: String?
    var turnCount: Int?
    var toolCallCount: Int?
    var diffAdditions: Int?
    var diffDeletions: Int?
    var contextPercent: Int?
    var hasTurnActive: Bool?
    /// Most recent tool the AI is/was running. Set only when the subtitle
    /// is the assistant's reply (so this stays a small secondary chip
    /// instead of duplicating the subtitle text).
    var lastTool: String?
    /// Per-file diffs surfaced by the watch's full diffs screen, ordered
    /// most-recent first and capped by the projection. `nil`/empty when
    /// the task has no file changes yet (or older iPhone builds that
    /// don't ship diffs).
    var diffs: [WatchFileDiff]?
}

/// Slice of realtime voice session state pushed to the watch so it can
/// render the transcript, audio level, and mute state without re-deriving
/// from upstream events.
struct WatchVoiceState: Codable, Hashable {
    enum Mode: String, Codable, Hashable {
        case idle, listening, speaking, thinking, error
    }

    let mode: Mode
    let serverId: String?
    let threadId: String?
    let recentTurns: [WatchTranscriptTurn]
    /// Most recent input level scaled to [0, 1].
    let audioLevel: Double
    let isMuted: Bool
}

/// Resolved theme palette the iPhone pushes to the watch so every screen can
/// reflect the user's selected light/dark theme. Hex strings, "#RRGGBB".
struct WatchThemePayload: Codable, Hashable {
    enum AppearanceMode: String, Codable, Hashable {
        case system, light, dark
    }

    let appearanceMode: AppearanceMode
    /// Phone-resolved colorScheme at push time — already honors `.system`.
    let isDark: Bool

    let accent: String
    let accentStrong: String
    let textPrimary: String
    let textSecondary: String
    let textMuted: String
    let surface: String
    let surfaceLight: String
    let border: String
    let danger: String
    let success: String
    let warning: String
    let textOnAccent: String
    let backgroundTop: String
    let backgroundBottom: String
}

/// Wire-format the iOS app pushes to the watch via `updateApplicationContext`.
struct WatchSnapshotPayload: Codable, Hashable {
    var tasks: [WatchTask]
    var pendingApproval: WatchApproval?
    var voice: WatchVoiceState?
    /// Resolved palette + appearance for the watch UI. Optional so older
    /// iPhone builds (and old persisted snapshots) decode cleanly.
    var theme: WatchThemePayload?
    /// Tasks the user has hidden from home. Optional so older iPhone builds
    /// (and old persisted snapshots) decode cleanly — watch shows no
    /// hidden screen until it sees a non-nil/non-empty list.
    var hiddenTasks: [WatchTask]?
}
