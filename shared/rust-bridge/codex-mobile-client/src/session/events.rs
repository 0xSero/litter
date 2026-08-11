//! Notification routing and event-driven state mutations.
//!
//! Processes upstream typed `ServerNotification` and `ServerRequest` enums
//! from `codex-app-server-protocol` and maps them to high-level `UiEvent`s
//! for platform (iOS/Android) consumption.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use codex_app_server_protocol::{ServerNotification, ServerRequest};
use tokio::sync::broadcast;
use tracing::warn;

use crate::types::AppThreadGoal;
use crate::types::{
    AgentRuntimeKind, ApprovalKind, PendingApproval, PendingApprovalSeed, PendingApprovalWithSeed,
    PendingUserInputOption, PendingUserInputQuestion, PendingUserInputRequest,
    PendingUserInputResponseKind, PendingUserInputSeed, ThreadKey,
};

/// High-level events for platform UI consumption.
///
/// Each variant represents a meaningful state change that the Swift/Kotlin
/// UI layer should react to. These are emitted by the [`EventProcessor`]
/// after processing typed upstream notifications from the server.
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub(crate) enum UiEvent {
    // ── Thread/Turn lifecycle ──────────────────────────────────────────
    ThreadStarted {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadStartedNotification,
    },
    ThreadArchived {
        key: ThreadKey,
    },
    ThreadNameUpdated {
        key: ThreadKey,
        thread_name: Option<String>,
    },
    ThreadStatusChanged {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadStatusChangedNotification,
    },
    ThreadGoalUpdated {
        key: ThreadKey,
        goal: AppThreadGoal,
        turn_id: Option<String>,
    },
    ThreadGoalCleared {
        key: ThreadKey,
    },
    ModelRerouted {
        key: ThreadKey,
        notification: codex_app_server_protocol::ModelReroutedNotification,
    },
    TurnStarted {
        key: ThreadKey,
        turn_id: String,
    },
    TurnCompleted {
        key: ThreadKey,
        turn_id: String,
        error: Option<String>,
    },
    TurnDiffUpdated {
        key: ThreadKey,
        notification: codex_app_server_protocol::TurnDiffUpdatedNotification,
    },
    TurnPlanUpdated {
        key: ThreadKey,
        notification: codex_app_server_protocol::TurnPlanUpdatedNotification,
    },
    /// Progressive patch updates streamed by upstream while a FileChange
    /// item is still applying. Without handling this, diff stats and the
    /// Edit tool-log entry don't appear until ItemCompleted lands at the
    /// end of the patch — see `reducer.rs::UiEvent::FileChangePatchUpdated`
    /// for the upsert path.
    FileChangePatchUpdated {
        key: ThreadKey,
        notification: codex_app_server_protocol::FileChangePatchUpdatedNotification,
    },
    ItemStarted {
        key: ThreadKey,
        notification: codex_app_server_protocol::ItemStartedNotification,
    },
    ItemCompleted {
        key: ThreadKey,
        notification: codex_app_server_protocol::ItemCompletedNotification,
    },
    McpToolCallProgress {
        key: ThreadKey,
        notification: codex_app_server_protocol::McpToolCallProgressNotification,
    },
    ServerRequestResolved {
        key: ThreadKey,
        notification: codex_app_server_protocol::ServerRequestResolvedNotification,
    },

    // ── Streaming deltas ───────────────────────────────────────────────
    MessageDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },
    ReasoningDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },
    PlanDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },
    CommandOutputDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },
    /// Streaming chunk of a `show_widget` (or other client-dynamic-tool)
    /// call's argument JSON. The reducer accumulates deltas in a
    /// per-`(thread, call_id)` buffer, synthesizes a partial
    /// `show_widget` arguments object, re-hydrates it as an in-flight
    /// `DynamicToolCall` item, and emits the update through the existing
    /// `AppStoreUpdateRecord::ThreadItemChanged` path — same shape as
    /// the finalized render, no new variant required.
    DynamicToolCallArgumentsDelta {
        key: ThreadKey,
        item_id: String,
        /// Provider-assigned call id. May be absent on very early deltas
        /// before the provider has confirmed the call id. In that case
        /// the reducer falls back to the item_id as the buffer key.
        call_id: Option<String>,
        delta: String,
    },

    // ── Approvals ──────────────────────────────────────────────────────
    ApprovalRequested {
        key: ThreadKey,
        approval: PendingApprovalWithSeed,
    },
    UserInputRequested {
        request: PendingUserInputRequest,
        seed: Option<PendingUserInputSeed>,
    },

    // ── Account / limits ───────────────────────────────────────────────
    AccountRateLimitsUpdated {
        server_id: String,
        runtime_kind: AgentRuntimeKind,
        notification: codex_app_server_protocol::AccountRateLimitsUpdatedNotification,
    },

    // ── Realtime voice ─────────────────────────────────────────────────
    RealtimeStarted {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadRealtimeStartedNotification,
    },
    RealtimeSdp {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadRealtimeSdpNotification,
    },
    RealtimeItemAdded {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadRealtimeItemAddedNotification,
    },
    RealtimeTranscriptUpdated {
        key: ThreadKey,
        role: String,
        text: String,
    },
    RealtimeOutputAudioDelta {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadRealtimeOutputAudioDeltaNotification,
    },
    RealtimeError {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadRealtimeErrorNotification,
    },
    RealtimeClosed {
        key: ThreadKey,
        notification: codex_app_server_protocol::ThreadRealtimeClosedNotification,
    },

    // ── Errors ─────────────────────────────────────────────────────────
    Error {
        key: Option<ThreadKey>,
        message: String,
        code: Option<i64>,
    },

    // ── Connection ─────────────────────────────────────────────────────
    ConnectionStateChanged {
        server_id: String,
        health: String,
    },

    // ── Context ────────────────────────────────────────────────────────
    ContextTokensUpdated {
        key: ThreadKey,
        used: u64,
        limit: u64,
    },

    // ── Raw notification passthrough ─────────────────────────────────
    /// Notifications not yet handled by the EventProcessor are forwarded
    /// as structured JSON so the platform layer can still process them.
    RawNotification {
        server_id: String,
        method: String,
        params: serde_json::Value,
    },
}

/// Processes upstream typed server notifications/requests and emits high-level [`UiEvent`]s.
///
/// The processor is `Send + Sync` — all mutable state is behind `Arc<Mutex<_>>`.
pub(crate) struct EventProcessor {
    ui_event_tx: broadcast::Sender<UiEvent>,
    pending_approvals: Arc<Mutex<Vec<PendingApproval>>>,
}

