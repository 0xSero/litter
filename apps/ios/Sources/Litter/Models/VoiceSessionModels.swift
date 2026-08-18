import Foundation

// MIGRATION: The handoff state tracking (e.g. `handoffRemoteThreadKey`) in
// `VoiceSessionState` is now managed by `RustVoiceHandoffManager` in
// RustVoiceBridge.swift, mirroring the Rust `VoiceHandoffManager`. The UI
// display types (`VoiceSessionPhase`, `VoiceSessionAudioRoute`, display
// helpers, `VoiceActions` protocol) remain iOS-specific. See Task #24.

struct VoiceSessionDebugEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let line: String

    init(id: UUID = UUID(), timestamp: Date = Date(), line: String) {
        self.id = id
        self.timestamp = timestamp
        self.line = line
    }
}

struct VoiceSessionTranscriptEntry: Identifiable, Equatable {
    let id: String
    let speaker: String
    let text: String
    let timestamp: Date
}

enum VoiceSessionPhase: String, Equatable {
    case connecting
    case listening
    case thinking
    case speaking
    case handoff
    case error

    var displayTitle: String {
        switch self {
        case .connecting:
            return "Connecting"
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Codex Speaking"
        case .handoff:
            return "Executing Tools"
        case .error:
            return "Session Ended"
        }
    }

    var activityPhase: CodexVoiceCallAttributes.ContentState.Phase {
        switch self {
        case .connecting: .connecting
        case .listening: .listening
        case .thinking, .handoff: .thinking
        case .speaking: .speaking
        case .error: .error
        }
    }
}

enum VoiceSessionAudioRoute: Equatable {
    case speaker
    case receiver
    case headphones(String)
    case bluetooth(String)
    case airPlay(String)
    case carPlay(String)
    case unknown(String)

    var label: String {
        switch self {
        case .speaker:
            return "Speaker"
        case .receiver:
            return "iPhone"
        case .headphones(let name), .bluetooth(let name), .airPlay(let name),
             .carPlay(let name), .unknown(let name):
            return name
        }
    }

    var supportsSpeakerToggle: Bool {
        switch self {
        case .speaker, .receiver, .unknown:
            return true
        case .headphones, .bluetooth, .airPlay, .carPlay:
            return false
        }
    }

    /// SF Symbol name for the audio route.
    var iconName: String {
        switch self {
        case .speaker:   return "speaker.wave.3.fill"
        case .receiver:  return "phone.fill"
        case .headphones: return "headphones"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .airPlay:   return "airplayaudio"
        case .carPlay:   return "car.fill"
        case .unknown:   return "speaker.wave.2.fill"
        }
    }
}

struct VoiceSessionState: Identifiable, Equatable {
    let threadKey: ThreadKey
    let threadTitle: String
    let model: String
    let startedAt: Date
    var sessionId: String?
    var phase: VoiceSessionPhase
    var lastError: String?
    var route: VoiceSessionAudioRoute
    var transcriptText: String?
    var transcriptSpeaker: String?
    var transcriptLiveMessageID: String?
    var inputLevel: Float
    var outputLevel: Float
    var isListening: Bool
    var isSpeaking: Bool
    var handoffRemoteThreadKey: ThreadKey?
    var transcriptHistory: [VoiceSessionTranscriptEntry]
    var debugEntries: [VoiceSessionDebugEntry]

    var id: String {
        "\(threadKey.serverId):\(threadKey.threadId)"
    }

    var statusText: String {
        if let error = lastError, !error.isEmpty {
            return error
        }
        if let transcriptText,
           !transcriptText.isEmpty,
           let transcriptSpeaker,
           !transcriptSpeaker.isEmpty {
            return "\(transcriptSpeaker): \(transcriptText)"
        }
        return phase.displayTitle
    }

    var activityContentState: CodexVoiceCallAttributes.ContentState {
        CodexVoiceCallAttributes.ContentState(
            phase: phase.activityPhase,
            routeLabel: route.label,
            transcriptText: transcriptText,
            lastError: lastError
        )
    }

    static func initial(threadKey: ThreadKey, threadTitle: String, model: String) -> VoiceSessionState {
        VoiceSessionState(
            threadKey: threadKey,
            threadTitle: threadTitle.isEmpty ? "Voice Session" : threadTitle,
            model: model.isEmpty ? "Codex" : model,
            startedAt: Date(),
            sessionId: nil,
            phase: .connecting,
            lastError: nil,
            route: .speaker,
            transcriptText: nil,
            transcriptSpeaker: nil,
            transcriptLiveMessageID: nil,
            inputLevel: 0,
            outputLevel: 0,
            isListening: false,
            isSpeaking: false,
            handoffRemoteThreadKey: nil,
            transcriptHistory: [],
            debugEntries: []
        )
    }
}

// MARK: - Display Helpers

extension VoiceSessionState {
    /// Standard audio level display scaling factor.
    static let levelScaleFactor: Float = 3.1

    /// Input level scaled for display (0...1).
    var scaledInputLevel: Float {
        min(1, inputLevel * Self.levelScaleFactor)
    }

    /// Output level scaled for display (0...1).
    var scaledOutputLevel: Float {
        min(1, outputLevel * Self.levelScaleFactor)
    }

    /// Truncated transcript suitable for glanceable display (CarPlay, widgets).
    func truncatedTranscript(maxLength: Int = 80) -> String? {
        guard let text = transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text.count > maxLength
            ? String(text.prefix(maxLength)) + "…"
            : text
    }
}

// MARK: - VoiceActions Protocol

/// Actions for controlling a voice session, consumable by any UI layer.
@MainActor
protocol VoiceActions: AnyObject {
    var activeVoiceSession: VoiceSessionState? { get }

    @discardableResult
    func startPinnedLocalVoiceCall(
        cwd: String,
        model: String?,
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) async throws -> ThreadKey

    @discardableResult
    func startVoiceOnThread(_ key: ThreadKey) async throws -> ThreadKey

    func stopActiveVoiceSession() async

    func toggleActiveVoiceSessionSpeaker() async throws
}
