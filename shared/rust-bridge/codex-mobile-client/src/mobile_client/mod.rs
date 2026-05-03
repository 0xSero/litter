use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex as StdMutex, RwLock};
use tokio::sync::{Mutex, broadcast, mpsc};
use tracing::{debug, info, trace, warn};
use url::Url;

use crate::alleycat::{
    AgentInfo as AlleycatAgentInfo, AgentWire as AlleycatAgentWire, AlleycatReconnectTransport,
    ParsedPairPayload as ParsedAlleycatPairPayload,
};
use crate::discovery::{DiscoveredServer, DiscoveryConfig, DiscoveryService, MdnsSeed};
use crate::session::connection::InProcessConfig;
use crate::session::connection::{
    RemoteSessionExtras, RuntimeRemoteSessionResource, ServerConfig, ServerEvent, ServerSession,
    SshReconnectTransport,
};
use crate::session::events::{EventProcessor, UiEvent};
use crate::ssh::{SshBootstrapResult, SshClient, SshCredentials};
use crate::store::snapshot::{
    IpcFailureClassification, ServerMutatingCommandKind, ServerMutatingCommandRoute,
    ServerTransportAuthority,
};
use crate::store::{
    AppConnectionProgressSnapshot, AppQueuedFollowUpKind, AppQueuedFollowUpPreview, AppSnapshot,
    AppStoreReducer, AppStoreUpdateRecord, ServerHealthSnapshot, ThreadSnapshot,
};
use crate::transport::{RpcError, TransportError};
use crate::types::{
    AgentRuntimeInfo, AgentRuntimeKind, AppCollaborationModePreset, AppModeKind,
    ApprovalDecisionValue, PendingApproval, PendingApprovalSeed, PendingApprovalWithSeed,
    PendingUserInputAnswer, PendingUserInputRequest, ThreadInfo, ThreadKey, ThreadSummaryStatus,
};
use codex_app_server_protocol as upstream;
use codex_ipc::{
    ClientStatus, CommandExecutionApprovalDecision, FileChangeApprovalDecision, IpcClient,
    IpcClientConfig, IpcError, ProjectedApprovalKind, ProjectedApprovalRequest,
    ProjectedUserInputRequest, ReconnectPolicy, ReconnectingIpcClient, RequestError, StreamChange,
    ThreadFollowerCommandApprovalDecisionParams, ThreadFollowerFileApprovalDecisionParams,
    ThreadFollowerSetCollaborationModeParams, ThreadFollowerStartTurnParams,
    ThreadFollowerSubmitUserInputParams, ThreadStreamStateChangedParams, TypedBroadcast,
    project_conversation_state, seed_conversation_state_from_thread,
};

mod dynamic_tools;
mod event_loop;
mod ipc_attach;
pub(crate) mod minigame;
mod store_listener;
#[cfg(test)]
mod tests;
mod thread_projection;

use self::dynamic_tools::*;
use self::ipc_attach::*;
use self::store_listener::*;
use self::thread_projection::*;
pub use self::thread_projection::{
    copy_thread_runtime_fields, reasoning_effort_from_string, reasoning_effort_string,
    reconcile_active_turn, thread_info_from_upstream_thread,
    thread_snapshot_from_upstream_thread_with_overrides,
};
/// Top-level entry point for platform code (iOS / Android).
///
/// Ties together server sessions, thread management, event processing,
/// discovery, auth, caching, and voice handoff into a single facade.
/// All methods are safe to call from any thread (`Send + Sync`).
pub struct MobileClient {
    pub(crate) sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    pub(crate) event_processor: Arc<EventProcessor>,
    pub app_store: Arc<AppStoreReducer>,
    pub(crate) discovery: RwLock<DiscoveryService>,
    oauth_callback_tunnels: Arc<Mutex<HashMap<String, OAuthCallbackTunnel>>>,
    pub(crate) recorder: Arc<crate::recorder::MessageRecorder>,
    pub(crate) ambient_cache: crate::ambient_suggestions::AmbientCache,
    /// One-shot hooks that fulfill when the next `show_widget` dynamic tool
    /// call finalizes on a specific thread. Keyed by `thread_id`.
    /// Used by `AppClient::update_saved_app`.
    pub(crate) widget_waiters: Arc<StdMutex<HashMap<String, WidgetWaiter>>>,
    /// Directory where `saved_apps.rs` persists the app index + per-app
    /// HTML/state files. Set once at process start by the platform
    /// (iOS/Android) via `AppClient::set_saved_apps_directory`. When
    /// `Some`, the `show_widget` auto-upsert hook is enabled; when
    /// `None`, the hook is skipped (pre-R2 callers / tests).
    pub(crate) saved_apps_directory: Arc<StdMutex<Option<String>>>,
    direct_resumed_threads: Arc<StdMutex<HashSet<ThreadKey>>>,
    thread_runtime_routes: Arc<StdMutex<HashMap<ThreadKey, AgentRuntimeKind>>>,
    /// In-flight guided-SSH-connect flows, keyed by server_id. Hosts the
    /// `install_decision` oneshot that the FFI install-prompt response feeds
    /// into. Held on `MobileClient` (not `SshBridge`) so the connect entry
    /// point and the install-prompt response can live on different bridges.
    pub(crate) ssh_bootstrap_flows:
        Arc<tokio::sync::Mutex<HashMap<String, ManagedSshBootstrapFlow>>>,
}

/// State for a single in-flight guided SSH connect. The connect task installs a
/// `oneshot::Sender<bool>` once it discovers Codex is missing on the remote and
/// awaits the FFI install-prompt response to fire it.
pub struct ManagedSshBootstrapFlow {
    pub install_decision: Option<tokio::sync::oneshot::Sender<bool>>,
}

/// A waiter registered by `update_saved_app` to receive the next
/// finalized `show_widget` on a specific thread. See
/// `MobileClient::widget_waiters` and `dynamic_tools::try_fulfill_widget_waiter`.
pub struct WidgetWaiter {
    pub sender: tokio::sync::oneshot::Sender<WidgetFinalizedPayload>,
}

#[derive(Debug, Clone)]
pub struct WidgetFinalizedPayload {
    pub widget_html: String,
    pub width: f64,
    pub height: f64,
    pub title: String,
}

#[derive(Debug, Clone)]
struct OAuthCallbackTunnel {
    login_id: String,
    local_port: u16,
}

#[derive(Debug, Clone)]
pub struct AlleycatConnectOutcome {
    pub server_id: String,
    pub node_id: String,
    pub agent_name: String,
}

const USER_INPUT_NOTE_PREFIX: &str = "user_note: ";
const USER_INPUT_OTHER_OPTION_LABEL: &str = "None of the above";
const USER_INPUT_RECONCILE_DELAYS_MS: [u64; 3] = [150, 800, 2500];

fn ipc_command_error_clears_server_ipc_state(error: &IpcError) -> bool {
    matches!(
        error,
        IpcError::Transport(_)
            | IpcError::NotConnected
            | IpcError::Request(RequestError::NoClientFound | RequestError::ClientDisconnected)
    )
}

fn ipc_command_error_context(error: &IpcError) -> &'static str {
    if ipc_command_error_clears_server_ipc_state(error) {
        "IPC transport is no longer connected"
    } else {
        "IPC stream is still attached, but desktop follower commands are unavailable"
    }
}

fn server_supports_ipc(session: &ServerSession) -> bool {
    session.ssh_client().is_some() || session.has_ipc()
}

fn server_has_live_ipc(
    app_store: &AppStoreReducer,
    server_id: &str,
    session: &ServerSession,
) -> bool {
    session.has_ipc()
        && app_store
            .snapshot()
            .servers
            .get(server_id)
            .map(|server| {
                server.has_ipc && server.transport.authority == ServerTransportAuthority::IpcPrimary
            })
            .unwrap_or(false)
}

fn should_fail_over_server_after_ipc_mutation_error(error: &IpcError) -> bool {
    matches!(
        error,
        IpcError::Request(RequestError::NoClientFound | RequestError::ClientDisconnected)
            | IpcError::Transport(_)
            | IpcError::NotConnected
    )
}

fn should_fall_back_to_direct_after_ipc_mutation_error(error: &IpcError) -> bool {
    matches!(
        error,
        IpcError::Request(
            RequestError::Timeout | RequestError::NoClientFound | RequestError::ClientDisconnected
        ) | IpcError::Transport(_)
            | IpcError::NotConnected
    )
}

fn is_timeout_like_ipc_mutation_error(error: &IpcError) -> bool {
    matches!(error, IpcError::Request(RequestError::Timeout))
}

fn should_fallback_to_thread_metadata_after_resume_error(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    lower.contains("no rollout found for thread id")
        || lower.contains("remote app-server worker channel is closed")
}

fn should_try_next_runtime_after_thread_lookup_error(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    lower.contains("no rollout found for thread id")
        || lower.contains("thread cannot be found")
        || lower.contains("thread not found")
        || lower.contains("no thread found")
        || lower.contains("unknown thread")
}

fn normalize_pending_user_input_answers(
    request: &PendingUserInputRequest,
    answers: &[PendingUserInputAnswer],
) -> Vec<PendingUserInputAnswer> {
    request
        .questions
        .iter()
        .map(|question| {
            let raw_answers = answers
                .iter()
                .find(|answer| answer.question_id == question.id)
                .map(|answer| answer.answers.as_slice())
                .unwrap_or(&[]);
            PendingUserInputAnswer {
                question_id: question.id.clone(),
                answers: normalize_pending_user_input_answer_entries(question, raw_answers),
            }
        })
        .collect()
}

fn fail_server_over_from_ipc_mutation(
    app_store: &AppStoreReducer,
    session: &ServerSession,
    server_id: &str,
    error: &IpcError,
) -> IpcFailureClassification {
    let classification = app_store.classify_ipc_mutation_failure(
        server_id,
        ipc_command_error_clears_server_ipc_state(error),
        is_timeout_like_ipc_mutation_error(error),
    );
    app_store.fail_server_over_to_direct_only(server_id, classification);
    if ipc_command_error_clears_server_ipc_state(error) {
        session.invalidate_ipc();
    }
    classification
}

fn start_remote_reconnecting_ipc_client(
    ssh_client: Arc<SshClient>,
    server_id: String,
    ipc_socket_path_override: Option<String>,
    bridge_pid_slot: Option<Arc<StdMutex<Option<u32>>>>,
    lane: &'static str,
) -> Arc<ReconnectingIpcClient> {
    Arc::new(ReconnectingIpcClient::start_with_connector(
        None,
        move || {
            let reconnect_ssh_client = Arc::clone(&ssh_client);
            let reconnect_server_id = server_id.clone();
            let reconnect_ipc_socket_path_override = ipc_socket_path_override.clone();
            let reconnect_bridge_pid = bridge_pid_slot.as_ref().map(Arc::clone);
            async move {
                if let Some(bridge_pid_slot) = reconnect_bridge_pid.as_ref() {
                    let previous_pid = match bridge_pid_slot.lock() {
                        Ok(mut guard) => guard.take(),
                        Err(error) => {
                            warn!("MobileClient: recovering poisoned {lane} ipc bridge pid lock");
                            error.into_inner().take()
                        }
                    };
                    if let Some(pid) = previous_pid {
                        let _ = reconnect_ssh_client
                            .exec(&format!("kill {pid} 2>/dev/null"))
                            .await;
                    }
                }

                let (client, bridge_pid) = attach_ipc_client_for_remote_session(
                    &reconnect_ssh_client,
                    reconnect_server_id.as_str(),
                    reconnect_ipc_socket_path_override.as_deref(),
                )
                .await;

                if let Some(bridge_pid_slot) = reconnect_bridge_pid.as_ref() {
                    match bridge_pid_slot.lock() {
                        Ok(mut guard) => *guard = bridge_pid,
                        Err(error) => {
                            warn!("MobileClient: recovering poisoned {lane} ipc bridge pid lock");
                            *error.into_inner() = bridge_pid;
                        }
                    }
                }

                client.ok_or(IpcError::NotConnected)
            }
        },
        ipc_reconnect_policy(),
    ))
}

async fn run_ipc_command<T, F, Fut>(session: &ServerSession, op: F) -> Result<Option<T>, IpcError>
where
    F: FnOnce(IpcClient) -> Fut,
    Fut: Future<Output = Result<T, IpcError>>,
{
    if let Some(ipc_client) = session.ipc_stream_client() {
        return op(ipc_client).await.map(Some);
    }
    Ok(None)
}

