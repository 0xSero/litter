import Foundation

// ---------------------------------------------------------------------------
// Swift wrapper around the Rust `HandoffManager` via UniFFI.
// ---------------------------------------------------------------------------

/// Thin Swift wrapper around the UniFFI-exported `HandoffManager`.
/// Thread-safe: the Rust side uses a `Mutex` internally.
final class RustHandoffManager: @unchecked Sendable {
    private let manager: HandoffManager

    init(localServerId: String) {
        manager = HandoffManager.create(localServerId: localServerId)
    }

    // MARK: - Server Registry

    func registerServer(serverId: String, name: String, hostname: String, isLocal: Bool, isConnected: Bool) {
        manager.uniffiRegisterServer(serverId: serverId, name: name, hostname: hostname, isLocal: isLocal, isConnected: isConnected)
    }

    // MARK: - Turn Config

    func setTurnConfig(model: String?, effort: String?, fastMode: Bool) {
        manager.uniffiSetTurnConfig(model: model, effort: effort, fastMode: fastMode)
    }

    // MARK: - Handoff Lifecycle

    func handleHandoffRequest(
        handoffId: String,
        voiceServerId: String,
        voiceThreadId: String,
        inputTranscript: String,
        activeTranscript: String,
        serverHint: String?,
        fallbackTranscript: String?
    ) {
        manager.uniffiHandleHandoffRequest(
            handoffId: handoffId,
            voiceServerId: voiceServerId,
            voiceThreadId: voiceThreadId,
            inputTranscript: inputTranscript,
            activeTranscript: activeTranscript,
            serverHint: serverHint,
            fallbackTranscript: fallbackTranscript
        )
    }

    func reportThreadCreated(handoffId: String, serverId: String, threadId: String) {
        manager.uniffiReportThreadCreated(handoffId: handoffId, serverId: serverId, threadId: threadId)
    }

    func reportThreadFailed(handoffId: String, error: String) {
        manager.uniffiReportThreadFailed(handoffId: handoffId, error: error)
    }

    func reportTurnSent(handoffId: String, baseItemCount: Int) {
        manager.uniffiReportTurnSent(handoffId: handoffId, baseItemCount: UInt32(baseItemCount))
    }

    func reportTurnFailed(handoffId: String, error: String) {
        manager.uniffiReportTurnFailed(handoffId: handoffId, error: error)
    }

    func reportFinalized(handoffId: String) {
        manager.uniffiReportFinalized(handoffId: handoffId)
    }

    func reset() {
        manager.uniffiReset()
    }

    // MARK: - Stream Polling

    func pollStreamProgress(handoffId: String, items: [(id: String, text: String)], turnActive: Bool) {
        let streamedItems = items.map { StreamedItem(itemId: $0.id, text: $0.text) }
        manager.uniffiPollStreamProgress(handoffId: handoffId, items: streamedItems, turnActive: turnActive)
    }

    // MARK: - Actions

    func drainActions() -> [HandoffAction] {
        manager.uniffiDrainActions()
    }
}