impl EventProcessor {
    /// Create a new `EventProcessor` with a default channel capacity of 256.
    pub fn new() -> Self {
        let (ui_event_tx, _) = broadcast::channel(256);
        Self {
            ui_event_tx,
            pending_approvals: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Subscribe to the stream of [`UiEvent`]s.
    pub fn subscribe(&self) -> broadcast::Receiver<UiEvent> {
        self.ui_event_tx.subscribe()
    }

    /// Return a snapshot of all pending approvals.
    #[cfg(test)]
    pub fn pending_approvals(&self) -> Vec<PendingApproval> {
        self.pending_approvals.lock().unwrap().clone()
    }

    /// Remove and return a pending approval by its JSON-RPC request ID.
    ///
    /// Returns `None` if no approval with that ID exists.
    #[cfg(test)]
    pub fn resolve_approval(&self, request_id: &str) -> Option<PendingApproval> {
        let mut approvals = self.pending_approvals.lock().unwrap();
        approvals.iter().position(|a| a.id == request_id).map(|pos| approvals.remove(pos))
    }

    pub fn emit_connection_state(&self, server_id: &str, health: &str) {
        self.emit(UiEvent::ConnectionStateChanged {
            server_id: server_id.to_string(),
            health: health.to_string(),
        });
    }

    // ── Notification processing ────────────────────────────────────────

    /// Process a typed upstream `ServerNotification`.
    ///
    /// Matches on the upstream enum variants (which carry typed payloads),
    /// extracts relevant fields directly, and emits the corresponding
    /// [`UiEvent`] to all subscribers.
    pub fn process_notification(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        notification: &ServerNotification,
    ) {
        match notification {
            // ── Turn lifecycle ──────────────────────────────────────
            ServerNotification::ThreadStarted(n) => {
                let key = Self::make_key(server_id, &n.thread.id);
                self.emit(UiEvent::ThreadStarted {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ThreadArchived(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ThreadArchived { key });
            }
            ServerNotification::ThreadNameUpdated(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ThreadNameUpdated {
                    key,
                    thread_name: n.thread_name.clone(),
                });
            }
            ServerNotification::ThreadStatusChanged(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ThreadStatusChanged {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ThreadGoalUpdated(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ThreadGoalUpdated {
                    key,
                    goal: n.goal.clone().into(),
                    turn_id: n.turn_id.clone(),
                });
            }
            ServerNotification::ThreadGoalCleared(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ThreadGoalCleared { key });
            }
            ServerNotification::ModelRerouted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ModelRerouted {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::TurnStarted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::TurnStarted {
                    key,
                    turn_id: n.turn.id.clone(),
                });
            }
            ServerNotification::TurnCompleted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                let error = n.turn.error.as_ref().map(|e| e.message.clone());
                self.emit(UiEvent::TurnCompleted {
                    key,
                    turn_id: n.turn.id.clone(),
                    error,
                });
            }
            ServerNotification::TurnDiffUpdated(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::TurnDiffUpdated {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::FileChangePatchUpdated(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::FileChangePatchUpdated {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::TurnPlanUpdated(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::TurnPlanUpdated {
                    key,
                    notification: n.clone(),
                });
            }

            // ── Item lifecycle ──────────────────────────────────────
            ServerNotification::ItemStarted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ItemStarted {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ItemCompleted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ItemCompleted {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::McpToolCallProgress(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::McpToolCallProgress {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ServerRequestResolved(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ServerRequestResolved {
                    key,
                    notification: n.clone(),
                });
            }

            // ── Streaming deltas ────────────────────────────────────
            ServerNotification::AgentMessageDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::MessageDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::ReasoningTextDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ReasoningDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::ReasoningSummaryTextDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ReasoningDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::PlanDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::PlanDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::CommandExecutionOutputDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::CommandOutputDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::DynamicToolCallArgumentsDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::DynamicToolCallArgumentsDelta {
                    key,
                    item_id: n.item_id.clone(),
                    call_id: n.call_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::FileChangeOutputDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::CommandOutputDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::AccountRateLimitsUpdated(n) => {
                self.emit(UiEvent::AccountRateLimitsUpdated {
                    server_id: server_id.to_string(),
                    runtime_kind,
                    notification: n.clone(),
                });
            }

            // ── Realtime / voice ────────────────────────────────────
            ServerNotification::ThreadRealtimeStarted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeStarted {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ThreadRealtimeSdp(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeSdp {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ThreadRealtimeItemAdded(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeItemAdded {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ThreadRealtimeTranscriptDone(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeTranscriptUpdated {
                    key,
                    role: n.role.clone(),
                    text: n.text.clone(),
                });
            }
            ServerNotification::ThreadRealtimeTranscriptDelta(_) => {
                // Deltas are consumed via ThreadRealtimeItemAdded by the bridge;
                // the UI currently only needs the finalized text.
            }
            ServerNotification::ThreadRealtimeOutputAudioDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeOutputAudioDelta {
                    key,
                    notification: n.clone(),
                });
            }
            // ── Errors ──────────────────────────────────────────────
            ServerNotification::Error(n) => {
                let key = Some(Self::make_key(server_id, &n.thread_id));
                self.emit(UiEvent::Error {
                    key,
                    message: n.error.message.clone(),
                    code: n.error.codex_error_info.as_ref().map(|_| {
                        // CodexErrorInfo doesn't expose a numeric code directly;
                        // no numeric code from the typed error.
                        0i64
                    }),
                });
            }
            ServerNotification::ThreadRealtimeError(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeError {
                    key,
                    notification: n.clone(),
                });
            }
            ServerNotification::ThreadRealtimeClosed(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeClosed {
                    key,
                    notification: n.clone(),
                });
            }

            // ── Context tokens ──────────────────────────────────────
            ServerNotification::ThreadTokenUsageUpdated(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                let last = &n.token_usage.last;
                let used = (last.input_tokens + last.output_tokens) as u64;
                let limit = n.token_usage.model_context_window.unwrap_or(0) as u64;
                self.emit(UiEvent::ContextTokensUpdated { key, used, limit });
            }
            // ── Everything else: forward as raw JSON ──────────────────
            other => {
                let method = format!("{other}");
                let params = serde_json::to_value(other).unwrap_or_default();
                self.emit(UiEvent::RawNotification {
                    server_id: server_id.to_string(),
                    method,
                    params,
                });
            }
        }
    }

    /// Forward a legacy notification as raw JSON for platform-specific handling.
    pub fn process_legacy_notification(
        &self,
        server_id: &str,
        method: &str,
        params: &serde_json::Value,
    ) {
        if method == "item/tool/requestUserInput"
            && let Some(request) = pending_user_input_request_from_raw(server_id, params) {
                self.emit(UiEvent::UserInputRequested {
                    request,
                    seed: None,
                });
                return;
            }
        self.emit(UiEvent::RawNotification {
            server_id: server_id.to_string(),
            method: method.to_string(),
            params: params.clone(),
        });
    }

    // ── Server request processing ──────────────────────────────────────

    /// Process a typed upstream `ServerRequest` that requires user action.
    ///
    /// Creates a [`PendingApproval`], stores it, and emits
    /// [`UiEvent::ApprovalRequested`] so the platform UI can present it.
    ///
    pub fn process_server_request(&self, server_id: &str, request: &ServerRequest) {
        let (
            kind,
            thread_id,
            turn_id,
            item_id,
            command,
            path,
            grant_root,
            cwd,
            reason,
            request_id,
            raw_params,
        ) = match request {
            ServerRequest::CommandExecutionRequestApproval { request_id, params } => {
                let raw = serde_json::to_value(params).unwrap_or_default();
                (
                    ApprovalKind::Command,
                    Some(params.thread_id.clone()),
                    Some(params.turn_id.clone()),
                    Some(params.item_id.clone()),
                    params.command.clone(),
                    None,
                    None,
                    params.cwd.as_ref().map(|p| p.display().to_string()),
                    params.reason.clone(),
                    request_id,
                    raw,
                )
            }
            ServerRequest::FileChangeRequestApproval { request_id, params } => {
                let raw = serde_json::to_value(params).unwrap_or_default();
                (
                    ApprovalKind::FileChange,
                    Some(params.thread_id.clone()),
                    Some(params.turn_id.clone()),
                    Some(params.item_id.clone()),
                    None,
                    None,
                    params.grant_root.as_ref().map(|p| p.display().to_string()),
                    None,
                    params.reason.clone(),
                    request_id,
                    raw,
                )
            }
            ServerRequest::PermissionsRequestApproval { request_id, params } => {
                let raw = serde_json::to_value(params).unwrap_or_default();
                (
                    ApprovalKind::Permissions,
                    Some(params.thread_id.clone()),
                    Some(params.turn_id.clone()),
                    Some(params.item_id.clone()),
                    None,
                    None,
                    None,
                    None,
                    params.reason.clone(),
                    request_id,
                    raw,
                )
            }
            ServerRequest::McpServerElicitationRequest { request_id, params } => {
                if let Some((request, seed)) =
                    mcp_elicitation_user_input_request_from_upstream(server_id, request_id, params)
                {
                    self.emit(UiEvent::UserInputRequested {
                        request,
                        seed: Some(seed),
                    });
                }
                return;
            }
            ServerRequest::ToolRequestUserInput { request_id, params } => {
                if let Some(request) =
                    pending_user_input_request_from_upstream(server_id, request_id, params)
                {
                    self.emit(UiEvent::UserInputRequested {
                        request,
                        seed: Some(PendingUserInputSeed {
                            request_id: request_id.clone(),
                            response_kind: PendingUserInputResponseKind::ToolRequestUserInput,
                            raw_params: serde_json::to_value(params).unwrap_or_default(),
                        }),
                    });
                }
                return;
            }
            ServerRequest::DynamicToolCall { request_id, params } => {
                self.emit_raw_server_request(server_id, "item/tool/call", request_id, params);
                return;
            }
            ServerRequest::ChatgptAuthTokensRefresh { request_id, params } => {
                self.emit_raw_server_request(
                    server_id,
                    "account/chatgptAuthTokens/refresh",
                    request_id,
                    params,
                );
                return;
            }
            other => {
                warn!(
                    method = ?other,
                    "unknown/unhandled server request type — ignoring"
                );
                return;
            }
        };

        let id = request_id_to_string(request_id);
        let approval = PendingApproval {
            id,
            server_id: server_id.to_string(),
            kind,
            thread_id: thread_id.clone(),
            turn_id,
            item_id,
            command,
            path,
            grant_root,
            cwd,
            reason,
        };

        // Store the approval.
        self.pending_approvals
            .lock()
            .unwrap()
            .push(approval.clone());

        // Build the thread key (best-effort).
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.unwrap_or_default(),
        };

        self.emit(UiEvent::ApprovalRequested {
            key,
            approval: PendingApprovalWithSeed {
                approval,
                seed: PendingApprovalSeed {
                    request_id: request_id.clone(),
                    raw_params,
                },
            },
        });
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    fn emit(&self, event: UiEvent) {
        // Ignore the error — it just means there are no active subscribers.
        let _ = self.ui_event_tx.send(event);
    }

    fn emit_raw_server_request<T: serde::Serialize>(
        &self,
        server_id: &str,
        method: &str,
        request_id: &codex_app_server_protocol::RequestId,
        params: &T,
    ) {
        let params = serde_json::json!({
            "requestId": request_id_to_string(request_id),
            "params": params,
        });
        self.emit(UiEvent::RawNotification {
            server_id: server_id.to_string(),
            method: method.to_string(),
            params,
        });
    }

    fn make_key(server_id: &str, thread_id: &str) -> ThreadKey {
        ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        }
    }
}

impl Default for EventProcessor {
    fn default() -> Self {
        Self::new()
    }
}

fn request_id_to_string(request_id: &codex_app_server_protocol::RequestId) -> String {
    match request_id {
        codex_app_server_protocol::RequestId::String(value) => value.clone(),
        codex_app_server_protocol::RequestId::Integer(value) => value.to_string(),
    }
}

pub(crate) fn sanitize_pending_user_input_questions(
    questions: Vec<PendingUserInputQuestion>,
) -> Vec<PendingUserInputQuestion> {
    let mut seen_ids = HashSet::new();
    questions
        .into_iter()
        .enumerate()
        .map(|(index, mut question)| {
            let requested_id = question.id.trim();
            let base_id = if requested_id.is_empty() {
                format!("question-{}", index + 1)
            } else {
                requested_id.to_string()
            };
            let mut candidate = base_id.clone();
            let mut suffix = 2usize;
            while !seen_ids.insert(candidate.clone()) {
                candidate = format!("{base_id}-{suffix}");
                suffix += 1;
            }
            question.id = candidate;
            question
        })
        .collect()
}

const MCP_APPROVAL_FIELD_ID: &str = "__approval";
const MCP_URL_ACTION_FIELD_ID: &str = "__url_action";
const MCP_APPROVAL_ACCEPT_ONCE_LABEL: &str = "Allow";
const MCP_APPROVAL_ACCEPT_SESSION_LABEL: &str = "Allow for this session";
const MCP_APPROVAL_ACCEPT_ALWAYS_LABEL: &str = "Always allow";
const MCP_APPROVAL_DECLINE_LABEL: &str = "Deny";
const MCP_APPROVAL_CANCEL_LABEL: &str = "Cancel";
const MCP_URL_FINISHED_LABEL: &str = "I finished";

fn pending_user_input_request_from_upstream(
    server_id: &str,
    request_id: &codex_app_server_protocol::RequestId,
    params: &codex_app_server_protocol::ToolRequestUserInputParams,
) -> Option<PendingUserInputRequest> {
    let questions = sanitize_pending_user_input_questions(
        params
            .questions
            .iter()
            .map(|question| PendingUserInputQuestion {
                id: question.id.clone(),
                header: Some(question.header.clone()).filter(|header| !header.is_empty()),
                question: question.question.clone(),
                is_other_allowed: question.is_other,
                is_secret: question.is_secret,
                options: question
                    .options
                    .clone()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|option| PendingUserInputOption {
                        label: option.label,
                        description: Some(option.description).filter(|value| !value.is_empty()),
                    })
                    .collect(),
            })
            .collect::<Vec<_>>(),
    );

    if questions.is_empty() {
        return None;
    }

    Some(PendingUserInputRequest {
        id: request_id_to_string(request_id),
        server_id: server_id.to_string(),
        thread_id: params.thread_id.clone(),
        turn_id: params.turn_id.clone(),
        item_id: params.item_id.clone(),
        questions,
        requester_agent_nickname: None,
        requester_agent_role: None,
    })
}

fn mcp_elicitation_user_input_request_from_upstream(
    server_id: &str,
    request_id: &codex_app_server_protocol::RequestId,
    params: &codex_app_server_protocol::McpServerElicitationRequestParams,
) -> Option<(PendingUserInputRequest, PendingUserInputSeed)> {
    let request_id_string = request_id_to_string(request_id);
    let questions = sanitize_pending_user_input_questions(mcp_elicitation_questions(params));
    if questions.is_empty() {
        return None;
    }

    let request = PendingUserInputRequest {
        id: request_id_string.clone(),
        server_id: server_id.to_string(),
        thread_id: params.thread_id.clone(),
        turn_id: params.turn_id.clone().unwrap_or_default(),
        item_id: format!("mcp-elicitation:{request_id_string}"),
        questions,
        requester_agent_nickname: None,
        requester_agent_role: None,
    };
    let seed = PendingUserInputSeed {
        request_id: request_id.clone(),
        response_kind: PendingUserInputResponseKind::McpServerElicitation,
        raw_params: serde_json::to_value(params).unwrap_or_default(),
    };
    Some((request, seed))
}

fn mcp_elicitation_questions(
    params: &codex_app_server_protocol::McpServerElicitationRequestParams,
) -> Vec<PendingUserInputQuestion> {
    match &params.request {
        codex_app_server_protocol::McpServerElicitationRequest::Form {
            meta,
            message,
            requested_schema,
        } => {
            if requested_schema.properties.is_empty() {
                return vec![mcp_approval_action_question(
                    message,
                    meta.as_ref(),
                    &params.server_name,
                )];
            }

            let mut questions = requested_schema
                .properties
                .iter()
                .filter_map(|(id, schema)| mcp_schema_question(id, schema))
                .collect::<Vec<_>>();
            if questions.is_empty() {
                return vec![mcp_approval_action_question(
                    message,
                    meta.as_ref(),
                    &params.server_name,
                )];
            }
            if let Some(first) = questions.first_mut() {
                let message = message.trim();
                if !message.is_empty() && first.question.trim() != message {
                    first.question = format!("{message}\n\n{}", first.question);
                }
            }
            questions
        }
        codex_app_server_protocol::McpServerElicitationRequest::Url { message, url, .. } => {
            let prompt = if message.trim().is_empty() {
                url.clone()
            } else {
                format!("{}\n\n{}", message.trim(), url)
            };
            vec![PendingUserInputQuestion {
                id: MCP_URL_ACTION_FIELD_ID.to_string(),
                header: Some(format!("MCP: {}", params.server_name)),
                question: prompt,
                is_other_allowed: false,
                is_secret: false,
                options: vec![
                    PendingUserInputOption {
                        label: MCP_URL_FINISHED_LABEL.to_string(),
                        description: Some(
                            "Resolve the request after completing the browser action.".to_string(),
                        ),
                    },
                    PendingUserInputOption {
                        label: MCP_APPROVAL_CANCEL_LABEL.to_string(),
                        description: Some("Cancel this request.".to_string()),
                    },
                ],
            }]
        }
    }
}

fn mcp_approval_action_question(
    message: &str,
    meta: Option<&serde_json::Value>,
    server_name: &str,
) -> PendingUserInputQuestion {
    let mut options = vec![PendingUserInputOption {
        label: MCP_APPROVAL_ACCEPT_ONCE_LABEL.to_string(),
        description: Some("Allow this request and continue.".to_string()),
    }];
    if mcp_approval_supports_persist_mode(meta, codex_protocol::mcp_approval_meta::PERSIST_SESSION)
    {
        options.push(PendingUserInputOption {
            label: MCP_APPROVAL_ACCEPT_SESSION_LABEL.to_string(),
            description: Some(
                "Allow this request and remember this choice for this session.".to_string(),
            ),
        });
    }
    if mcp_approval_supports_persist_mode(meta, codex_protocol::mcp_approval_meta::PERSIST_ALWAYS) {
        options.push(PendingUserInputOption {
            label: MCP_APPROVAL_ACCEPT_ALWAYS_LABEL.to_string(),
            description: Some(
                "Allow this request and remember this choice for future requests.".to_string(),
            ),
        });
    }
    options.push(PendingUserInputOption {
        label: MCP_APPROVAL_DECLINE_LABEL.to_string(),
        description: Some("Decline this request and continue.".to_string()),
    });
    options.push(PendingUserInputOption {
        label: MCP_APPROVAL_CANCEL_LABEL.to_string(),
        description: Some("Cancel this request.".to_string()),
    });

    PendingUserInputQuestion {
        id: MCP_APPROVAL_FIELD_ID.to_string(),
        header: Some(format!("MCP: {server_name}")),
        question: if message.trim().is_empty() {
            "Allow this MCP request?".to_string()
        } else {
            message.trim().to_string()
        },
        is_other_allowed: false,
        is_secret: false,
        options,
    }
}

fn mcp_approval_supports_persist_mode(
    meta: Option<&serde_json::Value>,
    expected_mode: &str,
) -> bool {
    let Some(persist) = meta
        .and_then(serde_json::Value::as_object)
        .and_then(|meta| meta.get(codex_protocol::mcp_approval_meta::PERSIST_KEY))
    else {
        return false;
    };

    match persist {
        serde_json::Value::String(value) => value == expected_mode,
        serde_json::Value::Array(values) => values
            .iter()
            .filter_map(serde_json::Value::as_str)
            .any(|value| value == expected_mode),
        _ => false,
    }
}

fn mcp_schema_question(
    id: &str,
    schema: &codex_app_server_protocol::McpElicitationPrimitiveSchema,
) -> Option<PendingUserInputQuestion> {
    match schema {
        codex_app_server_protocol::McpElicitationPrimitiveSchema::String(schema) => {
            let title = schema.title.clone().unwrap_or_else(|| id.to_string());
            Some(PendingUserInputQuestion {
                id: id.to_string(),
                header: Some(title.clone()),
                question: schema.description.clone().unwrap_or(title),
                is_other_allowed: true,
                is_secret: false,
                options: Vec::new(),
            })
        }
        codex_app_server_protocol::McpElicitationPrimitiveSchema::Number(schema) => {
            let title = schema.title.clone().unwrap_or_else(|| id.to_string());
            Some(PendingUserInputQuestion {
                id: id.to_string(),
                header: Some(title.clone()),
                question: schema.description.clone().unwrap_or(title),
                is_other_allowed: true,
                is_secret: false,
                options: Vec::new(),
            })
        }
        codex_app_server_protocol::McpElicitationPrimitiveSchema::Boolean(schema) => {
            let title = schema.title.clone().unwrap_or_else(|| id.to_string());
            Some(PendingUserInputQuestion {
                id: id.to_string(),
                header: Some(title.clone()),
                question: schema.description.clone().unwrap_or(title),
                is_other_allowed: false,
                is_secret: false,
                options: vec![
                    PendingUserInputOption {
                        label: "True".to_string(),
                        description: None,
                    },
                    PendingUserInputOption {
                        label: "False".to_string(),
                        description: None,
                    },
                ],
            })
        }
        codex_app_server_protocol::McpElicitationPrimitiveSchema::Enum(schema) => {
            mcp_enum_question(id, schema)
        }
    }
}

fn mcp_enum_question(
    id: &str,
    schema: &codex_app_server_protocol::McpElicitationEnumSchema,
) -> Option<PendingUserInputQuestion> {
    match schema {
        codex_app_server_protocol::McpElicitationEnumSchema::Legacy(schema) => {
            let title = schema.title.clone().unwrap_or_else(|| id.to_string());
            let enum_names = schema.enum_names.clone().unwrap_or_default();
            Some(PendingUserInputQuestion {
                id: id.to_string(),
                header: Some(title.clone()),
                question: schema.description.clone().unwrap_or(title),
                is_other_allowed: false,
                is_secret: false,
                options: schema
                    .enum_
                    .iter()
                    .enumerate()
                    .map(|(index, value)| PendingUserInputOption {
                        label: enum_names
                            .get(index)
                            .cloned()
                            .unwrap_or_else(|| value.clone()),
                        description: None,
                    })
                    .collect(),
            })
        }
        codex_app_server_protocol::McpElicitationEnumSchema::SingleSelect(schema) => match schema {
            codex_app_server_protocol::McpElicitationSingleSelectEnumSchema::Untitled(schema) => {
                let title = schema.title.clone().unwrap_or_else(|| id.to_string());
                Some(PendingUserInputQuestion {
                    id: id.to_string(),
                    header: Some(title.clone()),
                    question: schema.description.clone().unwrap_or(title),
                    is_other_allowed: false,
                    is_secret: false,
                    options: schema
                        .enum_
                        .iter()
                        .map(|value| PendingUserInputOption {
                            label: value.clone(),
                            description: None,
                        })
                        .collect(),
                })
            }
            codex_app_server_protocol::McpElicitationSingleSelectEnumSchema::Titled(schema) => {
                let title = schema.title.clone().unwrap_or_else(|| id.to_string());
                Some(PendingUserInputQuestion {
                    id: id.to_string(),
                    header: Some(title.clone()),
                    question: schema.description.clone().unwrap_or(title),
                    is_other_allowed: false,
                    is_secret: false,
                    options: schema
                        .one_of
                        .iter()
                        .map(|entry| PendingUserInputOption {
                            label: entry.title.clone(),
                            description: None,
                        })
                        .collect(),
                })
            }
        },
        codex_app_server_protocol::McpElicitationEnumSchema::MultiSelect(schema) => {
            let (title, description, options) = match schema {
                codex_app_server_protocol::McpElicitationMultiSelectEnumSchema::Untitled(
                    schema,
                ) => (
                    schema.title.clone().unwrap_or_else(|| id.to_string()),
                    schema.description.clone(),
                    schema
                        .items
                        .enum_
                        .iter()
                        .map(|value| PendingUserInputOption {
                            label: value.clone(),
                            description: None,
                        })
                        .collect::<Vec<_>>(),
                ),
                codex_app_server_protocol::McpElicitationMultiSelectEnumSchema::Titled(schema) => (
                    schema.title.clone().unwrap_or_else(|| id.to_string()),
                    schema.description.clone(),
                    schema
                        .items
                        .any_of
                        .iter()
                        .map(|entry| PendingUserInputOption {
                            label: entry.title.clone(),
                            description: None,
                        })
                        .collect::<Vec<_>>(),
                ),
            };
            Some(PendingUserInputQuestion {
                id: id.to_string(),
                header: Some(title.clone()),
                question: description.unwrap_or(title),
                is_other_allowed: false,
                is_secret: false,
                options,
            })
        }
    }
}

fn pending_user_input_request_from_raw(
    server_id: &str,
    payload: &serde_json::Value,
) -> Option<PendingUserInputRequest> {
    let request_id = match payload.get("requestId")? {
        serde_json::Value::String(value) => value.clone(),
        serde_json::Value::Number(value) => value.to_string(),
        _ => return None,
    };
    let params = payload.get("params")?;
    let params: codex_app_server_protocol::ToolRequestUserInputParams =
        serde_json::from_value(params.clone()).ok()?;
    let questions = sanitize_pending_user_input_questions(
        params
            .questions
            .iter()
            .map(|question| PendingUserInputQuestion {
                id: question.id.clone(),
                header: Some(question.header.clone()).filter(|header| !header.is_empty()),
                question: question.question.clone(),
                is_other_allowed: question.is_other,
                is_secret: question.is_secret,
                options: question
                    .options
                    .clone()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|option| PendingUserInputOption {
                        label: option.label,
                        description: Some(option.description).filter(|value| !value.is_empty()),
                    })
                    .collect(),
            })
            .collect::<Vec<_>>(),
    );

    if questions.is_empty() {
        return None;
    }

    Some(PendingUserInputRequest {
        id: request_id,
        server_id: server_id.to_string(),
        thread_id: params.thread_id,
        turn_id: params.turn_id,
        item_id: params.item_id,
        questions,
        requester_agent_nickname: None,
        requester_agent_role: None,
    })
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_protocol::{self as proto};
    use serde_json::json;

    fn test_abs_path(path: &str) -> codex_utils_absolute_path::AbsolutePathBuf {
        codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path_checked(path)
            .expect("test path must be absolute")
    }

    /// Helper: create processor, subscribe, process notification, return received event.
    fn process_and_recv(server_id: &str, notification: &ServerNotification) -> Option<UiEvent> {
        let proc = EventProcessor::new();
        let mut rx = proc.subscribe();
        proc.process_notification(server_id, "codex".to_string(), notification);
        rx.try_recv().ok()
    }

    /// Helper: create processor, subscribe, process server request, return received event.
    fn request_and_recv(server_id: &str, request: &ServerRequest) -> Option<UiEvent> {
        let proc = EventProcessor::new();
        let mut rx = proc.subscribe();
        proc.process_server_request(server_id, request);
        rx.try_recv().ok()
    }

    fn make_turn(id: &str) -> proto::Turn {
        proto::Turn {
            id: id.to_string(),
            items: Vec::new(),
            items_view: proto::TurnItemsView::Full,
            status: proto::TurnStatus::Completed,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        }
    }

    fn make_item(id: &str) -> proto::ThreadItem {
        proto::ThreadItem::AgentMessage {
            id: id.to_string(),
            text: String::new(),
            phase: None,
            memory_citation: None,
        }
    }

    fn upstream_item_id(item: &proto::ThreadItem) -> &str {
        match item {
            proto::ThreadItem::UserMessage { id, .. }
            | proto::ThreadItem::HookPrompt { id, .. }
            | proto::ThreadItem::AgentMessage { id, .. }
            | proto::ThreadItem::Plan { id, .. }
            | proto::ThreadItem::Reasoning { id, .. }
            | proto::ThreadItem::CommandExecution { id, .. }
            | proto::ThreadItem::FileChange { id, .. }
            | proto::ThreadItem::McpToolCall { id, .. }
            | proto::ThreadItem::DynamicToolCall { id, .. }
            | proto::ThreadItem::CollabAgentToolCall { id, .. }
            | proto::ThreadItem::WebSearch { id, .. }
            | proto::ThreadItem::ImageView { id, .. }
            | proto::ThreadItem::ImageGeneration { id, .. }
            | proto::ThreadItem::EnteredReviewMode { id, .. }
            | proto::ThreadItem::ExitedReviewMode { id, .. }
            | proto::ThreadItem::ContextCompaction { id, .. } => id,
        }
    }

    // ── EventProcessor basics ──────────────────────────────────────────

    #[test]
    fn new_processor_has_no_pending_approvals() {
        let proc = EventProcessor::new();
        assert!(proc.pending_approvals().is_empty());
    }

    #[test]
    fn default_creates_same_as_new() {
        let proc = EventProcessor::default();
        assert!(proc.pending_approvals().is_empty());
    }

    #[test]
    fn subscribe_returns_receiver() {
        let proc = EventProcessor::new();
        let _rx = proc.subscribe();
    }

    // ── Turn lifecycle ─────────────────────────────────────────────────

    #[test]
    fn thread_started() {
        let notification = ServerNotification::ThreadStarted(proto::ThreadStartedNotification {
            thread: proto::Thread {
                id: "thr_1".to_string(),
                session_id: "session_1".to_string(),
                forked_from_id: None,
                preview: "Preview".to_string(),
                ephemeral: false,
                model_provider: "openai".to_string(),
                created_at: 1,
                updated_at: 2,
                status: proto::ThreadStatus::Idle,
                path: None,
                cwd: test_abs_path("/tmp"),
                cli_version: "1.0.0".to_string(),
                source: proto::SessionSource::Cli,
                thread_source: None,
                agent_nickname: Some("builder".to_string()),
                agent_role: Some("worker".to_string()),
                git_info: None,
                name: Some("Example".to_string()),
                turns: Vec::new(),
            },
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::ThreadStarted { key, notification } => {
                assert_eq!(key.server_id, "srv1");
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread.id, "thr_1");
                assert_eq!(
                    notification.thread.agent_nickname.as_deref(),
                    Some("builder")
                );
            }
            other => panic!("expected ThreadStarted, got {other:?}"),
        }
    }

    #[test]
    fn thread_status_changed() {
        let notification =
            ServerNotification::ThreadStatusChanged(proto::ThreadStatusChangedNotification {
                thread_id: "thr_1".to_string(),
                status: proto::ThreadStatus::Active {
                    active_flags: vec![],
                },
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::ThreadStatusChanged { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(
                    notification.status,
                    proto::ThreadStatus::Active {
                        active_flags: vec![]
                    }
                );
            }
            other => panic!("expected ThreadStatusChanged, got {other:?}"),
        }
    }

    #[test]
    fn turn_started() {
        let notification = ServerNotification::TurnStarted(proto::TurnStartedNotification {
            thread_id: "thr_1".to_string(),
            turn: make_turn("turn_1"),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::TurnStarted { key, turn_id } => {
                assert_eq!(key.server_id, "srv1");
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(turn_id, "turn_1");
            }
            other => panic!("expected TurnStarted, got {other:?}"),
        }
    }

    #[test]
    fn turn_completed() {
        let notification = ServerNotification::TurnCompleted(proto::TurnCompletedNotification {
            thread_id: "thr_2".to_string(),
            turn: make_turn("turn_2"),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::TurnCompleted {
                key,
                turn_id,
                error,
            } => {
                assert_eq!(key.thread_id, "thr_2");
                assert_eq!(turn_id, "turn_2");
                assert!(error.is_none());
            }
            other => panic!("expected TurnCompleted, got {other:?}"),
        }
    }

    #[test]
    fn turn_diff_updated() {
        let notification =
            ServerNotification::TurnDiffUpdated(proto::TurnDiffUpdatedNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                diff: "--- a\n+++ b".to_string(),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::TurnDiffUpdated { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.turn_id, "turn_1");
                assert_eq!(notification.diff, "--- a\n+++ b");
            }
            other => panic!("expected TurnDiffUpdated, got {other:?}"),
        }
    }

    #[test]
    fn turn_plan_updated() {
        let notification =
            ServerNotification::TurnPlanUpdated(proto::TurnPlanUpdatedNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                explanation: Some("work".to_string()),
                plan: vec![proto::TurnPlanStep {
                    step: "Inspect".to_string(),
                    status: proto::TurnPlanStepStatus::InProgress,
                }],
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::TurnPlanUpdated { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.turn_id, "turn_1");
                assert_eq!(notification.plan.len(), 1);
                assert_eq!(
                    notification.plan[0].status,
                    proto::TurnPlanStepStatus::InProgress
                );
            }
            other => panic!("expected TurnPlanUpdated, got {other:?}"),
        }
    }

    // ── Item lifecycle ─────────────────────────────────────────────────

    #[test]
    fn item_started() {
        let notification = ServerNotification::ItemStarted(proto::ItemStartedNotification {
            thread_id: "thr_1".to_string(),
            turn_id: "turn_1".to_string(),
            item: make_item("item_1"),
            started_at_ms: 0,
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ItemStarted { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.turn_id, "turn_1");
                assert_eq!(upstream_item_id(&notification.item), "item_1");
            }
            other => panic!("expected ItemStarted, got {other:?}"),
        }
    }

    #[test]
    fn item_completed() {
        let notification = ServerNotification::ItemCompleted(proto::ItemCompletedNotification {
            thread_id: "thr_1".to_string(),
            turn_id: "turn_1".to_string(),
            item: make_item("item_2"),
            completed_at_ms: 0,
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ItemCompleted { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.turn_id, "turn_1");
                assert_eq!(upstream_item_id(&notification.item), "item_2");
            }
            other => panic!("expected ItemCompleted, got {other:?}"),
        }
    }

    #[test]
    fn mcp_tool_call_progress() {
        let notification =
            ServerNotification::McpToolCallProgress(proto::McpToolCallProgressNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                message: "halfway".to_string(),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::McpToolCallProgress { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.item_id, "item_1");
                assert_eq!(notification.message, "halfway");
            }
            other => panic!("expected McpToolCallProgress, got {other:?}"),
        }
    }

    #[test]
    fn server_request_resolved() {
        let notification =
            ServerNotification::ServerRequestResolved(proto::ServerRequestResolvedNotification {
                thread_id: "thr_1".to_string(),
                request_id: proto::RequestId::Integer(7),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ServerRequestResolved { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.request_id, proto::RequestId::Integer(7));
            }
            other => panic!("expected ServerRequestResolved, got {other:?}"),
        }
    }

    // ── Streaming deltas ───────────────────────────────────────────────

    #[test]
    fn agent_message_delta() {
        let notification =
            ServerNotification::AgentMessageDelta(proto::AgentMessageDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "Hello ".to_string(),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::MessageDelta {
                key,
                item_id,
                delta,
            } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(item_id, "item_1");
                assert_eq!(delta, "Hello ");
            }
            other => panic!("expected MessageDelta, got {other:?}"),
        }
    }

    #[test]
    fn reasoning_text_delta() {
        let notification =
            ServerNotification::ReasoningTextDelta(proto::ReasoningTextDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "thinking...".to_string(),
                content_index: 0,
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ReasoningDelta { delta, .. } => {
                assert_eq!(delta, "thinking...");
            }
            other => panic!("expected ReasoningDelta, got {other:?}"),
        }
    }

    #[test]
    fn reasoning_summary_text_delta() {
        let notification = ServerNotification::ReasoningSummaryTextDelta(
            proto::ReasoningSummaryTextDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "summary...".to_string(),
                summary_index: 0,
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ReasoningDelta { delta, .. } => {
                assert_eq!(delta, "summary...");
            }
            other => panic!("expected ReasoningDelta, got {other:?}"),
        }
    }

    #[test]
    fn plan_delta() {
        let notification = ServerNotification::PlanDelta(proto::PlanDeltaNotification {
            thread_id: "thr_1".to_string(),
            turn_id: "turn_1".to_string(),
            item_id: "item_1".to_string(),
            delta: "step 1".to_string(),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::PlanDelta { delta, .. } => {
                assert_eq!(delta, "step 1");
            }
            other => panic!("expected PlanDelta, got {other:?}"),
        }
    }

    #[test]
    fn command_execution_output_delta() {
        let notification = ServerNotification::CommandExecutionOutputDelta(
            proto::CommandExecutionOutputDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "output".to_string(),
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::CommandOutputDelta { delta, .. } => {
                assert_eq!(delta, "output");
            }
            other => panic!("expected CommandOutputDelta, got {other:?}"),
        }
    }

    // ── Realtime / voice ───────────────────────────────────────────────

    #[test]
    fn realtime_started() {
        let notification =
            ServerNotification::ThreadRealtimeStarted(proto::ThreadRealtimeStartedNotification {
                thread_id: "thr_1".to_string(),
                realtime_session_id: Some("sess_abc".to_string()),
                version: codex_protocol::protocol::RealtimeConversationVersion::V2,
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeStarted { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(
                    notification.realtime_session_id.as_deref(),
                    Some("sess_abc")
                );
            }
            other => panic!("expected RealtimeStarted, got {other:?}"),
        }
    }

    #[test]
    fn realtime_item_added() {
        let item_val = json!({"type": "message", "role": "assistant"});
        let notification = ServerNotification::ThreadRealtimeItemAdded(
            proto::ThreadRealtimeItemAddedNotification {
                thread_id: "thr_1".to_string(),
                item: item_val.clone(),
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeItemAdded { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                let parsed = serde_json::to_value(&notification.item).unwrap();
                assert_eq!(parsed["type"], "message");
            }
            other => panic!("expected RealtimeItemAdded, got {other:?}"),
        }
    }

    #[test]
    fn realtime_audio_delta() {
        let notification = ServerNotification::ThreadRealtimeOutputAudioDelta(
            proto::ThreadRealtimeOutputAudioDeltaNotification {
                thread_id: "thr_1".to_string(),
                audio: proto::ThreadRealtimeAudioChunk {
                    data: "base64audio==".to_string(),
                    sample_rate: 24000,
                    num_channels: 1,
                    samples_per_channel: None,
                    item_id: None,
                },
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeOutputAudioDelta { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.audio.data, "base64audio==");
            }
            other => panic!("expected RealtimeOutputAudioDelta, got {other:?}"),
        }
    }

    // ── Errors ─────────────────────────────────────────────────────────

    #[test]
    fn error_notification() {
        let notification = ServerNotification::Error(proto::ErrorNotification {
            error: proto::TurnError {
                message: "rate limited".to_string(),
                codex_error_info: None,
                additional_details: None,
            },
            will_retry: false,
            thread_id: String::new(),
            turn_id: String::new(),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::Error { message, .. } => {
                assert_eq!(message, "rate limited");
            }
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn error_notification_with_thread() {
        let notification = ServerNotification::Error(proto::ErrorNotification {
            error: proto::TurnError {
                message: "oops".to_string(),
                codex_error_info: None,
                additional_details: None,
            },
            will_retry: false,
            thread_id: "thr_1".to_string(),
            turn_id: String::new(),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::Error { key, message, .. } => {
                assert_eq!(key.as_ref().unwrap().thread_id, "thr_1");
                assert_eq!(message, "oops");
            }
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn realtime_sdp_emits_typed_event() {
        let notification =
            ServerNotification::ThreadRealtimeSdp(proto::ThreadRealtimeSdpNotification {
                thread_id: "thr_1".to_string(),
                sdp: "v=0\r\no=- 42 2 IN IP4 0.0.0.0\r\n...".to_string(),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeSdp { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert!(notification.sdp.starts_with("v=0"));
            }
            other => panic!("expected RealtimeSdp, got {other:?}"),
        }
    }

    #[test]
    fn realtime_error_emits_typed_event() {
        let notification =
            ServerNotification::ThreadRealtimeError(proto::ThreadRealtimeErrorNotification {
                thread_id: "thr_1".to_string(),
                message: "voice error".to_string(),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeError { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.message, "voice error");
            }
            other => panic!("expected RealtimeError, got {other:?}"),
        }
    }

    // ── Context tokens ─────────────────────────────────────────────────

    #[test]
    fn thread_token_usage_updated() {
        let notification = ServerNotification::ThreadTokenUsageUpdated(
            proto::ThreadTokenUsageUpdatedNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                token_usage: proto::ThreadTokenUsage {
                    total: proto::TokenUsageBreakdown {
                        total_tokens: 5000,
                        input_tokens: 3000,
                        cached_input_tokens: 0,
                        output_tokens: 2000,
                        reasoning_output_tokens: 0,
                    },
                    last: proto::TokenUsageBreakdown {
                        total_tokens: 150,
                        input_tokens: 100,
                        cached_input_tokens: 0,
                        output_tokens: 50,
                        reasoning_output_tokens: 0,
                    },
                    model_context_window: Some(128000),
                },
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ContextTokensUpdated {
                key, used, limit, ..
            } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(used, 150);
                assert_eq!(limit, 128000);
            }
            other => panic!("expected ContextTokensUpdated, got {other:?}"),
        }
    }

    #[test]
    fn account_rate_limits_updated() {
        let notification = ServerNotification::AccountRateLimitsUpdated(
            proto::AccountRateLimitsUpdatedNotification {
                rate_limits: proto::RateLimitSnapshot {
                    limit_id: Some("primary".to_string()),
                    limit_name: Some("Primary".to_string()),
                    primary: Some(proto::RateLimitWindow {
                        used_percent: 42,
                        window_duration_mins: Some(60),
                        resets_at: Some(123456789),
                    }),
                    secondary: None,
                    credits: Some(proto::CreditsSnapshot {
                        has_credits: true,
                        unlimited: false,
                        balance: Some("5.00".to_string()),
                    }),
                    plan_type: Some(codex_protocol::account::PlanType::Plus),
                    rate_limit_reached_type: None,
                },
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::AccountRateLimitsUpdated {
                server_id,
                runtime_kind,
                notification,
            } => {
                assert_eq!(server_id, "srv1");
                assert_eq!(runtime_kind, "codex");
                assert_eq!(
                    notification.rate_limits.limit_id.as_deref(),
                    Some("primary")
                );
                assert_eq!(
                    notification
                        .rate_limits
                        .primary
                        .as_ref()
                        .map(|w| w.used_percent),
                    Some(42)
                );
            }
            other => panic!("expected AccountRateLimitsUpdated, got {other:?}"),
        }
    }

    // ── Unknown notifications ──────────────────────────────────────────

    #[test]
    fn unhandled_known_notification_emits_raw() {
        // SkillsChanged is known but not mapped to a typed UiEvent —
        // it should be forwarded as RawNotification.
        let notification = ServerNotification::SkillsChanged(proto::SkillsChangedNotification {});
        let evt = process_and_recv("srv1", &notification);
        assert!(evt.is_some());
        match evt.unwrap() {
            UiEvent::RawNotification { method, .. } => {
                assert!(!method.is_empty());
            }
            other => panic!("expected RawNotification, got {other:?}"),
        }
    }

    #[test]
    fn typed_notifications_no_longer_fall_through_to_raw() {
        let notifications = vec![
            ServerNotification::ThreadStarted(proto::ThreadStartedNotification {
                thread: proto::Thread {
                    id: "thr_1".to_string(),
                    session_id: "session_1".to_string(),
                    forked_from_id: None,
                    preview: String::new(),
                    ephemeral: false,
                    model_provider: "openai".to_string(),
                    created_at: 1,
                    updated_at: 1,
                    status: proto::ThreadStatus::Idle,
                    path: None,
                    cwd: test_abs_path("/tmp"),
                    cli_version: "1.0.0".to_string(),
                    source: proto::SessionSource::Cli,
                    thread_source: None,
                    agent_nickname: None,
                    agent_role: None,
                    git_info: None,
                    name: None,
                    turns: Vec::new(),
                },
            }),
            ServerNotification::ThreadStatusChanged(proto::ThreadStatusChangedNotification {
                thread_id: "thr_1".to_string(),
                status: proto::ThreadStatus::Idle,
            }),
            ServerNotification::TurnDiffUpdated(proto::TurnDiffUpdatedNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                diff: String::new(),
            }),
            ServerNotification::TurnPlanUpdated(proto::TurnPlanUpdatedNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                explanation: None,
                plan: Vec::new(),
            }),
            ServerNotification::ServerRequestResolved(proto::ServerRequestResolvedNotification {
                thread_id: "thr_1".to_string(),
                request_id: proto::RequestId::String("abc".to_string()),
            }),
            ServerNotification::McpToolCallProgress(proto::McpToolCallProgressNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                message: String::new(),
            }),
        ];

        for notification in notifications {
            let evt = process_and_recv("srv1", &notification).expect("should emit");
            assert!(
                !matches!(evt, UiEvent::RawNotification { .. }),
                "typed notification fell through to raw: {evt:?}"
            );
        }
    }

    #[test]
    fn legacy_notification_emits_raw() {
        let proc = EventProcessor::new();
        let mut rx = proc.subscribe();
        proc.process_legacy_notification(
            "srv1",
            "codex/event/collab_wait_end",
            &serde_json::json!({ "receiver_agents": [{ "thread_id": "thr_2" }] }),
        );
        let evt = rx.try_recv().expect("should emit UiEvent");
        match evt {
            UiEvent::RawNotification {
                server_id,
                method,
                params,
            } => {
                assert_eq!(server_id, "srv1");
                assert_eq!(method, "codex/event/collab_wait_end");
                assert_eq!(params["receiver_agents"][0]["thread_id"], json!("thr_2"));
            }
            other => panic!("expected RawNotification, got {other:?}"),
        }
    }

    #[test]
    fn legacy_user_input_notification_emits_typed_request() {
        let proc = EventProcessor::new();
        let mut rx = proc.subscribe();
        proc.process_legacy_notification(
            "srv1",
            "item/tool/requestUserInput",
            &serde_json::json!({
                "requestId": "req-1",
                "params": {
                    "threadId": "thr_1",
                    "turnId": "turn_1",
                    "itemId": "item_1",
                    "questions": [{
                        "id": "q1",
                        "header": "Mode",
                        "question": "Pick one",
                        "isOther": false,
                        "isSecret": false,
                        "options": [{
                            "label": "Yes",
                            "description": "Allow it"
                        }]
                    }]
                }
            }),
        );
        let evt = rx.try_recv().expect("should emit UiEvent");
        match evt {
            UiEvent::UserInputRequested { request, seed } => {
                assert!(seed.is_none());
                assert_eq!(request.server_id, "srv1");
                assert_eq!(request.id, "req-1");
                assert_eq!(request.thread_id, "thr_1");
                assert_eq!(request.turn_id, "turn_1");
                assert_eq!(request.item_id, "item_1");
                assert_eq!(request.questions.len(), 1);
            }
            other => panic!("expected UserInputRequested, got {other:?}"),
        }
    }

    // ── Server requests (approvals) ────────────────────────────────────

    #[test]
    fn command_approval_request() {
        let request = ServerRequest::CommandExecutionRequestApproval {
            request_id: proto::RequestId::Integer(42),
            params: proto::CommandExecutionRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                started_at_ms: 0,
                approval_id: None,
                reason: None,
                network_approval_context: None,
                command: Some("rm -rf /tmp".to_string()),
                cwd: None,
                command_actions: None,
                additional_permissions: None,
                proposed_execpolicy_amendment: None,
                proposed_network_policy_amendments: None,
                available_decisions: None,
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::ApprovalRequested { key, approval } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(approval.approval.kind, ApprovalKind::Command);
                assert_eq!(approval.approval.id, "42");
                assert_eq!(approval.approval.command.as_deref(), Some("rm -rf /tmp"));
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    #[test]
    fn file_change_approval_request() {
        let request = ServerRequest::FileChangeRequestApproval {
            request_id: proto::RequestId::Integer(10),
            params: proto::FileChangeRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                started_at_ms: 0,
                reason: Some("modify file".to_string()),
                grant_root: None,
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::ApprovalRequested { approval, .. } => {
                assert_eq!(approval.approval.kind, ApprovalKind::FileChange);
                assert_eq!(approval.approval.reason.as_deref(), Some("modify file"));
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    #[test]
    fn permissions_approval_request() {
        let request = ServerRequest::PermissionsRequestApproval {
            request_id: proto::RequestId::Integer(11),
            params: proto::PermissionsRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                started_at_ms: 0,
                cwd: test_abs_path("/tmp"),
                reason: Some("need network access".to_string()),
                permissions: proto::RequestPermissionProfile {
                    network: None,
                    file_system: None,
                },
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::ApprovalRequested { approval, .. } => {
                assert_eq!(approval.approval.kind, ApprovalKind::Permissions);
                assert_eq!(
                    approval.approval.reason.as_deref(),
                    Some("need network access")
                );
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    #[test]
    fn mcp_elicitation_request() {
        let request = ServerRequest::McpServerElicitationRequest {
            request_id: proto::RequestId::Integer(12),
            params: proto::McpServerElicitationRequestParams {
                thread_id: "thr_1".to_string(),
                turn_id: None,
                server_name: "test_server".to_string(),
                request: proto::McpServerElicitationRequest::Form {
                    meta: None,
                    message: "Allow?".to_string(),
                    requested_schema: serde_json::from_value(json!({
                        "type": "object",
                        "properties": {}
                    }))
                    .unwrap(),
                },
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::UserInputRequested { request, seed } => {
                assert_eq!(request.server_id, "srv1");
                assert_eq!(request.id, "12");
                assert_eq!(request.thread_id, "thr_1");
                assert_eq!(request.questions.len(), 1);
                assert_eq!(request.questions[0].id, MCP_APPROVAL_FIELD_ID);
                assert_eq!(request.questions[0].question, "Allow?");
                assert_eq!(
                    request.questions[0].options[0].label,
                    MCP_APPROVAL_ACCEPT_ONCE_LABEL
                );
                assert!(matches!(
                    seed.map(|seed| seed.response_kind),
                    Some(PendingUserInputResponseKind::McpServerElicitation)
                ));
            }
            other => panic!("expected UserInputRequested, got {other:?}"),
        }
    }

    #[test]
    fn tool_request_user_input_is_emitted_as_typed_request() {
        let request = ServerRequest::ToolRequestUserInput {
            request_id: proto::RequestId::Integer(13),
            params: proto::ToolRequestUserInputParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                questions: vec![proto::ToolRequestUserInputQuestion {
                    id: "q1".to_string(),
                    header: "Mode".to_string(),
                    question: "Pick one".to_string(),
                    is_other: false,
                    is_secret: false,
                    options: Some(vec![proto::ToolRequestUserInputOption {
                        label: "Yes".to_string(),
                        description: "Allow it".to_string(),
                    }]),
                }],
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::UserInputRequested { request, seed } => {
                assert_eq!(request.server_id, "srv1");
                assert_eq!(request.id, "13");
                assert_eq!(request.thread_id, "thr_1");
                assert_eq!(request.turn_id, "turn_1");
                assert_eq!(request.item_id, "item_1");
                assert_eq!(request.questions.len(), 1);
                assert_eq!(request.questions[0].id, "q1");
                assert_eq!(request.questions[0].header.as_deref(), Some("Mode"));
                assert_eq!(request.questions[0].question, "Pick one");
                assert_eq!(request.questions[0].options.len(), 1);
                assert_eq!(request.questions[0].options[0].label, "Yes");
                assert!(matches!(
                    seed.map(|seed| seed.response_kind),
                    Some(PendingUserInputResponseKind::ToolRequestUserInput)
                ));
            }
            other => panic!("expected UserInputRequested, got {other:?}"),
        }
    }

    #[test]
    fn tool_request_user_input_normalizes_blank_and_duplicate_question_ids() {
        let request = ServerRequest::ToolRequestUserInput {
            request_id: proto::RequestId::Integer(14),
            params: proto::ToolRequestUserInputParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                questions: vec![
                    proto::ToolRequestUserInputQuestion {
                        id: "".to_string(),
                        header: "One".to_string(),
                        question: "Pick one".to_string(),
                        is_other: false,
                        is_secret: false,
                        options: None,
                    },
                    proto::ToolRequestUserInputQuestion {
                        id: "dup".to_string(),
                        header: "Two".to_string(),
                        question: "Pick two".to_string(),
                        is_other: false,
                        is_secret: false,
                        options: None,
                    },
                    proto::ToolRequestUserInputQuestion {
                        id: "dup".to_string(),
                        header: "Three".to_string(),
                        question: "Pick three".to_string(),
                        is_other: false,
                        is_secret: false,
                        options: None,
                    },
                ],
            },
        };

        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::UserInputRequested { request, .. } => {
                let ids = request
                    .questions
                    .iter()
                    .map(|question| question.id.as_str())
                    .collect::<Vec<_>>();
                assert_eq!(ids, vec!["question-1", "dup", "dup-2"]);
            }
            other => panic!("expected UserInputRequested, got {other:?}"),
        }
    }

    #[test]
    fn dynamic_tool_call_is_forwarded_with_request_id() {
        let request = ServerRequest::DynamicToolCall {
            request_id: proto::RequestId::Integer(14),
            params: proto::DynamicToolCallParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                call_id: "call_1".to_string(),
                tool: "show_widget".to_string(),
                namespace: None,
                arguments: json!({"title": "Hello"}),
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::RawNotification { method, params, .. } => {
                assert_eq!(method, "item/tool/call");
                assert_eq!(params["requestId"], json!("14"));
                assert_eq!(params["params"]["tool"], json!("show_widget"));
            }
            other => panic!("expected RawNotification, got {other:?}"),
        }
    }

    #[test]
    fn chatgpt_auth_tokens_refresh_is_forwarded_with_request_id() {
        let request = ServerRequest::ChatgptAuthTokensRefresh {
            request_id: proto::RequestId::Integer(15),
            params: proto::ChatgptAuthTokensRefreshParams {
                reason: proto::ChatgptAuthTokensRefreshReason::Unauthorized,
                previous_account_id: Some("acct-123".to_string()),
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::RawNotification { method, params, .. } => {
                assert_eq!(method, "account/chatgptAuthTokens/refresh");
                assert_eq!(params["requestId"], json!("15"));
                assert_eq!(params["params"]["previousAccountId"], json!("acct-123"));
            }
            other => panic!("expected RawNotification, got {other:?}"),
        }
    }

    // ── Pending approval management ────────────────────────────────────

    #[test]
    fn pending_approvals_are_tracked() {
        let proc = EventProcessor::new();
        let req1 = ServerRequest::CommandExecutionRequestApproval {
            request_id: proto::RequestId::Integer(1),
            params: proto::CommandExecutionRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                started_at_ms: 0,
                approval_id: None,
                reason: None,
                network_approval_context: None,
                command: Some("ls".to_string()),
                cwd: None,
                command_actions: None,
                additional_permissions: None,
                proposed_execpolicy_amendment: None,
                proposed_network_policy_amendments: None,
                available_decisions: None,
            },
        };
        let req2 = ServerRequest::FileChangeRequestApproval {
            request_id: proto::RequestId::Integer(2),
            params: proto::FileChangeRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_2".to_string(),
                started_at_ms: 0,
                reason: None,
                grant_root: None,
            },
        };
        proc.process_server_request("srv1", &req1);
        proc.process_server_request("srv1", &req2);
        assert_eq!(proc.pending_approvals().len(), 2);
    }

    #[test]
    fn resolve_approval_removes_it() {
        let proc = EventProcessor::new();
        let req1 = ServerRequest::CommandExecutionRequestApproval {
            request_id: proto::RequestId::Integer(1),
            params: proto::CommandExecutionRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                started_at_ms: 0,
                approval_id: None,
                reason: None,
                network_approval_context: None,
                command: None,
                cwd: None,
                command_actions: None,
                additional_permissions: None,
                proposed_execpolicy_amendment: None,
                proposed_network_policy_amendments: None,
                available_decisions: None,
            },
        };
        let req2 = ServerRequest::FileChangeRequestApproval {
            request_id: proto::RequestId::Integer(2),
            params: proto::FileChangeRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_2".to_string(),
                started_at_ms: 0,
                reason: None,
                grant_root: None,
            },
        };
        proc.process_server_request("srv1", &req1);
        proc.process_server_request("srv1", &req2);

        let resolved = proc.resolve_approval("1");
        assert!(resolved.is_some());
        assert_eq!(resolved.unwrap().id, "1");
        assert_eq!(proc.pending_approvals().len(), 1);
        assert_eq!(proc.pending_approvals()[0].id, "2");
    }

    #[test]
    fn resolve_nonexistent_approval_returns_none() {
        let proc = EventProcessor::new();
        assert!(proc.resolve_approval("999").is_none());
    }

    // ── Send + Sync ────────────────────────────────────────────────────

    #[test]
    fn event_processor_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<EventProcessor>();
    }

    // ── Multiple subscribers ───────────────────────────────────────────

    #[test]
    fn multiple_subscribers_receive_events() {
        let proc = EventProcessor::new();
        let mut rx1 = proc.subscribe();
        let mut rx2 = proc.subscribe();

        let notification = ServerNotification::TurnStarted(proto::TurnStartedNotification {
            thread_id: "thr_1".to_string(),
            turn: make_turn("turn_1"),
        });
        proc.process_notification("srv1", "codex".to_string(), &notification);

        assert!(rx1.try_recv().is_ok());
        assert!(rx2.try_recv().is_ok());
    }

    // ── No subscribers does not panic ──────────────────────────────────

    #[test]
    fn emit_without_subscribers_does_not_panic() {
        let proc = EventProcessor::new();
        let notification = ServerNotification::TurnStarted(proto::TurnStartedNotification {
            thread_id: "thr_1".to_string(),
            turn: make_turn("turn_1"),
        });
        proc.process_notification("srv1", "codex".to_string(), &notification);
        // No panic = success.
    }
}