/// Returns true when an RPC error string looks like a JSON-RPC -32601
/// "method not found" error.
fn is_method_not_found(error: &str) -> bool {
    error.contains("-32601")
        || error.to_ascii_lowercase().contains("method not found")
        || error.to_ascii_lowercase().contains("not implemented")
}

fn ipc_pending_user_input_submission_id(request: &PendingUserInputRequest) -> &str {
    // Desktop thread-follower user-input replies resolve the pending app-server request,
    // not the turn id that originally emitted it.
    &request.id
}

fn normalize_pending_user_input_answer_entries(
    question: &crate::types::PendingUserInputQuestion,
    raw_answers: &[String],
) -> Vec<String> {
    let mut selected_options = Vec::new();
    let mut note_parts = Vec::new();

    for raw_answer in raw_answers {
        let trimmed = raw_answer.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(note) = trimmed.strip_prefix(USER_INPUT_NOTE_PREFIX) {
            let note = note.trim();
            if !note.is_empty() {
                note_parts.push(note.to_string());
            }
            continue;
        }

        if !question.options.is_empty()
            && (question
                .options
                .iter()
                .any(|option| option.label == trimmed)
                || trimmed == USER_INPUT_OTHER_OPTION_LABEL)
        {
            selected_options.push(trimmed.to_string());
        } else {
            note_parts.push(trimmed.to_string());
        }
    }

    if question.options.is_empty() {
        return if note_parts.is_empty() {
            Vec::new()
        } else {
            vec![format!("{USER_INPUT_NOTE_PREFIX}{}", note_parts.join("\n"))]
        };
    }

    if question.is_other_allowed && !note_parts.is_empty() && selected_options.is_empty() {
        selected_options.push(USER_INPUT_OTHER_OPTION_LABEL.to_string());
    }

    if note_parts.is_empty() {
        return selected_options;
    }

    let mut normalized = selected_options;
    normalized.push(format!("{USER_INPUT_NOTE_PREFIX}{}", note_parts.join("\n")));
    normalized
}

