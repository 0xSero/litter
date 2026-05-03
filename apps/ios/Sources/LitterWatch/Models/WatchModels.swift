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

/// Wire-format the iOS app pushes to the watch via `updateApplicationContext`.
struct WatchSnapshotPayload: Codable, Hashable {
    var tasks: [WatchTask]
    var pendingApproval: WatchApproval?
    var voice: WatchVoiceState?
}

#if DEBUG
/// Minimal fixtures for SwiftUI `#Preview { ... }` blocks only — never
/// referenced from production code paths.
enum WatchPreviewFixtures {
    static let tasks: [WatchTask] = [
        WatchTask(
            id: "macbook-pro:t1",
            threadId: "t1",
            serverId: "macbook-pro",
            serverName: "macbook-pro",
            title: "fix auth token expiry",
            subtitle: "edit_file src/auth.go",
            status: .running,
            relativeTime: "now",
            steps: [
                WatchTaskStep(tool: "read_file", arg: "src/auth.go", state: .done),
                WatchTaskStep(tool: "edit_file", arg: "src/auth.go", state: .active),
                WatchTaskStep(tool: "run_tests", arg: "./...",       state: .pending),
            ],
            transcript: [
                WatchTranscriptTurn(role: .user,      text: "fix auth expiry", faded: false),
                WatchTranscriptTurn(role: .assistant, text: "editing...",      faded: false),
            ],
            pendingApprovalId: nil
        ),
        WatchTask(
            id: "macbook-pro:t2",
            threadId: "t2",
            serverId: "macbook-pro",
            serverName: "macbook-pro",
            title: "refactor session store",
            subtitle: "pushed to feature/session-split",
            status: .idle,
            relativeTime: "12m",
            steps: [],
            transcript: [],
            pendingApprovalId: nil
        ),
        WatchTask(
            id: "studio.lan:t3",
            threadId: "t3",
            serverId: "studio.lan",
            serverName: "studio.lan",
            title: "deploy staging",
            subtitle: "awaiting approval: git push",
            status: .needsApproval,
            relativeTime: "2m",
            steps: [],
            transcript: [],
            pendingApprovalId: "approval-id"
        ),
    ]

    static let approval = WatchApproval(
        id: "preview",
        command: "git push",
        target: "origin/fix-auth-expiry",
        diffSummary: "+12 -3 · 1 file",
        kind: .command
    )

    static let voice = WatchVoiceState(
        mode: .listening,
        serverId: "local",
        threadId: "voice-thread",
        recentTurns: [
            WatchTranscriptTurn(role: .user,      text: "what's on my plate", faded: false),
            WatchTranscriptTurn(role: .assistant, text: "two open threads…",  faded: false),
        ],
        audioLevel: 0.42,
        isMuted: false
    )

    static let transcript: [WatchTranscriptTurn] = [
        WatchTranscriptTurn(role: .user,      text: "fix the auth test",   faded: false),
        WatchTranscriptTurn(role: .assistant, text: "done. tests pass.",   faded: false),
    ]
}
#endif
