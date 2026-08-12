use std::collections::HashMap;
use std::time::Instant;

use codex_app_server_protocol as upstream;

use crate::conversation_uniffi::HydratedConversationItem;
use crate::types::{
    Account, AgentRuntimeInfo, AgentRuntimeKind, AppModeKind, AppPlanProgressSnapshot, ModelInfo,
    PendingApproval, PendingApprovalKey, PendingApprovalSeed, PendingUserInputKey,
    PendingUserInputRequest, PendingUserInputSeed, RateLimitSnapshot, RateLimits, ThreadInfo,
    ThreadKey,
};
use crate::types::{AppThreadGoal, AppVoiceSessionPhase, AppVoiceTranscriptEntry};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppConnectionStepKind {
    ConnectingToSsh,
    FindingCodex,
    InstallingCodex,
    StartingAppServer,
    OpeningTunnel,
    Connected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppConnectionStepState {
    Pending,
    InProgress,
    Completed,
    Failed,
    AwaitingUserInput,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppConnectionStepSnapshot {
    pub kind: AppConnectionStepKind,
    pub state: AppConnectionStepState,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppConnectionProgressSnapshot {
    pub steps: Vec<AppConnectionStepSnapshot>,
    pub pending_install: bool,
    pub terminal_message: Option<String>,
}

impl AppConnectionProgressSnapshot {
    pub fn ssh_bootstrap() -> Self {
        Self {
            steps: vec![
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::ConnectingToSsh,
                    state: AppConnectionStepState::InProgress,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::FindingCodex,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::InstallingCodex,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::StartingAppServer,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::OpeningTunnel,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::Connected,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
            ],
            pending_install: false,
            terminal_message: None,
        }
    }

    pub fn update_step(
        &mut self,
        kind: AppConnectionStepKind,
        state: AppConnectionStepState,
        detail: Option<String>,
    ) {
        if let Some(step) = self.steps.iter_mut().find(|step| step.kind == kind) {
            step.state = state;
            step.detail = detail;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerHealthSnapshot {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown(String),
}

impl ServerHealthSnapshot {
    pub fn from_wire(health: &str) -> Self {
        match health {
            "disconnected" => Self::Disconnected,
            "connecting" => Self::Connecting,
            "connected" => Self::Connected,
            "unresponsive" => Self::Unresponsive,
            other => Self::Unknown(other.to_string()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppLifecyclePhaseSnapshot {
    Active,
    Inactive,
    Background,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerMutatingCommandKind {
    StartTurn,
    SetQueuedFollowUpsState,
    SteerQueuedFollowUp,
    DeleteQueuedFollowUp,
    ApprovalResponse,
    UserInputResponse,
    CollaborationModeSync,
}

#[derive(Debug, Clone)]
pub struct PendingServerMutatingCommand {
    pub kind: ServerMutatingCommandKind,
    pub thread_id: String,
    pub local_request_id: String,
    pub started_at: Instant,
    pub lifecycle_phase_at_send: AppLifecyclePhaseSnapshot,
}

#[derive(Debug, Clone)]
pub struct ServerTransportDiagnostics {
    pub last_direct_request_ok_at: Option<Instant>,
    pub last_lifecycle_phase: AppLifecyclePhaseSnapshot,
    pub last_lifecycle_transition_at: Option<Instant>,
    pub last_resumed_at: Option<Instant>,
    pub pending_mutation: Option<PendingServerMutatingCommand>,
}

impl Default for ServerTransportDiagnostics {
    fn default() -> Self {
        Self {
            last_direct_request_ok_at: None,
            last_lifecycle_phase: AppLifecyclePhaseSnapshot::Active,
            last_lifecycle_transition_at: None,
            last_resumed_at: None,
            pending_mutation: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServerSnapshot {
    pub server_id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub wake_mac: Option<String>,
    pub is_local: bool,
    pub health: ServerHealthSnapshot,
    pub account: Option<Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<RateLimitSnapshot>,
    pub rate_limits_by_runtime: HashMap<AgentRuntimeKind, RateLimitSnapshot>,
    pub available_models: Option<Vec<ModelInfo>>,
    pub agent_runtimes: Vec<AgentRuntimeInfo>,
    pub connection_progress: Option<AppConnectionProgressSnapshot>,
    pub transport: ServerTransportDiagnostics,
    /// Whether the remote supports `thread/turns/list` + `exclude_turns`.
    /// Defaults to `true` and flips to `false` at runtime if a paginated RPC
    /// comes back as method-not-found or with the legacy embedded-turn shape.
    pub supports_turn_pagination: bool,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct AppVoiceSessionSnapshot {
    pub active_thread: Option<ThreadKey>,
    pub session_id: Option<String>,
    pub phase: Option<AppVoiceSessionPhase>,
    pub last_error: Option<String>,
    pub transcript_entries: Vec<AppVoiceTranscriptEntry>,
    pub handoff_thread_key: Option<ThreadKey>,
}

#[derive(Debug, Clone)]
pub struct ThreadSnapshot {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub agent_runtime_kind: AgentRuntimeKind,
    pub collaboration_mode: AppModeKind,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub effective_approval_policy: Option<crate::types::AppAskForApproval>,
    pub effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    pub items: Vec<HydratedConversationItem>,
    pub local_overlay_items: Vec<HydratedConversationItem>,
    pub queued_follow_ups: Vec<AppQueuedFollowUpPreview>,
    pub(crate) queued_follow_up_drafts: Vec<QueuedFollowUpDraft>,
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<RateLimits>,
    pub realtime_session_id: Option<String>,
    pub goal: Option<AppThreadGoal>,
    pub active_plan_progress: Option<AppPlanProgressSnapshot>,
    pub(crate) pending_plan_implementation_turn_id: Option<String>,
    /// Paginated-turns cursor pointing at the next older page, per
    /// `thread/turns/list` semantics with `sort_direction: Desc`.
    /// `None` means no more older turns on the server OR pagination is not
    /// yet loaded.
    pub older_turns_cursor: Option<String>,
    /// Whether this thread's first page of turns has been loaded into
    /// `items` (either from embedded resume/fork turns on a legacy server,
    /// or from an explicit `thread/turns/list` call on a paginated server).
    /// Gates the UI spinner when a thread is opened with `exclude_turns`.
    pub initial_turns_loaded: bool,
    /// Whether this mobile client has resumed the thread and attached a live
    /// listener during the current store lifetime.
    pub is_resumed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppQueuedFollowUpPreview {
    pub id: String,
    pub kind: AppQueuedFollowUpKind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppQueuedFollowUpKind {
    Message,
    PendingSteer,
    RetryingSteer,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct QueuedFollowUpDraft {
    pub preview: AppQueuedFollowUpPreview,
    pub inputs: Vec<upstream::UserInput>,
    pub source_message_json: Option<serde_json::Value>,
}

impl ThreadSnapshot {
    pub fn from_info(server_id: &str, info: ThreadInfo) -> Self {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: info.id.clone(),
        };
        Self {
            key,
            agent_runtime_kind: "codex".to_string(),
            collaboration_mode: AppModeKind::Default,
            model: info.model.clone(),
            info,
            reasoning_effort: None,
            effective_approval_policy: None,
            effective_sandbox_policy: None,
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: Vec::new(),
            queued_follow_up_drafts: Vec::new(),
            active_turn_id: None,
            context_tokens_used: None,
            model_context_window: None,
            rate_limits: None,
            realtime_session_id: None,
            goal: None,
            active_plan_progress: None,
            pending_plan_implementation_turn_id: None,
            older_turns_cursor: None,
            initial_turns_loaded: false,
            is_resumed: false,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct AppSnapshot {
    pub servers: HashMap<String, ServerSnapshot>,
    pub threads: HashMap<ThreadKey, ThreadSnapshot>,
    pub active_thread: Option<ThreadKey>,
    pub pending_approvals: Vec<PendingApproval>,
    pub(crate) pending_approval_seeds: HashMap<PendingApprovalKey, PendingApprovalSeed>,
    pub pending_user_inputs: Vec<PendingUserInputRequest>,
    pub(crate) pending_user_input_seeds: HashMap<PendingUserInputKey, PendingUserInputSeed>,
    pub voice_session: AppVoiceSessionSnapshot,
    /// Live terminal session snapshots, keyed by session id. Holds the
    /// ring-buffered output tail + lifecycle phase so renderers can
    /// re-attach after view teardown without losing scrollback. The
    /// strong [`crate::terminal::TerminalSession`] handles live on
    /// [`crate::MobileClient::terminal_sessions`]; this snapshot is the
    /// FFI-visible projection.
    pub terminal_sessions: Vec<TerminalSessionSnapshot>,
    /// Id of the currently-focused terminal session, if any. Drives the
    /// "Run in terminal" code-block action via
    /// [`crate::ffi::AppStore::write_to_active_terminal`].
    pub active_terminal_id: Option<String>,
}

/// Lifecycle phase of a terminal session as seen by the store. Maps
/// loosely to the platform-side `TerminalSessionController.Phase`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppTerminalSessionPhase {
    Connecting,
    Running,
    Exited,
    Failed,
}

/// Snapshot of a single terminal session held in the store.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalSessionSnapshot {
    pub id: String,
    pub backend_kind: crate::terminal::TerminalBackendKind,
    pub phase: AppTerminalSessionPhase,
    pub cols: u16,
    pub rows: u16,
    /// Wall-clock milliseconds since `UNIX_EPOCH` of the most recent
    /// activity (output byte or write). Stored as `u64` so the value
    /// crosses the UniFFI boundary without precision loss.
    pub last_activity_ts_ms: u64,
    /// Tail of the output byte stream, capped at 64 KiB (older bytes
    /// dropped as new ones arrive). Used to repaint scrollback when a
    /// renderer re-attaches after view teardown.
    pub output_tail: Vec<u8>,
    /// Exit code if the session has exited. `None` otherwise.
    pub exit_code: Option<i32>,
}