fn non_empty_trimmed(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn runtime_for_model_hint(value: &str) -> Option<AgentRuntimeKind> {
    let normalized = value.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "claude" | "claude-code" | "claude_code" => Some(AgentRuntimeKind::Claude),
        "opencode" | "open-code" | "open_code" | "open code" => Some(AgentRuntimeKind::Opencode),
        "pi" | "pi.dev" | "pidev" | "pi dev" => Some(AgentRuntimeKind::Pi),
        "codex" => Some(AgentRuntimeKind::Codex),
        _ if normalized.starts_with("claude") => Some(AgentRuntimeKind::Claude),
        _ if normalized.contains("opencode")
            || normalized.contains("open-code")
            || normalized.contains("open_code")
            || normalized.contains("open code") =>
        {
            Some(AgentRuntimeKind::Opencode)
        }
        _ if normalized.starts_with("pi.dev")
            || normalized.starts_with("pidev")
            || normalized.starts_with("pi/") =>
        {
            Some(AgentRuntimeKind::Pi)
        }
        _ => None,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedModelSelection {
    pub model: String,
    pub runtime_kind: AgentRuntimeKind,
}

impl MobileClient {
    /// Create a new `MobileClient`.
    pub fn new() -> Self {
        crate::logging::install_ipc_wire_trace_logger();
        let event_processor = Arc::new(EventProcessor::new());
        let app_store = Arc::new(AppStoreReducer::new());
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        spawn_store_listener(
            Arc::clone(&app_store),
            Arc::clone(&sessions),
            event_processor.subscribe(),
        );
        Self {
            sessions,
            event_processor,
            app_store,
            discovery: RwLock::new(DiscoveryService::new(DiscoveryConfig::default())),
            oauth_callback_tunnels: Arc::new(Mutex::new(HashMap::new())),
            recorder: Arc::new(crate::recorder::MessageRecorder::new()),
            ambient_cache: crate::ambient_suggestions::new_ambient_cache(),
            widget_waiters: Arc::new(StdMutex::new(HashMap::new())),
            saved_apps_directory: Arc::new(StdMutex::new(None)),
            direct_resumed_threads: Arc::new(StdMutex::new(HashSet::new())),
            thread_runtime_routes: Arc::new(StdMutex::new(HashMap::new())),
            ssh_bootstrap_flows: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
        }
    }

    fn sessions_write(
        &self,
    ) -> std::sync::RwLockWriteGuard<'_, HashMap<String, Arc<ServerSession>>> {
        match self.sessions.write() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned sessions write lock");
                error.into_inner()
            }
        }
    }

    fn sessions_read(&self) -> std::sync::RwLockReadGuard<'_, HashMap<String, Arc<ServerSession>>> {
        match self.sessions.read() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned sessions read lock");
                error.into_inner()
            }
        }
    }

    fn direct_resumed_threads(&self) -> std::sync::MutexGuard<'_, HashSet<ThreadKey>> {
        match self.direct_resumed_threads.lock() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned direct resume marker lock");
                error.into_inner()
            }
        }
    }

    fn thread_runtime_routes(
        &self,
    ) -> std::sync::MutexGuard<'_, HashMap<ThreadKey, AgentRuntimeKind>> {
        match self.thread_runtime_routes.lock() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned thread runtime route lock");
                error.into_inner()
            }
        }
    }

    pub(crate) fn note_thread_runtime(&self, key: ThreadKey, runtime_kind: AgentRuntimeKind) {
        self.thread_runtime_routes()
            .insert(key.clone(), runtime_kind);
        self.app_store.set_thread_agent_runtime(&key, runtime_kind);
    }

    pub(crate) fn runtime_for_thread(&self, key: &ThreadKey) -> AgentRuntimeKind {
        let routed_runtime = self.thread_runtime_routes().get(key).copied();
        if let Some(runtime_kind) = routed_runtime
            && runtime_kind != AgentRuntimeKind::Codex
        {
            return runtime_kind;
        }

        if let Some(thread) = self.app_store.thread_snapshot(key) {
            if thread.agent_runtime_kind != AgentRuntimeKind::Codex {
                return thread.agent_runtime_kind;
            }
            if let Some(runtime_kind) = self.non_codex_runtime_for_thread_metadata(key, &thread) {
                return runtime_kind;
            }
        }

        routed_runtime.unwrap_or(AgentRuntimeKind::Codex)
    }

    pub(crate) fn runtime_for_thread_start(
        &self,
        server_id: &str,
        explicit_runtime_kind: Option<AgentRuntimeKind>,
        model: Option<&str>,
    ) -> AgentRuntimeKind {
        if let Some(runtime_kind) = explicit_runtime_kind {
            return runtime_kind;
        }

        if let Some(model) = model.and_then(non_empty_trimmed) {
            if let Some(selection) = self.resolve_model_selection(server_id, model) {
                return selection.runtime_kind;
            }
            if let Some(runtime_kind) = runtime_for_model_hint(model) {
                return runtime_kind;
            }
        }

        AgentRuntimeKind::Codex
    }

    pub(crate) fn resolve_model_selection(
        &self,
        server_id: &str,
        model: &str,
    ) -> Option<ResolvedModelSelection> {
        let selected_model = non_empty_trimmed(model)?;
        let snapshot = self.app_store.snapshot();
        let models = snapshot.servers.get(server_id)?.available_models.as_ref()?;

        let exact = models
            .iter()
            .find(|candidate| candidate.id == selected_model);
        if let Some(candidate) = exact {
            return Some(ResolvedModelSelection {
                model: candidate.id.clone(),
                runtime_kind: candidate.agent_runtime_kind,
            });
        }

        if let Some(candidate) = models
            .iter()
            .find(|candidate| candidate.model == selected_model)
        {
            return Some(ResolvedModelSelection {
                model: candidate.id.clone(),
                runtime_kind: candidate.agent_runtime_kind,
            });
        }

        None
    }

    fn runtime_for_selected_model(&self, server_id: &str, model: &str) -> Option<AgentRuntimeKind> {
        self.resolve_model_selection(server_id, model)
            .map(|selection| selection.runtime_kind)
    }

    fn resolve_model_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        model: &str,
    ) -> Option<String> {
        let selected_model = non_empty_trimmed(model)?;
        let snapshot = self.app_store.snapshot();
        let models = snapshot.servers.get(server_id)?.available_models.as_ref()?;
        models
            .iter()
            .find(|candidate| {
                candidate.agent_runtime_kind == runtime_kind
                    && (candidate.id == selected_model || candidate.model == selected_model)
            })
            .map(|candidate| candidate.id.clone())
    }

    pub(crate) fn normalize_thread_model_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        model: &mut Option<String>,
    ) {
        let Some(selected_model) = model.as_deref().and_then(non_empty_trimmed) else {
            return;
        };
        if let Some(resolved) =
            self.resolve_model_for_runtime(server_id, runtime_kind, selected_model)
        {
            *model = Some(resolved);
        }
    }

    pub(crate) fn normalize_model_selection_for_request(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        request: &mut upstream::ClientRequest,
    ) {
        match request {
            upstream::ClientRequest::ThreadStart { params, .. } => {
                self.normalize_thread_model_for_runtime(server_id, runtime_kind, &mut params.model);
            }
            upstream::ClientRequest::ThreadResume { params, .. } => {
                self.normalize_thread_model_for_runtime(server_id, runtime_kind, &mut params.model);
            }
            upstream::ClientRequest::ThreadFork { params, .. } => {
                self.normalize_thread_model_for_runtime(server_id, runtime_kind, &mut params.model);
            }
            upstream::ClientRequest::TurnStart { params, .. } => {
                if let Some(selected_model) = params.model.as_deref().and_then(non_empty_trimmed)
                    && let Some(resolved) =
                        self.resolve_model_for_runtime(server_id, runtime_kind, selected_model)
                {
                    params.model = Some(resolved);
                }
            }
            _ => {}
        }
    }

    fn non_codex_runtime_for_thread_metadata(
        &self,
        key: &ThreadKey,
        thread: &ThreadSnapshot,
    ) -> Option<AgentRuntimeKind> {
        for model in [thread.model.as_deref(), thread.info.model.as_deref()]
            .into_iter()
            .flatten()
            .filter_map(non_empty_trimmed)
        {
            let runtime_kind = self
                .runtime_for_selected_model(&key.server_id, model)
                .or_else(|| runtime_for_model_hint(model));
            if let Some(runtime_kind) = runtime_kind
                && runtime_kind != AgentRuntimeKind::Codex
            {
                return Some(runtime_kind);
            }
        }

        if let Some(runtime_kind) = thread
            .info
            .model_provider
            .as_deref()
            .and_then(runtime_for_model_hint)
            .filter(|runtime_kind| *runtime_kind != AgentRuntimeKind::Codex)
        {
            return Some(runtime_kind);
        }

        None
    }

    fn has_direct_resume_marker(&self, key: &ThreadKey) -> bool {
        self.direct_resumed_threads().contains(key)
    }

    fn mark_direct_resumed_thread(&self, key: ThreadKey) {
        self.direct_resumed_threads().insert(key);
    }

    pub(super) fn clear_direct_resume_markers_for_server(&self, server_id: &str) {
        self.direct_resumed_threads()
            .retain(|key| key.server_id != server_id);
        self.thread_runtime_routes()
            .retain(|key, _| key.server_id != server_id);
    }

    // ── Internal RPC helpers ──────────────────────────────────────────────

    pub(crate) async fn server_get_account(
        &self,
        server_id: &str,
        params: upstream::GetAccountParams,
    ) -> Result<upstream::GetAccountResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        self.request_typed_for_server(
            server_id,
            upstream::ClientRequest::GetAccount {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params,
            },
        )
        .await
        .map_err(RpcClientError::Rpc)
    }

    pub(crate) async fn server_thread_fork(
        &self,
        server_id: &str,
        params: upstream::ThreadForkParams,
    ) -> Result<upstream::ThreadForkResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        self.request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadFork {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params,
            },
        )
        .await
        .map_err(RpcClientError::Rpc)
    }

    pub(crate) async fn server_thread_rollback(
        &self,
        server_id: &str,
        params: upstream::ThreadRollbackParams,
    ) -> Result<upstream::ThreadRollbackResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        self.request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadRollback {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params,
            },
        )
        .await
        .map_err(RpcClientError::Rpc)
    }

    #[allow(dead_code)]
    pub(crate) async fn server_thread_list(
        &self,
        server_id: &str,
        params: upstream::ThreadListParams,
    ) -> Result<upstream::ThreadListResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        let runtime_kinds = self
            .get_session(server_id)
            .map_err(|error| RpcClientError::Rpc(error.to_string()))?
            .runtime_kinds();
        let mut merged = upstream::ThreadListResponse {
            data: Vec::new(),
            next_cursor: None,
            backwards_cursor: None,
        };

        for runtime_kind in runtime_kinds {
            let response: upstream::ThreadListResponse = self
                .request_typed_for_server_runtime(
                    server_id,
                    runtime_kind,
                    upstream::ClientRequest::ThreadList {
                        request_id: upstream::RequestId::Integer(next_request_id()),
                        params: params.clone(),
                    },
                )
                .await
                .map_err(RpcClientError::Rpc)?;
            merged.data.extend(response.data);
            if merged.next_cursor.is_none() {
                merged.next_cursor = response.next_cursor;
            }
            if merged.backwards_cursor.is_none() {
                merged.backwards_cursor = response.backwards_cursor;
            }
        }

        Ok(merged)
    }

    pub(crate) async fn server_collaboration_mode_list(
        &self,
        server_id: &str,
    ) -> Result<Vec<AppCollaborationModePreset>, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        let response = self
            .request_typed_for_server::<upstream::CollaborationModeListResponse>(
                server_id,
                upstream::ClientRequest::CollaborationModeList {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: upstream::CollaborationModeListParams::default(),
                },
            )
            .await
            .map_err(RpcClientError::Rpc)?;

        Ok(response
            .data
            .into_iter()
            .filter_map(|mask| AppCollaborationModePreset::try_from(mask).ok())
            .collect())
    }

    fn discovery_write(&self) -> std::sync::RwLockWriteGuard<'_, DiscoveryService> {
        match self.discovery.write() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned discovery write lock");
                error.into_inner()
            }
        }
    }

    fn discovery_read(&self) -> std::sync::RwLockReadGuard<'_, DiscoveryService> {
        match self.discovery.read() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned discovery read lock");
                error.into_inner()
            }
        }
    }

    async fn clear_oauth_callback_tunnel(&self, server_id: &str) {
        let tunnel = {
            let mut tunnels = self.oauth_callback_tunnels.lock().await;
            tunnels.remove(server_id)
        };
        let session = self.sessions_read().get(server_id).cloned();
        if let Some(tunnel) = tunnel
            && let Some(session) = session
            && let Some(ssh_client) = session.ssh_client()
        {
            ssh_client.abort_forward_port(tunnel.local_port).await;
        }
    }

    async fn replace_oauth_callback_tunnel(
        &self,
        server_id: &str,
        login_id: &str,
        local_port: u16,
    ) {
        self.clear_oauth_callback_tunnel(server_id).await;
        let mut tunnels = self.oauth_callback_tunnels.lock().await;
        tunnels.insert(
            server_id.to_string(),
            OAuthCallbackTunnel {
                login_id: login_id.to_string(),
                local_port,
            },
        );
    }

    fn existing_active_session(&self, server_id: &str) -> Option<Arc<ServerSession>> {
        let session = self.sessions_read().get(server_id).cloned()?;
        let health_rx = session.health();
        match health_rx.borrow().clone() {
            crate::session::connection::ConnectionHealth::Disconnected => None,
            _ => Some(session),
        }
    }

    async fn replace_existing_session(&self, server_id: &str) {
        self.clear_oauth_callback_tunnel(server_id).await;
        let existing = self.sessions_write().remove(server_id);
        self.clear_direct_resume_markers_for_server(server_id);
        if let Some(session) = existing {
            info!("MobileClient: replacing existing server session {server_id}");
            session.disconnect().await;
        }
    }

    /// Common post-`connect_remote_multiplexed` attach work shared by every
    /// remote-connect orchestrator (Alleycat, SSH-direct, SSH-bridges).
    ///
    /// Runs the steps that are identical across transports: marking the server
    /// `Connected`, registering runtime info, spawning event/health readers,
    /// inserting into the session map, and queuing post-connect warmup. IPC
    /// readers are wired conditionally on `session.has_ipc()` so the SSH-direct
    /// IPC stream attaches without polluting the other paths.
    fn attach_remote_session(
        &self,
        server_id: &str,
        session: Arc<ServerSession>,
        runtime_infos: Vec<AgentRuntimeInfo>,
    ) {
        let session_runtime_kinds = session.runtime_kinds();
        info!(
            "MobileClient: attaching remote session server_id={} session_runtimes={:?} runtime_infos={:?}",
            server_id, session_runtime_kinds, runtime_infos
        );
        self.app_store.upsert_server(
            session.config(),
            ServerHealthSnapshot::Connected,
            server_supports_ipc(&session),
        );
        self.app_store
            .update_server_agent_runtimes(server_id, runtime_infos);
        if session.has_ipc() {
            self.app_store.update_server_ipc_state(server_id, true);
            self.app_store.mark_server_ipc_primary(server_id);
            self.spawn_ipc_reader(server_id.to_string(), Arc::clone(&session));
            self.spawn_ipc_connection_state_reader(server_id.to_string(), Arc::clone(&session));
        }
        self.sessions_write()
            .insert(server_id.to_string(), Arc::clone(&session));
        self.spawn_event_reader(server_id.to_string(), Arc::clone(&session));
        self.spawn_health_reader(server_id.to_string(), Arc::clone(&session));
        self.spawn_post_connect_warmup(server_id.to_string(), session);
    }

    // ── Server Management ─────────────────────────────────────────────

    /// Connect to a local (in-process) Codex server.
    ///
    /// Returns the `server_id` from the config on success.
    pub async fn connect_local(
        &self,
        config: ServerConfig,
        in_process: InProcessConfig,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        if self.existing_active_session(server_id.as_str()).is_some() {
            info!("MobileClient: reusing existing local server session {server_id}");
            return Ok(server_id);
        }
        self.replace_existing_session(server_id.as_str()).await;
        let session = Arc::new(ServerSession::connect_local(config, in_process).await?);
        self.app_store.upsert_server(
            session.config(),
            ServerHealthSnapshot::Connected,
            server_supports_ipc(&session),
        );

        self.sessions_write()
            .insert(server_id.clone(), Arc::clone(&session));
        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_post_connect_warmup(server_id.clone(), session);

        info!("MobileClient: connected local server {server_id}");
        Ok(server_id)
    }

    /// Connect to a remote Codex server via WebSocket.
    ///
    /// Returns the `server_id` from the config on success.
    pub async fn connect_remote(&self, config: ServerConfig) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        if self.existing_active_session(server_id.as_str()).is_some() {
            info!("MobileClient: reusing existing remote server session {server_id}");
            return Ok(server_id);
        }
        self.replace_existing_session(server_id.as_str()).await;
        let session = Arc::new(ServerSession::connect_remote(config).await?);
        self.app_store.upsert_server(
            session.config(),
            ServerHealthSnapshot::Connected,
            server_supports_ipc(&session),
        );

        self.sessions_write()
            .insert(server_id.clone(), Arc::clone(&session));
        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_post_connect_warmup(server_id.clone(), session);

        info!("MobileClient: connected remote server {server_id}");
        Ok(server_id)
    }

    pub async fn list_alleycat_agents(
        &self,
        params: ParsedAlleycatPairPayload,
    ) -> Result<Vec<AlleycatAgentInfo>, TransportError> {
        crate::alleycat::list_agents(params)
            .await
            .map_err(|error| TransportError::ConnectionFailed(error.to_string()))
    }

    pub async fn connect_remote_over_alleycat(
        &self,
        server_id: String,
        display_name: String,
        params: ParsedAlleycatPairPayload,
        agent_name: String,
        selected_agent_names: Vec<String>,
        wire: AlleycatAgentWire,
    ) -> Result<AlleycatConnectOutcome, TransportError> {
        info!(
            "MobileClient: connect_remote_over_alleycat start server_id={} node_id={} agent={} selected_agents={:?} wire={:?}",
            server_id, params.node_id, agent_name, selected_agent_names, wire
        );
        let selected_agent_names = selected_agent_names
            .into_iter()
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty())
            .collect::<std::collections::HashSet<_>>();
        let mut seen_runtime_kinds = std::collections::HashSet::new();
        let requested_agents = self
            .list_alleycat_agents(params.clone())
            .await?
            .into_iter()
            .filter_map(|agent| {
                if !selected_agent_names.is_empty() && !selected_agent_names.contains(&agent.name) {
                    return None;
                }
                let runtime_kind =
                    crate::alleycat::agent_runtime_kind(&agent.name, &agent.display_name)?;
                if !seen_runtime_kinds.insert(runtime_kind) {
                    return None;
                }
                (agent.available).then_some((runtime_kind, agent))
            })
            .collect::<Vec<_>>();
        let runtime_agents = if requested_agents.is_empty() {
            if !selected_agent_names.is_empty() && !selected_agent_names.contains(&agent_name) {
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                return Err(TransportError::ConnectionFailed(
                    "no selected Alleycat runtime streams are available".to_string(),
                ));
            }
            vec![(
                crate::alleycat::agent_runtime_kind(&agent_name, &agent_name)
                    .unwrap_or(AgentRuntimeKind::Codex),
                AlleycatAgentInfo {
                    name: agent_name.clone(),
                    display_name: display_name.clone(),
                    wire,
                    available: true,
                },
            )]
        } else {
            requested_agents
        };
        let visible_server_id = format!("alleycat:{}", params.node_id);
        let server_id = if server_id.starts_with(&visible_server_id) {
            visible_server_id
        } else {
            server_id
        };

        let config = ServerConfig {
            server_id: server_id.clone(),
            display_name,
            host: params.node_id.clone(),
            port: 0,
            websocket_url: Some(format!("ws://alleycat/{}", params.node_id)),
            is_local: false,
            tls: false,
        };
        self.app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting, true);
        self.replace_existing_session(server_id.as_str()).await;

        let mut runtime_resources = Vec::new();
        let mut runtime_infos = Vec::new();
        for (runtime_kind, agent) in runtime_agents {
            let reconnect_transport = AlleycatReconnectTransport {
                params: params.clone(),
                agent: agent.name.clone(),
                wire: agent.wire,
            };
            let (remote_client, alleycat_session) =
                match crate::alleycat::connect_app_server_client(
                    params.clone(),
                    agent.name.clone(),
                    agent.wire,
                )
                .await
                {
                    Ok(result) => result,
                    Err(error) => {
                        warn!(
                            "MobileClient: alleycat connect failed server_id={} agent={} error={}",
                            server_id, agent.name, error
                        );
                        continue;
                    }
                };
            runtime_infos.push(AgentRuntimeInfo {
                kind: runtime_kind,
                name: agent.name.clone(),
                display_name: agent.display_name.clone(),
                available: true,
            });
            let trait_transport: Arc<dyn crate::session::remote_transport::RemoteTransport> =
                Arc::new(reconnect_transport);
            let keepalive: Arc<dyn Send + Sync> = alleycat_session as Arc<dyn Send + Sync>;
            runtime_resources.push(RuntimeRemoteSessionResource {
                runtime_kind,
                client: remote_client,
                transport: Some(trait_transport),
                keepalive: Some(keepalive),
            });
        }
        if runtime_resources.is_empty() {
            self.app_store
                .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
            return Err(TransportError::ConnectionFailed(
                "no available Alleycat runtime streams connected".to_string(),
            ));
        }

        info!(
            "MobileClient: alleycat building multiplexed session server_id={} runtime_kinds={:?}",
            server_id,
            runtime_resources
                .iter()
                .map(|r| r.runtime_kind)
                .collect::<Vec<_>>()
        );
        let session = match ServerSession::connect_remote_multiplexed(
            config,
            runtime_resources,
            RemoteSessionExtras::default(),
        )
        .await
        {
            Ok(session) => Arc::new(session),
            Err(error) => {
                warn!(
                    "MobileClient: alleycat app-server session failed server_id={} error={}",
                    server_id, error
                );
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                return Err(error);
            }
        };
        info!(
            "MobileClient: alleycat session ready server_id={} runtime_kinds={:?}",
            server_id,
            session.runtime_kinds()
        );

        self.attach_remote_session(&server_id, session, runtime_infos.clone());

        Ok(AlleycatConnectOutcome {
            server_id,
            node_id: params.node_id,
            agent_name: runtime_infos
                .iter()
                .map(|runtime| runtime.name.clone())
                .collect::<Vec<_>>()
                .join(","),
        })
    }

    pub async fn connect_remote_over_ssh_bridges(
        &self,
        ssh_client: Arc<SshClient>,
        server_id: String,
        display_name: String,
        host: String,
        state_root: String,
        runtime_kinds: Vec<AgentRuntimeKind>,
        transport: crate::ssh_bridge::SshBridgeTransport,
    ) -> Result<AlleycatConnectOutcome, TransportError> {
        if runtime_kinds.is_empty() {
            return Err(TransportError::ConnectionFailed(
                "no SSH runtime kinds selected".to_string(),
            ));
        }

        let visible_server_id = format!("ssh-bridge:{host}");
        let server_id = if server_id.starts_with(&visible_server_id) {
            visible_server_id
        } else {
            server_id
        };
        let config = ServerConfig {
            server_id: server_id.clone(),
            display_name,
            host: host.clone(),
            port: 0,
            websocket_url: Some(format!("ssh-bridge://{host}")),
            is_local: false,
            tls: false,
        };
        self.app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting, true);
        self.replace_existing_session(server_id.as_str()).await;

        let (runtime_resources, runtime_infos) =
            crate::ssh_bridge::connect_runtime_resources_via_ssh(
                ssh_client,
                state_root,
                runtime_kinds,
                transport,
                host.contains(':'),
            )
            .await
            .map_err(|error| TransportError::ConnectionFailed(error.to_string()))?;
        info!(
            "MobileClient: SSH bridge runtime resources ready server_id={} runtimes={:?} infos={:?}",
            server_id,
            runtime_resources
                .iter()
                .map(|resource| resource.runtime_kind)
                .collect::<Vec<_>>(),
            runtime_infos
        );
        if runtime_resources.is_empty() {
            self.app_store
                .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
            return Err(TransportError::ConnectionFailed(
                "no available SSH bridge runtime streams connected".to_string(),
            ));
        }

        let session = match ServerSession::connect_remote_multiplexed(
            config,
            runtime_resources,
            RemoteSessionExtras::default(),
        )
        .await
        {
            Ok(session) => Arc::new(session),
            Err(error) => {
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                return Err(error);
            }
        };
        info!(
            "MobileClient: SSH bridge session ready server_id={} runtime_kinds={:?}",
            server_id,
            session.runtime_kinds()
        );
        self.attach_remote_session(&server_id, session, runtime_infos.clone());

        Ok(AlleycatConnectOutcome {
            server_id,
            node_id: host,
            agent_name: runtime_infos
                .iter()
                .map(|runtime| runtime.name.clone())
                .collect::<Vec<_>>()
                .join(","),
        })
    }

    pub async fn connect_remote_over_ssh(
        &self,
        config: ServerConfig,
        ssh_credentials: SshCredentials,
        accept_unknown_host: bool,
        working_dir: Option<String>,
        ipc_socket_path_override: Option<String>,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        info!(
            "MobileClient: connect_remote_over_ssh start server_id={} host={} ssh_port={} accept_unknown_host={} working_dir={}",
            server_id,
            ssh_credentials.host.as_str(),
            ssh_credentials.port,
            accept_unknown_host,
            working_dir.as_deref().unwrap_or("<none>")
        );
        self.app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting, true);
        self.app_store.update_server_connection_progress(
            server_id.as_str(),
            Some(AppConnectionProgressSnapshot::ssh_bootstrap()),
        );
        // SSH-backed sessions depend on a local tunnel and optional IPC bridge
        // that may be torn down while the app is backgrounded even if the
        // session health never observed a clean disconnect. Prefer replacing
        // any existing session so resume can rebuild the full SSH transport.
        self.replace_existing_session(server_id.as_str()).await;

        let ssh_client = Arc::new(
            SshClient::connect(
                ssh_credentials.clone(),
                make_accept_unknown_host_callback(accept_unknown_host),
            )
            .await
            .map_err(map_ssh_transport_error)?,
        );
        info!(
            "MobileClient: SSH transport established server_id={} host={} ssh_port={}",
            config.server_id,
            ssh_credentials.host.as_str(),
            ssh_credentials.port
        );

        let use_ipv6 = config.host.contains(':');
        let bootstrap = match ssh_client
            .bootstrap_codex_server(working_dir.as_deref(), use_ipv6)
            .await
        {
            Ok(result) => result,
            Err(error) => {
                warn!(
                    "remote ssh bootstrap failed server={} error={}",
                    config.server_id, error
                );
                warn!(
                    "MobileClient: remote ssh bootstrap failed server_id={} host={} error={}",
                    config.server_id,
                    ssh_credentials.host.as_str(),
                    error
                );
                ssh_client.disconnect().await;
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                self.app_store
                    .update_server_connection_progress(server_id.as_str(), None);
                return Err(map_ssh_transport_error(error));
            }
        };
        info!(
            "MobileClient: remote ssh bootstrap succeeded server_id={} host={} remote_port={} local_tunnel_port={} pid={:?}",
            config.server_id,
            ssh_credentials.host.as_str(),
            bootstrap.server_port,
            bootstrap.tunnel_local_port,
            bootstrap.pid
        );

        let result = self
            .finish_connect_remote_over_ssh(
                config,
                ssh_credentials,
                accept_unknown_host,
                ssh_client,
                bootstrap,
                working_dir,
                ipc_socket_path_override,
            )
            .await;
        match &result {
            Ok(_) => {
                self.app_store
                    .update_server_connection_progress(server_id.as_str(), None);
            }
            Err(_) => {
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                self.app_store
                    .update_server_connection_progress(server_id.as_str(), None);
            }
        }
        result
    }

    pub(crate) async fn finish_connect_remote_over_ssh(
        &self,
        mut config: ServerConfig,
        ssh_credentials: SshCredentials,
        _accept_unknown_host: bool,
        ssh_client: Arc<SshClient>,
        bootstrap: SshBootstrapResult,
        working_dir: Option<String>,
        ipc_socket_path_override: Option<String>,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        trace!(
            "MobileClient: finish_connect_remote_over_ssh start server_id={} host={} bootstrap_remote_port={} bootstrap_local_port={} pid={:?} ipc_socket_path_override={}",
            server_id,
            ssh_credentials.host.as_str(),
            bootstrap.server_port,
            bootstrap.tunnel_local_port,
            bootstrap.pid,
            ipc_socket_path_override.as_deref().unwrap_or("<none>")
        );

        config.port = bootstrap.server_port;
        config.websocket_url = Some(format!("ws://127.0.0.1:{}", bootstrap.tunnel_local_port));
        config.is_local = false;
        config.tls = false;
        let ssh_pid = Arc::new(StdMutex::new(bootstrap.pid));
        let ssh_reconnect_transport = SshReconnectTransport {
            ssh_client: Arc::clone(&ssh_client),
            local_port: bootstrap.tunnel_local_port,
            remote_port: Arc::new(StdMutex::new(bootstrap.server_port)),
            prefer_ipv6: config.host.contains(':'),
            working_dir,
            ssh_pid: Some(Arc::clone(&ssh_pid)),
        };

        let ipc_enabled = ipc_socket_path_override
            .as_deref()
            .is_none_or(|path| !path.trim().is_empty());
        let ipc_stream_bridge_pid = ipc_enabled.then(|| Arc::new(StdMutex::new(None)));
        let ipc_stream_client = if ipc_enabled {
            Some(start_remote_reconnecting_ipc_client(
                Arc::clone(&ssh_client),
                config.server_id.clone(),
                ipc_socket_path_override.clone(),
                ipc_stream_bridge_pid.as_ref().map(Arc::clone),
                "stream",
            ))
        } else {
            None
        };
        trace!(
            "MobileClient: finish_connect_remote_over_ssh IPC attach result server_id={} attached={}",
            server_id,
            ipc_stream_client
                .as_ref()
                .is_some_and(|client| client.is_connected())
        );

        // Eagerly establish the WebSocket-over-SSH-tunnel client now that the
        // forward is up. Surfacing connect errors here matches the eager-connect
        // semantics used by `connect_remote_over_alleycat` and the multi-runtime
        // SSH-bridges path, so `connect_remote_multiplexed` only sees populated
        // clients.
        let (_, connect_args) = crate::session::connection::remote_connect_args(&config);
        let initial_client = match crate::session::connection::connect_remote_client(&connect_args)
            .await
        {
            Ok(client) => client,
            Err(error) => {
                warn!(
                    "MobileClient: remote ssh websocket connect failed server_id={} host={} error={}",
                    server_id,
                    ssh_credentials.host.as_str(),
                    error
                );
                ssh_client.disconnect().await;
                return Err(error);
            }
        };
        let trait_transport: Arc<dyn crate::session::remote_transport::RemoteTransport> =
            Arc::new(ssh_reconnect_transport);
        let resource = RuntimeRemoteSessionResource {
            runtime_kind: crate::types::AgentRuntimeKind::Codex,
            client: initial_client,
            transport: Some(trait_transport),
            keepalive: None,
        };
        let extras = RemoteSessionExtras {
            ssh_client: Some(Arc::clone(&ssh_client)),
            ssh_pid: Some(Arc::clone(&ssh_pid)),
            ipc_stream_client,
            ipc_ssh_client: None,
            ipc_stream_bridge_pid,
        };
        let session = match ServerSession::connect_remote_multiplexed(
            config,
            vec![resource],
            extras,
        )
        .await
        {
            Ok(session) => Arc::new(session),
            Err(error) => {
                warn!(
                    "remote ssh session connect failed server={} error={}",
                    server_id, error
                );
                warn!(
                    "MobileClient: remote ssh session connect failed server_id={} host={} error={}",
                    server_id,
                    ssh_credentials.host.as_str(),
                    error
                );
                ssh_client.disconnect().await;
                return Err(error);
            }
        };

        trace!(
            "MobileClient: finish_connect_remote_over_ssh session connected server_id={} websocket_url={}",
            server_id,
            session
                .config()
                .websocket_url
                .as_deref()
                .unwrap_or("<none>")
        );
        let codex_runtime_info = AgentRuntimeInfo {
            kind: crate::types::AgentRuntimeKind::Codex,
            name: "codex".to_string(),
            display_name: "Codex".to_string(),
            available: true,
        };
        self.attach_remote_session(&server_id, session, vec![codex_runtime_info]);

        info!("MobileClient: connected remote SSH server {server_id}");
        Ok(server_id)
    }

    /// Disconnect a server by its ID.
    ///
    /// Always clears the server from the app store snapshot and drops any
    /// OAuth callback tunnel, even when no live session exists (e.g. the
    /// server was already disconnected or never connected this launch).
    /// Otherwise removing a disconnected server pill from the UI would be a
    /// no-op because the snapshot would still carry it.
    pub fn disconnect_server(&self, server_id: &str) {
        let session = self.sessions_write().remove(server_id);
        self.clear_direct_resume_markers_for_server(server_id);
        self.app_store.remove_server(server_id);

        let inner = Arc::clone(&self.oauth_callback_tunnels);
        let server_id_owned = server_id.to_string();
        Self::spawn_detached(async move {
            inner.lock().await.remove(&server_id_owned);
            if let Some(session) = session {
                session.disconnect().await;
            }
        });
        info!("MobileClient: disconnected server {server_id}");
    }

    pub async fn restart_app_server(&self, server_id: &str) -> Result<(), TransportError> {
        self.clear_oauth_callback_tunnel(server_id).await;
        let session = self.sessions_write().remove(server_id);
        self.clear_direct_resume_markers_for_server(server_id);
        self.app_store.remove_server(server_id);
        let Some(session) = session else {
            return Err(TransportError::Disconnected);
        };

        info!("MobileClient: restarting app server {server_id}");
        session.restart_app_server_and_disconnect().await;
        Ok(())
    }

    /// Return the configs of all currently connected servers.
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) fn connected_servers(&self) -> Vec<ServerConfig> {
        self.sessions_read()
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    // ── Threads ───────────────────────────────────────────────────────

    /// List threads from a specific server.
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) async fn list_threads(&self, server_id: &str) -> Result<Vec<ThreadInfo>, RpcError> {
        self.get_session(server_id)?;
        let response = self
            .server_thread_list(
                server_id,
                upstream::ThreadListParams {
                    limit: None,
                    cursor: None,
                    sort_key: None,
                    sort_direction: None,
                    model_providers: None,
                    source_kinds: None,
                    archived: None,
                    cwd: None,
                    search_term: None,
                    use_state_db_only: false,
                },
            )
            .await
            .map_err(map_rpc_client_error)?;
        let threads = response
            .data
            .into_iter()
            .filter_map(thread_info_from_upstream_thread)
            .collect::<Vec<_>>();
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(threads)
    }

    pub async fn sync_server_account(&self, server_id: &str) -> Result<(), RpcError> {
        self.get_session(server_id)?;
        let response = self
            .server_get_account(
                server_id,
                upstream::GetAccountParams {
                    refresh_token: false,
                },
            )
            .await
            .map_err(map_rpc_client_error)?;
        self.apply_account_response(server_id, &response);
        Ok(())
    }

    fn spawn_post_connect_warmup(&self, server_id: String, session: Arc<ServerSession>) {
        run_connect_warmup(
            Arc::clone(&self.sessions),
            Arc::clone(&self.app_store),
            server_id,
            session,
            "post-connect",
        );
    }

    pub async fn start_remote_ssh_oauth_login(&self, server_id: &str) -> Result<String, RpcError> {
        let session = self.get_session(server_id)?;
        if session.config().is_local {
            return Err(RpcError::Transport(TransportError::ConnectionFailed(
                "remote SSH OAuth is only available for remote servers".to_string(),
            )));
        }
        let ssh_client = session.ssh_client().ok_or_else(|| {
            RpcError::Transport(TransportError::ConnectionFailed(
                "remote ChatGPT login requires an SSH-backed connection".to_string(),
            ))
        })?;

        let params = upstream::LoginAccountParams::Chatgpt;
        let response = self
            .request_typed_for_server::<upstream::LoginAccountResponse>(
                server_id,
                upstream::ClientRequest::LoginAccount {
                    request_id: upstream::RequestId::Integer(crate::next_request_id()),
                    params,
                },
            )
            .await
            .map_err(RpcError::Deserialization)?;
        self.reconcile_public_rpc(
            "account/login/start",
            server_id,
            Option::<&()>::None,
            &response,
        )
        .await?;

        let upstream::LoginAccountResponse::Chatgpt { login_id, auth_url } = response else {
            return Err(RpcError::Deserialization(
                "expected ChatGPT login response for remote SSH OAuth".to_string(),
            ));
        };

        let callback_port = remote_oauth_callback_port(&auth_url)?;
        self.clear_oauth_callback_tunnel(server_id).await;
        if let Err(error) = ssh_client
            .ensure_forward_port_to(callback_port, "127.0.0.1", callback_port)
            .await
        {
            let _ = self
                .request_typed_for_server::<upstream::CancelLoginAccountResponse>(
                    server_id,
                    upstream::ClientRequest::CancelLoginAccount {
                        request_id: upstream::RequestId::Integer(crate::next_request_id()),
                        params: upstream::CancelLoginAccountParams {
                            login_id: login_id.clone(),
                        },
                    },
                )
                .await;
            return Err(RpcError::Transport(TransportError::ConnectionFailed(
                format!(
                    "failed to open localhost callback tunnel on port {callback_port}: {error}"
                ),
            )));
        }
        self.replace_oauth_callback_tunnel(server_id, &login_id, callback_port)
            .await;
        Ok(auth_url)
    }

    pub async fn external_resume_thread(
        &self,
        server_id: &str,
        thread_id: &str,
        host_id: Option<String>,
    ) -> Result<(), RpcError> {
        let session = self.get_session(server_id)?;
        if self.app_store.server_transport_authority(server_id)
            == Some(ServerTransportAuthority::DirectOnly)
            && !self.app_store.server_has_active_turns(server_id)
        {
            self.app_store.mark_server_ipc_recovering(server_id);
            if session.has_ipc() {
                info!(
                    "IPC recovery: invalidating server={} before explicit thread reopen",
                    server_id
                );
                session.invalidate_ipc();
            }
        }
        if host_id.is_some() {
            trace!(
                "IPC out: external_resume_thread ignoring explicit host_id for server={} thread={}",
                server_id, thread_id
            );
        }
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };

        // If the server has live IPC and the thread already exists in the store
        // with populated data, skip the RPC — IPC broadcasts are already keeping
        // the thread state up to date.  This is the "passive IPC open" path that
        // was previously handled in platform code (Swift/Kotlin).
        if server_has_live_ipc(&self.app_store, server_id, &session) {
            let thread_exists_with_data = self
                .app_store
                .snapshot()
                .threads
                .get(&key)
                .is_some_and(|t| !t.items.is_empty());
            if thread_exists_with_data {
                debug!(
                    "external_resume_thread: skipping RPC for server={} thread={} — IPC is live and thread data exists in store",
                    server_id, thread_id
                );
                self.app_store.mark_thread_resumed(&key, true);
                return Ok(());
            }
            debug!(
                "external_resume_thread: IPC live but thread not in store, falling back to thread/read for server={} thread={}",
                server_id, thread_id
            );
        }
        if self.has_direct_resume_marker(&key) {
            let thread_has_loaded_turns = self
                .app_store
                .thread_snapshot(&key)
                .is_some_and(|thread| !thread.items.is_empty() || thread.initial_turns_loaded);
            if thread_has_loaded_turns {
                debug!(
                    "external_resume_thread: skipping RPC for server={} thread={} — direct listener already attached for current session",
                    server_id, thread_id
                );
                self.app_store.mark_thread_resumed(&key, true);
                return Ok(());
            }
            debug!(
                "external_resume_thread: direct listener exists but thread has no loaded turns, refreshing server={} thread={}",
                server_id, thread_id
            );
        }
        let mut runtime_candidates = vec![self.runtime_for_thread(&key)];
        for runtime_kind in session.runtime_kinds() {
            if !runtime_candidates.contains(&runtime_kind) {
                runtime_candidates.push(runtime_kind);
            }
        }
        if !runtime_candidates.contains(&AgentRuntimeKind::Codex) {
            runtime_candidates.push(AgentRuntimeKind::Codex);
        }

        let mut lookup_errors = Vec::new();
        for runtime_kind in runtime_candidates.iter().copied() {
            let exclude_turns = self.app_store.server_supports_turn_pagination(server_id);
            match self
                .resume_thread_for_runtime(server_id, thread_id, &key, runtime_kind, exclude_turns)
                .await
            {
                Ok(()) => {
                    self.note_thread_runtime(key.clone(), runtime_kind);
                    return Ok(());
                }
                Err(error) if should_try_next_runtime_after_thread_lookup_error(&error) => {
                    info!(
                        "external_resume_thread: thread lookup missed runtime {:?} server={} thread={}: {}",
                        runtime_kind, server_id, thread_id, error
                    );
                    lookup_errors.push((runtime_kind, error));
                }
                Err(error) if should_fallback_to_thread_metadata_after_resume_error(&error) => {
                    warn!(
                        "external_resume_thread: resume failed, falling back to metadata-only thread/read runtime={:?} server={} thread={} error={}",
                        runtime_kind, server_id, thread_id, error
                    );
                    self.read_thread_metadata_only_for_runtime(server_id, thread_id, runtime_kind)
                        .await
                        .map_err(|fallback_error| {
                            RpcError::Deserialization(format!(
                                "{error}; metadata fallback failed: {fallback_error}"
                            ))
                        })?;
                    self.note_thread_runtime(key.clone(), runtime_kind);
                    return Ok(());
                }
                Err(error) => return Err(RpcError::Deserialization(error)),
            }
        }

        for (runtime_kind, resume_error) in lookup_errors {
            match self
                .read_thread_metadata_only_for_runtime(server_id, thread_id, runtime_kind)
                .await
            {
                Ok(()) => {
                    self.note_thread_runtime(key.clone(), runtime_kind);
                    return Ok(());
                }
                Err(fallback_error)
                    if should_try_next_runtime_after_thread_lookup_error(
                        &fallback_error.to_string(),
                    ) =>
                {
                    info!(
                        "external_resume_thread: metadata lookup missed runtime {:?} server={} thread={}: {}",
                        runtime_kind, server_id, thread_id, fallback_error
                    );
                }
                Err(fallback_error) => {
                    return Err(RpcError::Deserialization(format!(
                        "{resume_error}; metadata fallback failed: {fallback_error}"
                    )));
                }
            }
        }

        Err(RpcError::Deserialization(format!(
            "thread {thread_id} was not found in any registered runtime for server {server_id}"
        )))
    }

    async fn resume_thread_for_runtime(
        &self,
        server_id: &str,
        thread_id: &str,
        key: &ThreadKey,
        runtime_kind: AgentRuntimeKind,
        exclude_turns: bool,
    ) -> Result<(), String> {
        // Use thread/resume (not thread/read) so the server attaches a
        // conversation listener for this connection. Without the listener
        // the WebSocket client only receives ThreadStatusChanged — no
        // TurnStarted, ItemStarted, MessageDelta, or TurnCompleted events.
        let resume_request = upstream::ClientRequest::ThreadResume {
            request_id: upstream::RequestId::Integer(crate::next_request_id()),
            params: upstream::ThreadResumeParams {
                thread_id: thread_id.to_string(),
                developer_instructions:
                    crate::local_runtime_instructions::splice_local_runtime_developer_instructions(
                        self, server_id, None,
                    ),
                exclude_turns,
                ..Default::default()
            },
        };
        let response = self
            .request_typed_for_server_runtime::<upstream::ThreadResumeResponse>(
                server_id,
                runtime_kind,
                resume_request,
            )
            .await?;
        let existing = self.app_store.thread_snapshot(key);
        // Diagnostic for the pagination-cursor-lost bug (task #13):
        // capture what we read as `existing` BEFORE overwriting, so
        // logcat shows whether the cursor was present at the moment
        // resume reconciles.
        tracing::info!(
            target: "store",
            server_id,
            thread_id,
            existing_present = existing.is_some(),
            existing_items = existing.as_ref().map(|e| e.items.len()).unwrap_or(0),
            existing_older_turns_cursor = existing
                .as_ref()
                .and_then(|e| e.older_turns_cursor.clone())
                .unwrap_or_default(),
            existing_initial_turns_loaded = existing
                .as_ref()
                .map(|e| e.initial_turns_loaded)
                .unwrap_or(false),
            "external_resume_thread existing snapshot"
        );
        let turns = response.thread.turns.clone();
        let server_honored_exclude_turns = exclude_turns && turns.is_empty();
        // Legacy v0.124 remotes ignore `exclude_turns` and return the
        // full embedded turn history. Flip the capability flag so
        // future code paths (load_thread_turns_page) short-circuit
        // and the UI keeps relying on embedded turns.
        if !server_honored_exclude_turns {
            self.app_store
                .set_server_supports_turn_pagination(server_id, false);
        }
        let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread,
            Some(response.model),
            response
                .reasoning_effort
                .map(Into::into)
                .map(reasoning_effort_string),
            Some(response.approval_policy.into()),
            Some(response.sandbox.into()),
        )?;
        snapshot.agent_runtime_kind = runtime_kind;
        // Preserve existing store items when the server returned empty turns
        // (paginated path); mark initial_turns_loaded so the UI spinner knows
        // to wait for load_thread_turns_page.
        if server_honored_exclude_turns {
            if let Some(current) = existing.as_ref() {
                snapshot.items = current.items.clone();
                snapshot.older_turns_cursor = current.older_turns_cursor.clone();
                snapshot.initial_turns_loaded = current.initial_turns_loaded;
            } else {
                snapshot.initial_turns_loaded = false;
            }
        } else {
            snapshot.initial_turns_loaded = true;
            snapshot.older_turns_cursor = None;
        }
        reconcile_active_turn(existing.as_ref(), &mut snapshot, &turns);
        snapshot.is_resumed = true;
        self.app_store.upsert_thread_snapshot(snapshot);
        self.mark_direct_resumed_thread(key.clone());
        Ok(())
    }

    /// Composite action: page a thread's older turns via `thread/turns/list`
    /// and merge them into the canonical store.
    ///
    /// - When the server is known to not support pagination
    ///   (`supports_turn_pagination == false`), refreshes an empty/unloaded
    ///   thread with an embedded-turn resume. Already-loaded threads still
    ///   short-circuit because their embedded turns are already in the store.
    /// - When the RPC comes back as JSON-RPC -32601 (method not found),
    ///   flips `supports_turn_pagination = false` on the server snapshot
    ///   and returns the same short-circuit result.
    /// - On success, invokes the `apply_thread_turns_page` reducer.
    pub async fn load_thread_turns_page(
        &self,
        server_id: &str,
        thread_id: &str,
        cursor: Option<String>,
        limit: Option<u32>,
    ) -> Result<crate::types::AppLoadThreadTurnsOutcome, RpcError> {
        if !self.app_store.server_supports_turn_pagination(server_id) {
            let key = ThreadKey {
                server_id: server_id.to_string(),
                thread_id: thread_id.to_string(),
            };
            let needs_embedded_resume = self
                .app_store
                .thread_snapshot(&key)
                .is_none_or(|thread| thread.items.is_empty() && !thread.initial_turns_loaded);
            if needs_embedded_resume {
                let runtime_kind = self.runtime_for_thread(&key);
                self.resume_thread_for_runtime(server_id, thread_id, &key, runtime_kind, false)
                    .await
                    .map_err(RpcError::Deserialization)?;
                return Ok(crate::types::AppLoadThreadTurnsOutcome {
                    loaded: true,
                    has_more: false,
                });
            }
            return Ok(crate::types::AppLoadThreadTurnsOutcome {
                loaded: false,
                has_more: false,
            });
        }
        let params = upstream::ThreadTurnsListParams {
            thread_id: thread_id.to_string(),
            cursor,
            limit,
            sort_direction: Some(upstream::SortDirection::Desc),
        };
        let request = upstream::ClientRequest::ThreadTurnsList {
            request_id: upstream::RequestId::Integer(crate::next_request_id()),
            params,
        };
        match self
            .request_typed_for_server::<upstream::ThreadTurnsListResponse>(server_id, request)
            .await
        {
            Ok(response) => {
                let has_more = response.next_cursor.is_some();
                let page: crate::types::AppListThreadTurnsResponse = response.into();
                self.apply_thread_turns_page(
                    server_id,
                    thread_id,
                    &page,
                    crate::types::AppTurnsSortDirection::Descending,
                )
                .map_err(RpcError::Deserialization)?;
                Ok(crate::types::AppLoadThreadTurnsOutcome {
                    loaded: true,
                    has_more,
                })
            }
            Err(error) if is_method_not_found(&error) => {
                self.app_store
                    .set_server_supports_turn_pagination(server_id, false);
                let key = ThreadKey {
                    server_id: server_id.to_string(),
                    thread_id: thread_id.to_string(),
                };
                let runtime_kind = self.runtime_for_thread(&key);
                self.resume_thread_for_runtime(server_id, thread_id, &key, runtime_kind, false)
                    .await
                    .map_err(RpcError::Deserialization)?;
                Ok(crate::types::AppLoadThreadTurnsOutcome {
                    loaded: true,
                    has_more: false,
                })
            }
            Err(error) => Err(RpcError::Deserialization(error)),
        }
    }

    async fn read_thread_metadata_only_for_runtime(
        &self,
        server_id: &str,
        thread_id: &str,
        runtime_kind: AgentRuntimeKind,
    ) -> Result<(), RpcError> {
        let response: upstream::ThreadReadResponse = self
            .request_typed_for_server_runtime(
                server_id,
                runtime_kind,
                upstream::ClientRequest::ThreadRead {
                    request_id: upstream::RequestId::Integer(crate::next_request_id()),
                    params: upstream::ThreadReadParams {
                        thread_id: thread_id.to_string(),
                        include_turns: false,
                    },
                },
            )
            .await
            .map_err(RpcError::Deserialization)?;
        upsert_thread_snapshot_from_app_server_read_response(&self.app_store, server_id, response)
    }

    pub async fn thread_unsubscribe(
        &self,
        server_id: &str,
        thread_id: &str,
    ) -> Result<(), RpcError> {
        self.get_session(server_id)?;
        let _: upstream::ThreadUnsubscribeResponse = self
            .request_typed_for_server(
                server_id,
                upstream::ClientRequest::ThreadUnsubscribe {
                    request_id: upstream::RequestId::Integer(crate::next_request_id()),
                    params: upstream::ThreadUnsubscribeParams {
                        thread_id: thread_id.to_string(),
                    },
                },
            )
            .await
            .map_err(RpcError::Deserialization)?;
        self.direct_resumed_threads().remove(&ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        });
        self.app_store.mark_thread_resumed(
            &ThreadKey {
                server_id: server_id.to_string(),
                thread_id: thread_id.to_string(),
            },
            false,
        );
        Ok(())
    }

    pub async fn start_turn(
        &self,
        server_id: &str,
        params: upstream::TurnStartParams,
    ) -> Result<(), RpcError> {
        let session = self.get_session(server_id)?;
        let mut params = params;
        let thread_key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: params.thread_id.clone(),
        };
        self.app_store
            .dismiss_plan_implementation_prompt(&thread_key);
        let thread_snapshot = self.snapshot_thread(&thread_key).ok();
        if let Some(thread) = thread_snapshot.as_ref()
            && thread.collaboration_mode == AppModeKind::Plan
            && params.collaboration_mode.is_none()
        {
            params.collaboration_mode = collaboration_mode_from_thread(
                thread,
                AppModeKind::Plan,
                params.model.clone(),
                params.effort,
            );
        }
        let has_active_turn = thread_snapshot
            .as_ref()
            .is_some_and(|thread| thread.active_turn_id.is_some());
        let direct_params = params.clone();
        let has_live_ipc = server_has_live_ipc(&self.app_store, server_id, &session);
        // Stage an optimistic local overlay so the user sees their message
        // immediately, before the server echoes it back.
        let optimistic_overlay_id = if !has_active_turn {
            self.app_store
                .stage_local_user_message_overlay(&thread_key, &params.input)
        } else {
            None
        };
        let queued_draft = has_active_turn
            .then(|| {
                queued_follow_up_draft_from_inputs(&params.input, AppQueuedFollowUpKind::Message)
            })
            .flatten();
        let queued_follow_up_command_id =
            queued_draft.as_ref().filter(|_| has_live_ipc).map(|_| {
                self.app_store.begin_server_mutating_command(
                    server_id,
                    ServerMutatingCommandKind::SetQueuedFollowUpsState,
                    &params.thread_id,
                    ServerMutatingCommandRoute::Ipc,
                )
            });
        if let Some(draft) = queued_draft.clone() {
            self.app_store
                .enqueue_thread_follow_up_draft(&thread_key, draft.clone());

            if has_live_ipc {
                let mut next_drafts = thread_snapshot
                    .as_ref()
                    .map(|thread| thread.queued_follow_up_drafts.clone())
                    .unwrap_or_default();
                next_drafts.push(draft);
                let thread_id = params.thread_id.clone();
                info!(
                    "IPC out: set_queued_follow_ups_state server={} thread={}",
                    server_id, thread_id
                );
                let ipc_thread_id = thread_id.clone();
                let ipc_state = queued_follow_up_state_json_from_drafts(&next_drafts);
                let ipc_result = run_ipc_command(&session, move |ipc_client| async move {
                    ipc_client
                        .set_queued_follow_ups_state(
                            codex_ipc::ThreadFollowerSetQueuedFollowUpsStateParams {
                                conversation_id: ipc_thread_id,
                                state: ipc_state,
                            },
                        )
                        .await
                })
                .await;
                match ipc_result {
                    Ok(Some(_)) => {
                        if let Some(command_id) = queued_follow_up_command_id.as_deref() {
                            self.app_store.finish_server_mutating_command_success(
                                server_id,
                                command_id,
                                ServerMutatingCommandRoute::Ipc,
                            );
                        }
                        debug!(
                            "IPC out: set_queued_follow_ups_state ok server={} thread={}",
                            server_id, thread_id
                        );
                        return Ok(());
                    }
                    Ok(None) => {}
                    Err(error) => {
                        warn!(
                            "MobileClient: IPC queued follow-up update failed for {} thread {}: {} ({})",
                            server_id,
                            thread_id,
                            error,
                            ipc_command_error_context(&error)
                        );
                        if should_fail_over_server_after_ipc_mutation_error(&error) {
                            let classification = fail_server_over_from_ipc_mutation(
                                &self.app_store,
                                &session,
                                server_id,
                                &error,
                            );
                            warn!(
                                "MobileClient: server {} failed over to direct-only after queued follow-up IPC failure: {:?}",
                                server_id, classification
                            );
                        } else if !should_fall_back_to_direct_after_ipc_mutation_error(&error) {
                            return Err(RpcError::Deserialization(format!(
                                "IPC queued follow-up update: {error}"
                            )));
                        }
                    }
                }
            }
            // In direct-only mode (no IPC), the draft was enqueued locally
            // for UI feedback but we still need to steer/start the turn below.
        }

        if queued_draft.is_none() && has_live_ipc {
            let thread_id = params.thread_id.clone();
            let command_id = self.app_store.begin_server_mutating_command(
                server_id,
                ServerMutatingCommandKind::StartTurn,
                &thread_id,
                ServerMutatingCommandRoute::Ipc,
            );
            info!(
                "IPC out: start_turn server={} thread={}",
                server_id, thread_id
            );
            let ipc_thread_id = thread_id.clone();
            let ipc_params = params.clone();
            let ipc_result = run_ipc_command(&session, move |ipc_client| async move {
                ipc_client
                    .start_turn(ThreadFollowerStartTurnParams {
                        conversation_id: ipc_thread_id,
                        turn_start_params: ipc_params,
                    })
                    .await
            })
            .await;
            match ipc_result {
                Ok(Some(_)) => {
                    self.app_store.finish_server_mutating_command_success(
                        server_id,
                        &command_id,
                        ServerMutatingCommandRoute::Ipc,
                    );
                    debug!(
                        "IPC out: start_turn ok server={} thread={}",
                        server_id, thread_id
                    );
                    return Ok(());
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC follower start turn failed for {} thread {}: {} ({})",
                        server_id,
                        thread_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if should_fail_over_server_after_ipc_mutation_error(&error) {
                        let classification = fail_server_over_from_ipc_mutation(
                            &self.app_store,
                            &session,
                            server_id,
                            &error,
                        );
                        warn!(
                            "MobileClient: server {} failed over to direct-only after start_turn IPC failure: {:?}",
                            server_id, classification
                        );
                    } else if !should_fall_back_to_direct_after_ipc_mutation_error(&error) {
                        return Err(RpcError::Deserialization(format!(
                            "IPC follower start turn: {error}"
                        )));
                    }
                }
            }
        }

        // If there's an active turn and we didn't queue a follow-up draft,
        // try turn/steer first (injects input into the running turn).
        // When a draft was queued, the user can Steer it or it will auto-send
        // when the turn finishes.  Don't also auto-steer here.
        if queued_draft.is_some() {
            return Ok(());
        }

        // If there's an active turn, try turn/steer first (injects input
        // into the running turn).  Fall back to turn/start if the turn is
        // no longer steerable or has already finished.
        if let Some(active_turn_id) = thread_snapshot
            .as_ref()
            .and_then(|t| t.active_turn_id.clone())
        {
            let steer_result = self
                .request_typed_for_server::<upstream::TurnSteerResponse>(
                    server_id,
                    upstream::ClientRequest::TurnSteer {
                        request_id: upstream::RequestId::Integer(crate::next_request_id()),
                        params: upstream::TurnSteerParams {
                            thread_id: params.thread_id.clone(),
                            input: direct_params.input.clone(),
                            responsesapi_client_metadata: None,
                            expected_turn_id: active_turn_id,
                        },
                    },
                )
                .await;
            match steer_result {
                Ok(_) => {
                    // Draft cleanup happens via TurnStarted / item upsert;
                    // don't remove here so the user sees the queued preview.
                    return Ok(());
                }
                Err(_) => {
                    // Turn not steerable or gone — fall through to turn/start.
                }
            }
        }

        let direct_command_id = self.app_store.begin_server_mutating_command(
            server_id,
            if queued_draft.is_some() {
                ServerMutatingCommandKind::SetQueuedFollowUpsState
            } else {
                ServerMutatingCommandKind::StartTurn
            },
            &params.thread_id,
            ServerMutatingCommandRoute::Direct,
        );
        let response = self
            .request_typed_for_server::<upstream::TurnStartResponse>(
                server_id,
                upstream::ClientRequest::TurnStart {
                    request_id: upstream::RequestId::Integer(crate::next_request_id()),
                    params: direct_params,
                },
            )
            .await
            .map_err(|error| {
                if let Some(overlay_id) = optimistic_overlay_id.as_ref() {
                    self.app_store
                        .remove_local_overlay_item(&thread_key, overlay_id);
                }
                if let Some(draft) = queued_draft.as_ref() {
                    self.app_store
                        .remove_thread_follow_up_draft(&thread_key, &draft.preview.id);
                }
                RpcError::Deserialization(error)
            })?;
        self.app_store.finish_server_mutating_command_success(
            server_id,
            &direct_command_id,
            ServerMutatingCommandRoute::Direct,
        );
        if let Some(overlay_id) = optimistic_overlay_id.as_ref() {
            self.app_store.bind_local_user_message_overlay_to_turn(
                &thread_key,
                overlay_id,
                &response.turn.id,
            );
        }
        Ok(())
    }

    pub async fn steer_queued_follow_up(
        &self,
        key: &ThreadKey,
        preview_id: &str,
    ) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        let Some(draft) = thread
            .queued_follow_up_drafts
            .iter()
            .find(|draft| draft.preview.id == preview_id)
            .cloned()
        else {
            return Err(RpcError::Deserialization(format!(
                "queued follow-up not found: {preview_id}"
            )));
        };

        if server_has_live_ipc(&self.app_store, &key.server_id, &session) {
            let next_drafts = thread
                .queued_follow_up_drafts
                .into_iter()
                .map(|mut queued| {
                    if queued.preview.id == preview_id {
                        queued.preview.kind = AppQueuedFollowUpKind::PendingSteer;
                    }
                    queued
                })
                .collect::<Vec<_>>();
            let command_id = self.app_store.begin_server_mutating_command(
                &key.server_id,
                ServerMutatingCommandKind::SteerQueuedFollowUp,
                &key.thread_id,
                ServerMutatingCommandRoute::Ipc,
            );
            let ipc_state = queued_follow_up_state_json_from_drafts(&next_drafts);
            match run_ipc_command(&session, move |ipc_client| async move {
                ipc_client
                    .set_queued_follow_ups_state(
                        codex_ipc::ThreadFollowerSetQueuedFollowUpsStateParams {
                            conversation_id: key.thread_id.clone(),
                            state: ipc_state,
                        },
                    )
                    .await
            })
            .await
            {
                Ok(Some(_)) => {
                    self.app_store.finish_server_mutating_command_success(
                        &key.server_id,
                        &command_id,
                        ServerMutatingCommandRoute::Ipc,
                    );
                    self.app_store.set_thread_follow_up_drafts(key, next_drafts);
                    return Ok(());
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC steer queued follow-up failed for {} thread {}: {} ({})",
                        key.server_id,
                        key.thread_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if should_fail_over_server_after_ipc_mutation_error(&error) {
                        let classification = fail_server_over_from_ipc_mutation(
                            &self.app_store,
                            &session,
                            &key.server_id,
                            &error,
                        );
                        warn!(
                            "MobileClient: server {} failed over to direct-only after steer queued follow-up IPC failure: {:?}",
                            key.server_id, classification
                        );
                    } else if !should_fall_back_to_direct_after_ipc_mutation_error(&error) {
                        return Err(RpcError::Deserialization(format!(
                            "IPC steer queued follow-up: {error}"
                        )));
                    }
                }
            }
        }

        let active_turn_id = thread.active_turn_id.ok_or_else(|| {
            RpcError::Deserialization("no active turn available to steer".to_string())
        })?;

        // Mark as pending-steer immediately so the UI reflects the tap.
        self.app_store.update_thread_follow_up_draft_kind(
            key,
            preview_id,
            AppQueuedFollowUpKind::PendingSteer,
        );

        let direct_command_id = self.app_store.begin_server_mutating_command(
            &key.server_id,
            ServerMutatingCommandKind::SteerQueuedFollowUp,
            &key.thread_id,
            ServerMutatingCommandRoute::Direct,
        );
        self.request_typed_for_server::<upstream::TurnSteerResponse>(
            &key.server_id,
            upstream::ClientRequest::TurnSteer {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: upstream::TurnSteerParams {
                    thread_id: key.thread_id.clone(),
                    input: draft.inputs,
                    responsesapi_client_metadata: None,
                    expected_turn_id: active_turn_id,
                },
            },
        )
        .await
        .map_err(RpcError::Deserialization)?;
        self.app_store.finish_server_mutating_command_success(
            &key.server_id,
            &direct_command_id,
            ServerMutatingCommandRoute::Direct,
        );
        // Keep draft visible as PendingSteer; TurnCompleted will clean it up.
        Ok(())
    }

    pub async fn delete_queued_follow_up(
        &self,
        key: &ThreadKey,
        preview_id: &str,
    ) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        let next_drafts = thread
            .queued_follow_up_drafts
            .into_iter()
            .filter(|draft| draft.preview.id != preview_id)
            .collect::<Vec<_>>();

        if server_has_live_ipc(&self.app_store, &key.server_id, &session) {
            let command_id = self.app_store.begin_server_mutating_command(
                &key.server_id,
                ServerMutatingCommandKind::DeleteQueuedFollowUp,
                &key.thread_id,
                ServerMutatingCommandRoute::Ipc,
            );
            let ipc_state = queued_follow_up_state_json_from_drafts(&next_drafts);
            match run_ipc_command(&session, move |ipc_client| async move {
                ipc_client
                    .set_queued_follow_ups_state(
                        codex_ipc::ThreadFollowerSetQueuedFollowUpsStateParams {
                            conversation_id: key.thread_id.clone(),
                            state: ipc_state,
                        },
                    )
                    .await
            })
            .await
            {
                Ok(Some(_)) => {
                    self.app_store.finish_server_mutating_command_success(
                        &key.server_id,
                        &command_id,
                        ServerMutatingCommandRoute::Ipc,
                    );
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC delete queued follow-up failed for {} thread {}: {} ({})",
                        key.server_id,
                        key.thread_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if should_fail_over_server_after_ipc_mutation_error(&error) {
                        let classification = fail_server_over_from_ipc_mutation(
                            &self.app_store,
                            &session,
                            &key.server_id,
                            &error,
                        );
                        warn!(
                            "MobileClient: server {} failed over to direct-only after delete queued follow-up IPC failure: {:?}",
                            key.server_id, classification
                        );
                    } else if !should_fall_back_to_direct_after_ipc_mutation_error(&error) {
                        return Err(RpcError::Deserialization(format!(
                            "IPC delete queued follow-up: {error}"
                        )));
                    }
                }
            }
        }

        let direct_command_id = self.app_store.begin_server_mutating_command(
            &key.server_id,
            ServerMutatingCommandKind::DeleteQueuedFollowUp,
            &key.thread_id,
            ServerMutatingCommandRoute::Direct,
        );
        self.app_store.set_thread_follow_up_drafts(key, next_drafts);
        self.app_store.finish_server_mutating_command_success(
            &key.server_id,
            &direct_command_id,
            ServerMutatingCommandRoute::Direct,
        );
        Ok(())
    }

    /// Roll back the current thread to a selected user turn and return the
    /// message text that should be restored into the composer for editing.
    pub async fn edit_message(
        &self,
        key: &ThreadKey,
        selected_turn_index: u32,
    ) -> Result<String, RpcError> {
        self.get_session(&key.server_id)?;
        let current = self.snapshot_thread(key)?;
        ensure_thread_is_editable(&current)?;
        let rollback_depth = rollback_depth_for_turn(&current, selected_turn_index as usize)?;
        let prefill_text = user_boundary_text_for_turn(&current, selected_turn_index as usize)?;

        if rollback_depth > 0 {
            let response = self
                .server_thread_rollback(
                    &key.server_id,
                    upstream::ThreadRollbackParams {
                        thread_id: key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            let turns = response.thread.turns.clone();
            let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
                &key.server_id,
                response.thread,
                current.model.clone(),
                current.reasoning_effort.clone(),
                current.effective_approval_policy.clone(),
                current.effective_sandbox_policy.clone(),
            )
            .map_err(RpcError::Deserialization)?;
            copy_thread_runtime_fields(&current, &mut snapshot);
            reconcile_active_turn(Some(&current), &mut snapshot, &turns);
            self.app_store.upsert_thread_snapshot(snapshot);
        }

        self.set_active_thread(Some(key.clone()));
        Ok(prefill_text)
    }

    /// Fork a thread from a selected user message boundary.
    pub async fn fork_thread_from_message(
        &self,
        key: &ThreadKey,
        selected_turn_index: u32,
        cwd: Option<String>,
        model: Option<String>,
        approval_policy: Option<crate::types::AppAskForApproval>,
        sandbox: Option<crate::types::AppSandboxMode>,
        developer_instructions: Option<String>,
        persist_extended_history: bool,
    ) -> Result<ThreadKey, RpcError> {
        self.get_session(&key.server_id)?;
        let source = self.snapshot_thread(key)?;
        ensure_thread_is_editable(&source)?;
        let rollback_depth = rollback_depth_for_turn(&source, selected_turn_index as usize)?;

        let developer_instructions =
            crate::local_runtime_instructions::splice_local_runtime_developer_instructions(
                self,
                &key.server_id,
                developer_instructions,
            );

        let response = self
            .server_thread_fork(
                &key.server_id,
                crate::types::AppForkThreadRequest {
                    thread_id: key.thread_id.clone(),
                    model,
                    cwd,
                    approval_policy,
                    sandbox,
                    developer_instructions,
                    persist_extended_history,
                    exclude_turns: false,
                }
                .try_into()
                .map_err(|e: crate::RpcClientError| RpcError::Deserialization(e.to_string()))?,
            )
            .await
            .map_err(|e| RpcError::Deserialization(e.to_string()))?;

        let fork_model = Some(response.model);
        let fork_reasoning = response
            .reasoning_effort
            .map(|value| reasoning_effort_string(value.into()));
        let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
            &key.server_id,
            response.thread,
            fork_model.clone(),
            fork_reasoning.clone(),
            Some(response.approval_policy.into()),
            Some(response.sandbox.into()),
        )
        .map_err(RpcError::Deserialization)?;
        let next_key = snapshot.key.clone();

        if rollback_depth > 0 {
            let rollback_response = self
                .server_thread_rollback(
                    &key.server_id,
                    upstream::ThreadRollbackParams {
                        thread_id: next_key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            snapshot = thread_snapshot_from_upstream_thread_with_overrides(
                &key.server_id,
                rollback_response.thread,
                fork_model,
                fork_reasoning,
                snapshot.effective_approval_policy.clone(),
                snapshot.effective_sandbox_policy.clone(),
            )
            .map_err(RpcError::Deserialization)?;
        }

        self.app_store.upsert_thread_snapshot(snapshot);
        self.set_active_thread(Some(next_key.clone()));
        Ok(next_key)
    }

    pub async fn respond_to_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecisionValue,
    ) -> Result<(), RpcError> {
        let approval = self.pending_approval(request_id)?;
        let approval_seed = self
            .app_store
            .pending_approval_seed(&approval.server_id, &approval.id);
        let session = self.get_session(&approval.server_id)?;
        if server_has_live_ipc(&self.app_store, &approval.server_id, &session)
            && let Some(thread_id) = approval.thread_id.clone()
        {
            let approval_server_id = approval.server_id.clone();
            let command_id = self.app_store.begin_server_mutating_command(
                &approval_server_id,
                ServerMutatingCommandKind::ApprovalResponse,
                &thread_id,
                ServerMutatingCommandRoute::Ipc,
            );
            let approval_for_ipc = approval.clone();
            let thread_id_for_ipc = thread_id.clone();
            let decision_for_ipc = decision.clone();
            match run_ipc_command(&session, move |ipc_client| async move {
                send_ipc_approval_response(
                    &ipc_client,
                    &approval_for_ipc,
                    &thread_id_for_ipc,
                    decision_for_ipc,
                )
                .await
            })
            .await
            {
                Ok(Some(true)) => {
                    self.app_store.finish_server_mutating_command_success(
                        &approval.server_id,
                        &command_id,
                        ServerMutatingCommandRoute::Ipc,
                    );
                    debug!(
                        "MobileClient: approval response sent over IPC for server={} request_id={}",
                        approval.server_id, request_id
                    );
                    self.app_store.resolve_approval(request_id);
                    return Ok(());
                }
                Ok(Some(false)) | Ok(None) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC approval response failed for server={} request_id={}: {} ({})",
                        approval.server_id,
                        request_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if should_fail_over_server_after_ipc_mutation_error(&error) {
                        let classification = fail_server_over_from_ipc_mutation(
                            &self.app_store,
                            &session,
                            &approval.server_id,
                            &error,
                        );
                        warn!(
                            "MobileClient: server {} failed over to direct-only after approval IPC failure: {:?}",
                            approval.server_id, classification
                        );
                    } else if !should_fall_back_to_direct_after_ipc_mutation_error(&error) {
                        return Err(RpcError::Deserialization(format!(
                            "IPC approval response: {error}"
                        )));
                    }
                }
            }
        }
        let direct_command_id = self.app_store.begin_server_mutating_command(
            &approval.server_id,
            ServerMutatingCommandKind::ApprovalResponse,
            approval.thread_id.as_deref().unwrap_or(""),
            ServerMutatingCommandRoute::Direct,
        );
        let response_json = approval_response_json(&approval, approval_seed.as_ref(), decision)?;
        let response_request_id =
            server_request_id_json(approval_request_id(&approval, approval_seed.as_ref()));
        session.respond(response_request_id, response_json).await?;
        self.app_store.finish_server_mutating_command_success(
            &approval.server_id,
            &direct_command_id,
            ServerMutatingCommandRoute::Direct,
        );
        debug!(
            "MobileClient: approval response sent for server={} request_id={}",
            approval.server_id, request_id
        );
        self.app_store.resolve_approval(request_id);
        Ok(())
    }

    pub async fn respond_to_user_input(
        &self,
        request_id: &str,
        answers: Vec<PendingUserInputAnswer>,
    ) -> Result<(), RpcError> {
        let request = self.pending_user_input(request_id)?;
        let normalized_answers = normalize_pending_user_input_answers(&request, &answers);
        let answered_inputs = normalized_answers.clone();
        let session = self.get_session(&request.server_id)?;
        if server_has_live_ipc(&self.app_store, &request.server_id, &session) {
            let request_server_id = request.server_id.clone();
            let submission_id = ipc_pending_user_input_submission_id(&request).to_string();
            let command_id = self.app_store.begin_server_mutating_command(
                &request_server_id,
                ServerMutatingCommandKind::UserInputResponse,
                &request.thread_id,
                ServerMutatingCommandRoute::Ipc,
            );
            let request_thread_id = request.thread_id.clone();
            let submission_id_for_ipc = submission_id.clone();
            let normalized_answers_for_ipc = normalized_answers.clone();
            match run_ipc_command(&session, move |ipc_client| async move {
                send_ipc_user_input_response(
                    &ipc_client,
                    &request_thread_id,
                    &submission_id_for_ipc,
                    normalized_answers_for_ipc,
                )
                .await
            })
            .await
            {
                Ok(Some(true)) => {
                    self.app_store.finish_server_mutating_command_success(
                        &request.server_id,
                        &command_id,
                        ServerMutatingCommandRoute::Ipc,
                    );
                    debug!(
                        "MobileClient: user input response sent over IPC for server={} request_id={} submission_id={}",
                        request.server_id, request_id, submission_id
                    );
                    self.app_store
                        .resolve_pending_user_input_with_response(request_id, answered_inputs);
                    self.spawn_post_user_input_reconcile(
                        request.server_id.clone(),
                        request.thread_id.clone(),
                        Arc::clone(&session),
                    );
                    return Ok(());
                }
                Ok(Some(false)) | Ok(None) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC user input response failed for server={} request_id={}: {} ({})",
                        request.server_id,
                        request_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if should_fail_over_server_after_ipc_mutation_error(&error) {
                        let classification = fail_server_over_from_ipc_mutation(
                            &self.app_store,
                            &session,
                            &request.server_id,
                            &error,
                        );
                        warn!(
                            "MobileClient: server {} failed over to direct-only after user-input IPC failure: {:?}",
                            request.server_id, classification
                        );
                    } else if !should_fall_back_to_direct_after_ipc_mutation_error(&error) {
                        return Err(RpcError::Deserialization(format!(
                            "IPC user input response: {error}"
                        )));
                    }
                }
            }
        }
        let direct_command_id = self.app_store.begin_server_mutating_command(
            &request.server_id,
            ServerMutatingCommandKind::UserInputResponse,
            &request.thread_id,
            ServerMutatingCommandRoute::Direct,
        );
        let response = upstream::ToolRequestUserInputResponse {
            answers: normalized_answers
                .into_iter()
                .map(|answer| {
                    (
                        answer.question_id,
                        upstream::ToolRequestUserInputAnswer {
                            answers: answer.answers,
                        },
                    )
                })
                .collect::<HashMap<_, _>>(),
        };
        let response_json = serde_json::to_value(response).map_err(|e| {
            RpcError::Deserialization(format!("serialize user input response: {e}"))
        })?;
        let response_request_id = server_request_id_json(fallback_server_request_id(&request.id));
        session.respond(response_request_id, response_json).await?;
        self.app_store.finish_server_mutating_command_success(
            &request.server_id,
            &direct_command_id,
            ServerMutatingCommandRoute::Direct,
        );
        debug!(
            "MobileClient: user input response sent for server={} request_id={}",
            request.server_id, request_id
        );
        self.app_store
            .resolve_pending_user_input_with_response(request_id, answered_inputs);
        self.spawn_post_user_input_reconcile(
            request.server_id.clone(),
            request.thread_id.clone(),
            Arc::clone(&session),
        );
        Ok(())
    }

    fn spawn_post_user_input_reconcile(
        &self,
        server_id: String,
        thread_id: String,
        session: Arc<ServerSession>,
    ) {
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            for delay_ms in USER_INPUT_RECONCILE_DELAYS_MS {
                tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                match read_thread_response_from_app_server(Arc::clone(&session), &thread_id, true)
                    .await
                {
                    Ok(response) => {
                        if let Err(error) = upsert_thread_snapshot_from_app_server_read_response(
                            &app_store, &server_id, response,
                        ) {
                            warn!(
                                "MobileClient: failed to reconcile thread after user input for server={} thread={}: {}",
                                server_id, thread_id, error
                            );
                            continue;
                        }
                        let key = ThreadKey {
                            server_id: server_id.clone(),
                            thread_id: thread_id.clone(),
                        };
                        let should_keep_polling = app_store
                            .snapshot()
                            .threads
                            .get(&key)
                            .is_some_and(|thread| thread.active_turn_id.is_some());
                        if !should_keep_polling {
                            break;
                        }
                    }
                    Err(error) => {
                        warn!(
                            "MobileClient: failed to refresh thread after user input for server={} thread={}: {}",
                            server_id, thread_id, error
                        );
                    }
                }
            }
        });
    }

    pub fn snapshot(&self) -> AppSnapshot {
        self.app_store.snapshot()
    }

    pub fn subscribe_updates(&self) -> broadcast::Receiver<AppStoreUpdateRecord> {
        self.app_store.subscribe()
    }

    pub fn app_snapshot(&self) -> AppSnapshot {
        self.snapshot()
    }

    pub fn subscribe_app_updates(&self) -> broadcast::Receiver<AppStoreUpdateRecord> {
        self.subscribe_updates()
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_active_thread(key);
    }

    pub async fn set_thread_collaboration_mode(
        &self,
        key: &ThreadKey,
        mode: AppModeKind,
    ) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        self.app_store.set_thread_collaboration_mode(key, mode);

        if !server_has_live_ipc(&self.app_store, &key.server_id, &session) {
            return Ok(());
        }
        let Some(collaboration_mode) = collaboration_mode_from_thread(&thread, mode, None, None)
        else {
            return Ok(());
        };

        info!(
            "IPC out: set_collaboration_mode server={} thread={}",
            key.server_id, key.thread_id
        );
        let command_id = self.app_store.begin_server_mutating_command(
            &key.server_id,
            ServerMutatingCommandKind::CollaborationModeSync,
            &key.thread_id,
            ServerMutatingCommandRoute::Ipc,
        );
        let ipc_result = run_ipc_command(&session, move |ipc_client| async move {
            ipc_client
                .set_collaboration_mode(ThreadFollowerSetCollaborationModeParams {
                    conversation_id: key.thread_id.clone(),
                    collaboration_mode,
                })
                .await
        })
        .await;
        match ipc_result {
            Ok(Some(_)) => {
                self.app_store.finish_server_mutating_command_success(
                    &key.server_id,
                    &command_id,
                    ServerMutatingCommandRoute::Ipc,
                );
                debug!(
                    "IPC out: set_collaboration_mode ok server={} thread={}",
                    key.server_id, key.thread_id
                );
            }
            Ok(None) => return Ok(()),
            Err(error) => {
                warn!(
                    "MobileClient: IPC collaboration mode sync failed for {} thread {}: {} ({})",
                    key.server_id,
                    key.thread_id,
                    error,
                    ipc_command_error_context(&error)
                );
                if should_fail_over_server_after_ipc_mutation_error(&error) {
                    let classification = fail_server_over_from_ipc_mutation(
                        &self.app_store,
                        &session,
                        &key.server_id,
                        &error,
                    );
                    warn!(
                        "MobileClient: server {} failed over to direct-only after collaboration mode IPC failure: {:?}",
                        key.server_id, classification
                    );
                } else if !should_fall_back_to_direct_after_ipc_mutation_error(&error) {
                    return Err(RpcError::Deserialization(format!(
                        "IPC collaboration mode sync: {error}"
                    )));
                }
            }
        }
        Ok(())
    }

    pub fn dismiss_plan_implementation_prompt(&self, key: &ThreadKey) {
        self.app_store.dismiss_plan_implementation_prompt(key);
    }

    pub async fn implement_plan(&self, key: &ThreadKey) -> Result<(), RpcError> {
        self.app_store.dismiss_plan_implementation_prompt(key);
        let thread = self.snapshot_thread(key).ok();
        self.app_store
            .set_thread_collaboration_mode(key, AppModeKind::Default);
        let collaboration_mode = thread
            .as_ref()
            .and_then(|t| collaboration_mode_from_thread(t, AppModeKind::Default, None, None));
        self.start_turn(
            &key.server_id,
            upstream::TurnStartParams {
                thread_id: key.thread_id.clone(),
                input: vec![upstream::UserInput::Text {
                    text: "Implement the plan.".to_string(),
                    text_elements: Vec::new(),
                }],
                responsesapi_client_metadata: None,
                cwd: None,
                approval_policy: None,
                approvals_reviewer: None,
                sandbox_policy: None,
                environments: None,
                permission_profile: None,
                model: None,
                service_tier: None,
                effort: None,
                summary: None,
                personality: None,
                output_schema: None,
                collaboration_mode,
            },
        )
        .await
    }

    pub fn set_voice_handoff_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_voice_handoff_thread(key);
    }

    pub async fn scan_servers_with_mdns_context(
        &self,
        mdns_results: Vec<MdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Vec<DiscoveredServer> {
        let discovery = self.discovery_write();
        discovery
            .scan_once_with_context(&mdns_results, local_ipv4.as_deref())
            .await
    }

    pub fn subscribe_scan_servers_with_mdns_context(
        &self,
        mdns_results: Vec<MdnsSeed>,
        local_ipv4: Option<String>,
    ) -> broadcast::Receiver<crate::discovery::ProgressiveDiscoveryUpdate> {
        let (tx, rx) = broadcast::channel(32);
        let discovery = self.discovery_read().clone_for_one_shot();

        Self::spawn_detached(async move {
            let _ = discovery
                .scan_once_progressive_with_context(&mdns_results, local_ipv4.as_deref(), &tx)
                .await;
        });

        rx
    }

    /// Invalidate the in-memory ambient suggestions cache for a server.
    /// If `project_root` is `None`, all entries for the server are cleared.
    pub fn invalidate_ambient_suggestions(&self, server_id: &str, project_root: Option<&str>) {
        crate::ambient_suggestions::invalidate_cache(&self.ambient_cache, server_id, project_root);
    }
}

impl Default for MobileClient {
    fn default() -> Self {
        Self::new()
    }
}

pub(super) fn run_connect_warmup(
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    app_store: Arc<AppStoreReducer>,
    server_id: String,
    session: Arc<ServerSession>,
    label: &'static str,
) {
    MobileClient::spawn_detached(async move {
        match refresh_account_from_app_server(
            session,
            Arc::clone(&app_store),
            Arc::clone(&sessions),
            server_id.as_str(),
        )
        .await
        {
            Ok(()) => trace!("MobileClient: {label} account sync completed server_id={server_id}"),
            Err(error) => {
                warn!("MobileClient: {label} account sync failed server_id={server_id}: {error}")
            }
        }
    });
}
