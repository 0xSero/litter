use crate::conversation_uniffi::{HydratedConversationItem, HydratedWidgetData};
use crate::types::{AppVoiceHandoffRequest, AppVoiceTranscriptUpdate};
use crate::types::{PendingApproval, PendingUserInputRequest, ThreadKey};

use super::boundary::{AppSessionSummary, AppThreadSnapshot, AppThreadStateRecord};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ThreadStreamingDeltaKind {
    AssistantText,
    ReasoningText,
    PlanText,
    CommandOutput,
    McpProgress,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ThreadStreamingDeltaChunk {
    pub revision: u64,
    pub text: String,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppStoreUpdateRecord {
    FullResync,
    ServerChanged {
        server_id: String,
    },
    ServerRemoved {
        server_id: String,
    },
    ThreadUpserted {
        thread: AppThreadSnapshot,
        session_summary: AppSessionSummary,
        agent_directory_version: u64,
    },
    ThreadMetadataChanged {
        state: AppThreadStateRecord,
        session_summary: AppSessionSummary,
        agent_directory_version: u64,
    },
    ThreadItemChanged {
        key: ThreadKey,
        item: HydratedConversationItem,
        /// Per-item derivation (`last_response_preview`, `last_tool_label`,
        /// `stats`, etc.) computed at the point of the mutation. Lets
        /// platform listeners patch their local `AppSessionSummary` without
        /// another FFI roundtrip or a full snapshot rebuild, so the home
        /// dashboard's zoom-2 meta line stays in sync with streaming items.
        session_summary: AppSessionSummary,
    },
    ThreadStreamingDelta {
        key: ThreadKey,
        item_id: String,
        kind: ThreadStreamingDeltaKind,
        chunks: Vec<ThreadStreamingDeltaChunk>,
    },
    ThreadRemoved {
        key: ThreadKey,
        agent_directory_version: u64,
    },
    ActiveThreadChanged {
        key: Option<ThreadKey>,
    },
    PendingApprovalsChanged {
        approvals: Vec<PendingApproval>,
    },
    PendingUserInputsChanged {
        requests: Vec<PendingUserInputRequest>,
    },
    VoiceSessionChanged,
    /// Emitted whenever the saved-apps on-disk index mutates — the
    /// auto-upsert hook for a finalized `show_widget`, or one of the
    /// handwritten Save-as-App / rename / delete / replace-html /
    /// save-state calls. Payload-free: platforms respond by calling
    /// their existing `SavedAppsStore.reload()` (or equivalent Kotlin
    /// flow) to pull a fresh snapshot. Introduced in R3 to give the
    /// Apps list live reactivity without a separate subscription
    /// surface.
    SavedAppsChanged,
    RealtimeTranscriptUpdated {
        key: ThreadKey,
        update: AppVoiceTranscriptUpdate,
    },
    RealtimeHandoffRequested {
        key: ThreadKey,
        request: AppVoiceHandoffRequest,
    },
    RealtimeSpeechStarted {
        key: ThreadKey,
    },
    RealtimeStarted {
        key: ThreadKey,
        notification: crate::types::AppRealtimeStartedNotification,
    },
    /// One-shot WebRTC answer SDP from the server, to be applied via
    /// `RTCPeerConnection.setRemoteDescription` on the platform. No store
    /// state changes; the shared Rust layer just relays it.
    RealtimeSdp {
        key: ThreadKey,
        notification: crate::types::AppRealtimeSdpNotification,
    },
    RealtimeOutputAudioDelta {
        key: ThreadKey,
        notification: crate::types::AppRealtimeOutputAudioDeltaNotification,
    },
    RealtimeError {
        key: ThreadKey,
        notification: crate::types::AppRealtimeErrorNotification,
    },
    RealtimeClosed {
        key: ThreadKey,
        notification: crate::types::AppRealtimeClosedNotification,
    },
    /// Streaming delta for an in-flight `show_widget` dynamic tool call.
    /// Fires while the model is still emitting the `widget_code` argument.
    /// Platforms push `widget.widget_html` through the existing timeline
    /// widget bubble so the HTML materializes progressively. Guaranteed
    /// `widget.is_finalized == false`; the finalized render arrives via
    /// `ThreadItemChanged` and must win over any late stale deltas.
    DynamicWidgetStreaming {
        key: ThreadKey,
        item_id: String,
        call_id: String,
        widget: HydratedWidgetData,
    },
    /// Any change to the terminal-session snapshot list (open/close/exit
    /// or active id change). Payload-free: subscribers re-read
    /// `AppSnapshot.terminal_sessions` / `active_terminal_id`.
    TerminalSessionsChanged,
}
