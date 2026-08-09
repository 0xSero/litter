use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, RwLock, Weak};
use tokio::sync::{Mutex, broadcast};
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
    SlingshotReconnectTransport, SshReconnectTransport, connect_remote_client_over_slingshot,
    remote_connect_args,
};
use crate::session::events::{EventProcessor, UiEvent};
use crate::slingshot_url::build_slingshot_connection_url;
use crate::ssh::{SshBootstrapResult, SshBootstrapTransport, SshClient, SshCredentials};
use crate::store::snapshot::ServerMutatingCommandKind;
use crate::store::{
    AppConnectionProgressSnapshot, AppQueuedFollowUpKind, AppQueuedFollowUpPreview, AppSnapshot,
    AppStoreReducer, AppStoreUpdateRecord, ServerHealthSnapshot, ThreadSnapshot,
};
use crate::transport::{RpcError, TransportError};
use crate::types::{
    AgentRuntimeInfo, AgentRuntimeKind, AppCollaborationModePreset, AppModeKind,
    ApprovalDecisionValue, PendingApproval, PendingApprovalSeed, PendingUserInputAnswer,
    PendingUserInputRequest, PendingUserInputResponseKind, PendingUserInputSeed, ThreadInfo,
    ThreadKey, ThreadSummaryStatus,
};
use codex_app_server_protocol as upstream;

mod dynamic_tools;
mod event_loop;
pub(crate) mod minigame;
mod store_listener;
#[cfg(test)]
mod tests;
mod thread_projection;

use self::dynamic_tools::*;
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
    pub agent_metadata: Arc<crate::store::AgentMetadataStore>,
    pub(crate) discovery: RwLock<DiscoveryService>,
    oauth_callback_tunnels: Arc<Mutex<HashMap<String, OAuthCallbackTunnel>>>,
    slingshot_apis: Arc<StdMutex<HashMap<String, codex_slingshot::SlingshotApi>>>,
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
    /// Directory where the Slingshot controller enrollment is persisted.
    /// This holds the device-key enrollment and short-lived remote-control
    /// session token so cold launches can reconnect without another browser
    /// step-up while the token remains valid.
    pub(crate) slingshot_credentials_directory: Arc<StdMutex<Option<String>>>,
    direct_resumed_threads: Arc<StdMutex<HashSet<ThreadKey>>>,
    resume_locks: Arc<StdMutex<HashMap<ThreadKey, Weak<tokio::sync::Mutex<()>>>>>,
    thread_runtime_routes: Arc<StdMutex<HashMap<ThreadKey, AgentRuntimeKind>>>,
    /// Single shared iroh `Endpoint` for all alleycat operations. iroh is
    /// designed for one-per-app reuse: `Endpoint::connect(&self, ...)`
    /// takes `&self` so it can be called many times to open new
    /// connections, and `Endpoint::network_change()` re-evaluates paths
    /// across every active `Connection` carried on it. Building a fresh
    /// endpoint per reconnect (the prior behavior) was rebinding UDP
    /// sockets, generating fresh secret keys, re-running relay
    /// discovery, and logging "Aborting ungracefully" on every drop.
    /// Lazily initialized on the first `list_agents` /
    /// `connect_remote_over_alleycat`.
    alleycat_endpoint: Arc<tokio::sync::OnceCell<iroh::Endpoint>>,
    /// Persisted iroh device secret key. The platform loads the key
    /// bytes from keychain (iOS) / EncryptedSharedPreferences (Android)
    /// at app launch and pushes them in via
    /// `set_alleycat_secret_key`. After `alleycat_endpoint()` initializes,
    /// the platform reads the actually-used bytes back via
    /// `alleycat_secret_key` and persists them — so the next cold
    /// launch reuses the same `EndpointId` (faster relay re-association,
    /// stable peer identity).
    alleycat_secret_key: Arc<StdMutex<Option<[u8; 32]>>>,
    /// In-flight guided-SSH-connect flows, keyed by server_id. Held on
    /// `MobileClient` so repeated connect attempts can reuse the same
    /// bootstrap task.
    pub(crate) ssh_bootstrap_flows:
        Arc<tokio::sync::Mutex<HashMap<String, ManagedSshBootstrapFlow>>>,
    alleycat_restart_targets: Arc<StdMutex<HashMap<String, AlleycatRestartTarget>>>,
    /// Live terminal session handles keyed by session id. The store
    /// holds the FFI-visible snapshot
    /// (`AppSnapshot.terminal_sessions`); these are the strong
    /// references that keep the underlying PTY / SSH channel alive while
    /// view-scoped renderers come and go. Cleared per-id when the
    /// session exits or the caller explicitly closes it.
    pub(crate) terminal_sessions:
        Arc<StdMutex<HashMap<String, Arc<crate::terminal::TerminalSession>>>>,
}

/// State for a single in-flight guided SSH connect.
pub struct ManagedSshBootstrapFlow {}

#[derive(Debug, Clone)]
struct AlleycatRestartTarget {
    params: crate::alleycat::ParsedPairPayload,
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
const MCP_APPROVAL_FIELD_ID: &str = "__approval";
const MCP_URL_ACTION_FIELD_ID: &str = "__url_action";
const MCP_APPROVAL_ACCEPT_ONCE_LABEL: &str = "Allow";
const MCP_APPROVAL_ACCEPT_SESSION_LABEL: &str = "Allow for this session";
const MCP_APPROVAL_ACCEPT_ALWAYS_LABEL: &str = "Always allow";
const MCP_APPROVAL_DECLINE_LABEL: &str = "Deny";
const MCP_APPROVAL_CANCEL_LABEL: &str = "Cancel";
const MCP_URL_FINISHED_LABEL: &str = "I finished";
const SLINGSHOT_CREDENTIALS_DIR_NAME: &str = "slingshot";
const SLINGSHOT_CREDENTIALS_VERSION: u32 = 1;
const SLINGSHOT_TOKEN_REFRESH_SKEW_SECS: i64 = 30;
const SLINGSHOT_INITIALIZE_TIMEOUT_RETRY_ATTEMPTS: usize = 2;
const SLINGSHOT_INITIALIZE_TIMEOUT_RETRY_DELAY_SECS: u64 = 0;
const ALLEYCAT_AGENT_INVENTORY_REFRESH_DELAYS_MS: [u64; 3] = [500, 1_000, 1_500];
const ALLEYCAT_AGENT_DIAL_RETRY_DELAYS_MS: [u64; 2] = [500, 1_000];
const ALLEYCAT_CONTROLLER_AGENT_DIAL_RETRY_DELAYS_MS: [u64; 6] =
    [250, 500, 750, 1_000, 1_500, 2_000];

pub(crate) fn slingshot_user_agent() -> String {
    let arch = slingshot_user_agent_arch();
    if cfg!(target_os = "android") {
        format!("Codex Desktop/26.513.20950 (Android; {arch})")
    } else if cfg!(target_os = "ios") {
        format!("Codex Desktop/26.513.20950 (iOS; {arch})")
    } else {
        format!("Codex Desktop/26.513.20950 (Macintosh; Intel Mac OS X; {arch})")
    }
}

fn slingshot_user_agent_arch() -> &'static str {
    if cfg!(all(target_os = "android", target_arch = "aarch64")) {
        "arm64-v8a"
    } else if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        std::env::consts::ARCH
    }
}

fn slingshot_api_cache_key(base_url: &Url, account_id: &str) -> String {
    format!("{}|{}", base_url.as_str().trim_end_matches('/'), account_id)
}

#[derive(serde::Serialize, serde::Deserialize)]
struct StoredSlingshotControllerSession {
    version: u32,
    base_url: String,
    account_id: String,
    session: codex_slingshot::SlingshotControllerSession,
}

fn slingshot_credentials_path(root: &Path, base_url: &Url, account_id: &str) -> PathBuf {
    let mut hasher = DefaultHasher::new();
    base_url.as_str().trim_end_matches('/').hash(&mut hasher);
    account_id.hash(&mut hasher);
    root.join(SLINGSHOT_CREDENTIALS_DIR_NAME)
        .join(format!("{:016x}.json", hasher.finish()))
}

fn slingshot_session_is_usable(session: &codex_slingshot::SlingshotControllerSession) -> bool {
    let Ok(expires_at) = chrono::DateTime::parse_from_rfc3339(&session.expires_at) else {
        return false;
    };
    let expires_at = expires_at.with_timezone(&chrono::Utc);
    expires_at > chrono::Utc::now() + chrono::Duration::seconds(SLINGSHOT_TOKEN_REFRESH_SKEW_SECS)
}

fn is_slingshot_initialize_timeout(error: &TransportError) -> bool {
    match error {
        TransportError::ConnectionFailed(message) => {
            message.contains("slingshot app-server handshake failed")
                && message.contains("timed out waiting for initialize response")
        }
        _ => false,
    }
}

async fn connect_slingshot_with_startup_retries(
    api: codex_slingshot::SlingshotApi,
    environment_id: String,
    args: &codex_app_server_client::RemoteAppServerConnectArgs,
    server_id: &str,
) -> Result<codex_app_server_client::AppServerClient, TransportError> {
    for attempt in 1..=SLINGSHOT_INITIALIZE_TIMEOUT_RETRY_ATTEMPTS {
        match connect_remote_client_over_slingshot(api.clone(), environment_id.clone(), args).await
        {
            Ok(client) => {
                if attempt > 1 {
                    info!(
                        target: "codex_slingshot",
                        %server_id,
                        %environment_id,
                        attempt,
                        "Slingshot app-server initialize succeeded after retry"
                    );
                }
                return Ok(client);
            }
            Err(error)
                if attempt < SLINGSHOT_INITIALIZE_TIMEOUT_RETRY_ATTEMPTS
                    && is_slingshot_initialize_timeout(&error) =>
            {
                warn!(
                    target: "codex_slingshot",
                    %server_id,
                    %environment_id,
                    attempt,
                    max_attempts = SLINGSHOT_INITIALIZE_TIMEOUT_RETRY_ATTEMPTS,
                    retry_delay_secs = SLINGSHOT_INITIALIZE_TIMEOUT_RETRY_DELAY_SECS,
                    %error,
                    "Slingshot app-server initialize timed out; retrying"
                );
                tokio::time::sleep(std::time::Duration::from_secs(
                    SLINGSHOT_INITIALIZE_TIMEOUT_RETRY_DELAY_SECS,
                ))
                .await;
            }
            Err(error) => return Err(error),
        }
    }

    unreachable!("Slingshot retry loop always returns from the final attempt")
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

/// Returns true when an RPC error string looks like a JSON-RPC -32601
/// "method not found" error.
fn is_method_not_found(error: &str) -> bool {
    error.contains("-32601")
        || error.to_ascii_lowercase().contains("method not found")
        || error.to_ascii_lowercase().contains("not implemented")
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

fn pending_user_input_first_answer<'a>(
    answers: &'a [PendingUserInputAnswer],
    question_id: &str,
) -> Option<&'a str> {
    answers
        .iter()
        .find(|answer| answer.question_id == question_id)
        .and_then(|answer| {
            answer
                .answers
                .iter()
                .find_map(|entry| non_empty_trimmed(entry))
        })
}

fn mcp_elicitation_response_json(
    seed: &PendingUserInputSeed,
    answers: &[PendingUserInputAnswer],
) -> Result<serde_json::Value, RpcError> {
    let params: upstream::McpServerElicitationRequestParams =
        serde_json::from_value(seed.raw_params.clone()).map_err(|error| {
            RpcError::Deserialization(format!("deserialize MCP elicitation params: {error}"))
        })?;
    let response = match &params.request {
        upstream::McpServerElicitationRequest::Form {
            requested_schema, ..
        } if requested_schema.properties.is_empty() => {
            let (action, meta) = mcp_approval_action_response(answers);
            upstream::McpServerElicitationRequestResponse {
                action,
                content: None,
                meta,
            }
        }
        upstream::McpServerElicitationRequest::Form {
            requested_schema, ..
        } => {
            let mut content = serde_json::Map::new();
            for (id, schema) in &requested_schema.properties {
                if let Some(value) = mcp_elicitation_answer_value(schema, id, answers) {
                    content.insert(id.clone(), value);
                }
            }
            upstream::McpServerElicitationRequestResponse {
                action: upstream::McpServerElicitationAction::Accept,
                content: Some(serde_json::Value::Object(content)),
                meta: None,
            }
        }
        upstream::McpServerElicitationRequest::Url { .. } => {
            let answer = pending_user_input_first_answer(answers, MCP_URL_ACTION_FIELD_ID);
            let action = match answer {
                Some(MCP_URL_FINISHED_LABEL) => upstream::McpServerElicitationAction::Accept,
                Some(MCP_APPROVAL_CANCEL_LABEL) => upstream::McpServerElicitationAction::Cancel,
                _ => upstream::McpServerElicitationAction::Cancel,
            };
            upstream::McpServerElicitationRequestResponse {
                action,
                content: None,
                meta: None,
            }
        }
    };
    serde_json::to_value(response)
        .map_err(|error| RpcError::Deserialization(format!("serialize MCP response: {error}")))
}

fn mcp_approval_action_response(
    answers: &[PendingUserInputAnswer],
) -> (
    upstream::McpServerElicitationAction,
    Option<serde_json::Value>,
) {
    match pending_user_input_first_answer(answers, MCP_APPROVAL_FIELD_ID) {
        Some(MCP_APPROVAL_ACCEPT_SESSION_LABEL) => (
            upstream::McpServerElicitationAction::Accept,
            Some(serde_json::json!({
                codex_protocol::mcp_approval_meta::PERSIST_KEY:
                    codex_protocol::mcp_approval_meta::PERSIST_SESSION,
            })),
        ),
        Some(MCP_APPROVAL_ACCEPT_ALWAYS_LABEL) => (
            upstream::McpServerElicitationAction::Accept,
            Some(serde_json::json!({
                codex_protocol::mcp_approval_meta::PERSIST_KEY:
                    codex_protocol::mcp_approval_meta::PERSIST_ALWAYS,
            })),
        ),
        Some(MCP_APPROVAL_DECLINE_LABEL) => (upstream::McpServerElicitationAction::Decline, None),
        Some(MCP_APPROVAL_CANCEL_LABEL) => (upstream::McpServerElicitationAction::Cancel, None),
        Some(MCP_APPROVAL_ACCEPT_ONCE_LABEL) => {
            (upstream::McpServerElicitationAction::Accept, None)
        }
        _ => (upstream::McpServerElicitationAction::Cancel, None),
    }
}

fn mcp_elicitation_answer_value(
    schema: &upstream::McpElicitationPrimitiveSchema,
    question_id: &str,
    answers: &[PendingUserInputAnswer],
) -> Option<serde_json::Value> {
    match schema {
        upstream::McpElicitationPrimitiveSchema::String(_) => {
            pending_user_input_first_answer(answers, question_id)
                .map(|value| serde_json::Value::String(value.to_string()))
        }
        upstream::McpElicitationPrimitiveSchema::Number(schema) => {
            let answer = pending_user_input_first_answer(answers, question_id)?;
            match schema.type_ {
                upstream::McpElicitationNumberType::Integer => answer
                    .parse::<i64>()
                    .ok()
                    .map(|value| serde_json::Value::Number(value.into())),
                upstream::McpElicitationNumberType::Number => answer
                    .parse::<f64>()
                    .ok()
                    .and_then(serde_json::Number::from_f64)
                    .map(serde_json::Value::Number),
            }
        }
        upstream::McpElicitationPrimitiveSchema::Boolean(_) => {
            let answer = pending_user_input_first_answer(answers, question_id)?;
            parse_bool_answer(answer).map(serde_json::Value::Bool)
        }
        upstream::McpElicitationPrimitiveSchema::Enum(schema) => {
            mcp_enum_answer_value(schema, question_id, answers)
        }
    }
}

fn parse_bool_answer(answer: &str) -> Option<bool> {
    match answer.trim().to_ascii_lowercase().as_str() {
        "true" | "yes" | "y" | "1" | "allow" => Some(true),
        "false" | "no" | "n" | "0" | "deny" => Some(false),
        _ => None,
    }
}

fn mcp_enum_answer_value(
    schema: &upstream::McpElicitationEnumSchema,
    question_id: &str,
    answers: &[PendingUserInputAnswer],
) -> Option<serde_json::Value> {
    match schema {
        upstream::McpElicitationEnumSchema::Legacy(schema) => {
            let answer = pending_user_input_first_answer(answers, question_id)?;
            let enum_names = schema.enum_names.clone().unwrap_or_default();
            schema.enum_.iter().enumerate().find_map(|(index, value)| {
                let label = enum_names.get(index).unwrap_or(value);
                (answer == label || answer == value)
                    .then(|| serde_json::Value::String(value.clone()))
            })
        }
        upstream::McpElicitationEnumSchema::SingleSelect(schema) => {
            let answer = pending_user_input_first_answer(answers, question_id)?;
            match schema {
                upstream::McpElicitationSingleSelectEnumSchema::Untitled(schema) => schema
                    .enum_
                    .iter()
                    .find(|value| answer == value.as_str())
                    .map(|value| serde_json::Value::String(value.clone())),
                upstream::McpElicitationSingleSelectEnumSchema::Titled(schema) => schema
                    .one_of
                    .iter()
                    .find(|entry| answer == entry.title || answer == entry.const_)
                    .map(|entry| serde_json::Value::String(entry.const_.clone())),
            }
        }
        upstream::McpElicitationEnumSchema::MultiSelect(schema) => {
            let raw_answers = answers
                .iter()
                .find(|answer| answer.question_id == question_id)?
                .answers
                .iter()
                .filter_map(|answer| non_empty_trimmed(answer))
                .collect::<Vec<_>>();
            let values = match schema {
                upstream::McpElicitationMultiSelectEnumSchema::Untitled(schema) => raw_answers
                    .into_iter()
                    .filter_map(|answer| {
                        schema
                            .items
                            .enum_
                            .iter()
                            .find(|value| answer == value.as_str())
                            .cloned()
                    })
                    .map(serde_json::Value::String)
                    .collect::<Vec<_>>(),
                upstream::McpElicitationMultiSelectEnumSchema::Titled(schema) => raw_answers
                    .into_iter()
                    .filter_map(|answer| {
                        schema
                            .items
                            .any_of
                            .iter()
                            .find(|entry| answer == entry.title || answer == entry.const_)
                            .map(|entry| entry.const_.clone())
                    })
                    .map(serde_json::Value::String)
                    .collect::<Vec<_>>(),
            };
            Some(serde_json::Value::Array(values))
        }
    }
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
        "claude" | "claude-code" | "claude_code" => Some("claude".to_string()),
        "anthropic" => Some("claude".to_string()),
        "amp" | "ampcode" | "amp-code" | "amp_code" | "amp code" => Some("amp".to_string()),
        "opencode" | "open-code" | "open_code" | "open code" => Some("opencode".to_string()),
        "pi" | "pi.dev" | "pidev" | "pi dev" => Some("pi".to_string()),
        "droid" | "factory" | "factory-droid" | "factory_droid" | "factory droid" => {
            Some("droid".to_string())
        }
        "codex" => Some("codex".to_string()),
        // Match patterns like `anthropic/claude-opus-4-7` or
        // `claude-3-5-sonnet` — i.e. a `claude` token anywhere in the
        // hint, after stripping a leading provider prefix. We treat
        // `<segment>/claude...` as Claude even if the leading segment
        // is `anthropic`.
        _ if normalized.starts_with("claude") => Some("claude".to_string()),
        _ if normalized
            .split('/')
            .any(|segment| segment.starts_with("claude")) =>
        {
            Some("claude".to_string())
        }
        _ if normalized.contains("opencode")
            || normalized.contains("open-code")
            || normalized.contains("open_code")
            || normalized.contains("open code") =>
        {
            Some("opencode".to_string())
        }
        _ if normalized.starts_with("amp/")
            || normalized.starts_with("amp:")
            || normalized.starts_with("amp-")
            || normalized.contains("ampcode")
            || normalized.contains("amp-code")
            || normalized.contains("amp_code") =>
        {
            Some("amp".to_string())
        }
        _ if normalized.starts_with("pi.dev")
            || normalized.starts_with("pidev")
            || normalized.starts_with("pi/") =>
        {
            Some("pi".to_string())
        }
        _ if normalized.starts_with("factory/") || normalized.starts_with("droid/") => {
            Some("droid".to_string())
        }
        _ => None,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedModelSelection {
    pub model: String,
    pub runtime_kind: AgentRuntimeKind,
}

fn alleycat_runtime_agent_names(
    runtime_agents: &[(AgentRuntimeKind, AlleycatAgentInfo)],
) -> String {
    runtime_agents
        .iter()
        .map(|(_, agent)| agent.name.clone())
        .collect::<Vec<_>>()
        .join(",")
}

fn missing_runtime_kinds(
    existing_runtime_kinds: &[AgentRuntimeKind],
    requested_runtime_kinds: &HashSet<AgentRuntimeKind>,
) -> Vec<AgentRuntimeKind> {
    let existing = existing_runtime_kinds
        .iter()
        .cloned()
        .collect::<HashSet<_>>();
    let mut missing = requested_runtime_kinds
        .iter()
        .cloned()
        .filter(|kind| !existing.contains(kind))
        .collect::<Vec<_>>();
    missing.sort();
    missing
}

fn can_reuse_waited_resume(
    waited: bool,
    force_authoritative: bool,
    has_direct_resume_marker: bool,
) -> bool {
    waited && !force_authoritative && has_direct_resume_marker
}

fn alleycat_requested_runtime_kinds(
    runtime_agents: &[(AgentRuntimeKind, AlleycatAgentInfo)],
) -> HashSet<AgentRuntimeKind> {
    runtime_agents
        .iter()
        .map(|(runtime_kind, _)| runtime_kind.clone())
        .collect()
}

fn is_local_studio_controller(server_id: &str) -> bool {
    server_id.starts_with("alleycat:local-studio:")
}

fn alleycat_agent_is_requested(
    local_studio_controller: bool,
    selected_agent_names: &HashSet<String>,
    agent_name: &str,
) -> bool {
    if local_studio_controller {
        return agent_name == "local-studio";
    }
    selected_agent_names.is_empty() || selected_agent_names.contains(agent_name)
}

fn merge_alleycat_agent_inventory(
    inventory: &mut Vec<AlleycatAgentInfo>,
    refreshed: Vec<AlleycatAgentInfo>,
) {
    for agent in refreshed {
        if let Some(existing) = inventory
            .iter_mut()
            .find(|existing| existing.name == agent.name)
        {
            *existing = agent;
        } else {
            inventory.push(agent);
        }
    }
}

fn alleycat_inventory_refresh_delays(wait_for_registration: bool) -> &'static [u64] {
    if wait_for_registration {
        &ALLEYCAT_AGENT_INVENTORY_REFRESH_DELAYS_MS
    } else {
        &[]
    }
}

fn alleycat_dial_retry_delays(use_all_controller_agents: bool) -> &'static [u64] {
    if use_all_controller_agents {
        &ALLEYCAT_CONTROLLER_AGENT_DIAL_RETRY_DELAYS_MS
    } else {
        &ALLEYCAT_AGENT_DIAL_RETRY_DELAYS_MS
    }
}

impl MobileClient {
    /// Create a new `MobileClient`.
    pub fn new() -> Self {
        crate::logging::install_tracing_subscriber();
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
            agent_metadata: crate::store::AgentMetadataStore::new(),
            discovery: RwLock::new(DiscoveryService::new(DiscoveryConfig::default())),
            oauth_callback_tunnels: Arc::new(Mutex::new(HashMap::new())),
            slingshot_apis: Arc::new(StdMutex::new(HashMap::new())),
            recorder: Arc::new(crate::recorder::MessageRecorder::new()),
            ambient_cache: crate::ambient_suggestions::new_ambient_cache(),
            widget_waiters: Arc::new(StdMutex::new(HashMap::new())),
            saved_apps_directory: Arc::new(StdMutex::new(None)),
            slingshot_credentials_directory: Arc::new(StdMutex::new(None)),
            direct_resumed_threads: Arc::new(StdMutex::new(HashSet::new())),
            resume_locks: Arc::new(StdMutex::new(HashMap::new())),
            thread_runtime_routes: Arc::new(StdMutex::new(HashMap::new())),
            alleycat_endpoint: Arc::new(tokio::sync::OnceCell::new()),
            alleycat_secret_key: Arc::new(StdMutex::new(None)),
            ssh_bootstrap_flows: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            alleycat_restart_targets: Arc::new(StdMutex::new(HashMap::new())),
            terminal_sessions: Arc::new(StdMutex::new(HashMap::new())),
        }
    }

    /// Platform pre-loads the persisted device key bytes from secure
    /// storage. Must be called BEFORE the first alleycat operation —
    /// once `alleycat_endpoint()` lazily initializes, the secret key
    /// is captured into the iroh endpoint and any subsequent set is a
    /// no-op for that endpoint's lifetime.
    pub fn set_alleycat_secret_key(&self, bytes: Option<Vec<u8>>) {
        let parsed = bytes.and_then(|v| <[u8; 32]>::try_from(v).ok());
        match self.alleycat_secret_key.lock() {
            Ok(mut guard) => *guard = parsed,
            Err(error) => *error.into_inner() = parsed,
        }
    }

    /// Read the secret key bytes the alleycat endpoint is bound to.
    /// Returns `None` if the endpoint hasn't been initialized yet.
    /// Platform calls this after `alleycat_endpoint()` initializes to
    /// persist freshly-generated keys to secure storage.
    pub fn alleycat_secret_key(&self) -> Option<Vec<u8>> {
        self.alleycat_endpoint
            .get()
            .map(|endpoint| endpoint.secret_key().to_bytes().to_vec())
    }

    fn slingshot_credentials_directory(&self) -> Option<PathBuf> {
        match self.slingshot_credentials_directory.lock() {
            Ok(guard) => guard.clone().map(PathBuf::from),
            Err(error) => error.into_inner().clone().map(PathBuf::from),
        }
    }

    fn load_persisted_slingshot_session(
        &self,
        base_url: &Url,
        account_id: &str,
    ) -> Option<codex_slingshot::SlingshotControllerSession> {
        let root = self.slingshot_credentials_directory()?;
        let path = slingshot_credentials_path(&root, base_url, account_id);
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return None,
            Err(error) => {
                warn!(
                    target: "codex_slingshot",
                    path = %path.display(),
                    %error,
                    "failed to read persisted Slingshot controller session"
                );
                return None;
            }
        };
        let stored: StoredSlingshotControllerSession = match serde_json::from_slice(&bytes) {
            Ok(stored) => stored,
            Err(error) => {
                warn!(
                    target: "codex_slingshot",
                    path = %path.display(),
                    %error,
                    "failed to decode persisted Slingshot controller session"
                );
                return None;
            }
        };
        if stored.version != SLINGSHOT_CREDENTIALS_VERSION
            || stored.base_url != base_url.as_str().trim_end_matches('/')
            || stored.account_id != account_id
        {
            warn!(
                target: "codex_slingshot",
                path = %path.display(),
                version = stored.version,
                "ignoring mismatched persisted Slingshot controller session"
            );
            return None;
        }
        if slingshot_session_is_usable(&stored.session) {
            info!(
                target: "codex_slingshot",
                path = %path.display(),
                client_id = %stored.session.client_id,
                account_user_id = %stored.session.account_user_id,
                expires_at = %stored.session.expires_at,
                "loaded persisted Slingshot controller session"
            );
        } else {
            info!(
                target: "codex_slingshot",
                path = %path.display(),
                client_id = %stored.session.client_id,
                account_user_id = %stored.session.account_user_id,
                expires_at = %stored.session.expires_at,
                "loaded expired persisted Slingshot controller session"
            );
        }
        Some(stored.session)
    }

    fn persist_slingshot_session(
        &self,
        base_url: &Url,
        account_id: &str,
        session: &codex_slingshot::SlingshotControllerSession,
    ) {
        let Some(root) = self.slingshot_credentials_directory() else {
            warn!(
                target: "codex_slingshot",
                "Slingshot controller session persistence skipped because directory is unset"
            );
            return;
        };
        let path = slingshot_credentials_path(&root, base_url, account_id);
        let stored = StoredSlingshotControllerSession {
            version: SLINGSHOT_CREDENTIALS_VERSION,
            base_url: base_url.as_str().trim_end_matches('/').to_string(),
            account_id: account_id.to_string(),
            session: session.clone(),
        };
        let result = (|| -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let bytes = serde_json::to_vec_pretty(&stored)?;
            std::fs::write(&path, bytes)?;
            Ok(())
        })();
        match result {
            Ok(()) => info!(
                target: "codex_slingshot",
                path = %path.display(),
                client_id = %session.client_id,
                account_user_id = %session.account_user_id,
                expires_at = %session.expires_at,
                "persisted Slingshot controller session"
            ),
            Err(error) => warn!(
                target: "codex_slingshot",
                path = %path.display(),
                %error,
                "failed to persist Slingshot controller session"
            ),
        }
    }

    /// Lazy accessor for the shared alleycat iroh `Endpoint`. The first
    /// caller binds the endpoint (UDP socket, persisted-or-fresh
    /// `SecretKey`, relay discovery); every subsequent caller gets a
    /// cheap clone of the same `Endpoint` handle. Reconnects open new
    /// `Connection`s on this endpoint instead of building a new one
    /// from scratch — that's the model iroh is designed for and is
    /// what makes `Endpoint::network_change()` work across reconnect
    /// cycles.
    pub(crate) async fn alleycat_endpoint(
        &self,
    ) -> Result<iroh::Endpoint, crate::alleycat::AlleycatError> {
        let secret_key = match self.alleycat_secret_key.lock() {
            Ok(guard) => *guard,
            Err(error) => *error.into_inner(),
        };
        self.alleycat_endpoint
            .get_or_try_init(|| async { crate::alleycat::bind_alleycat_endpoint(secret_key).await })
            .await
            .cloned()
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

    fn resume_lock(&self, key: &ThreadKey) -> Arc<tokio::sync::Mutex<()>> {
        let mut locks = self.resume_locks.lock().unwrap_or_else(|error| {
            warn!("MobileClient: recovering poisoned resume lock map");
            error.into_inner()
        });
        locks.retain(|_, lock| lock.strong_count() > 0);
        if let Some(lock) = locks.get(key).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(tokio::sync::Mutex::new(()));
        locks.insert(key.clone(), Arc::downgrade(&lock));
        lock
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
            .insert(key.clone(), runtime_kind.clone());
        self.app_store.set_thread_agent_runtime(&key, runtime_kind);
    }

    pub(crate) fn runtime_for_thread(&self, key: &ThreadKey) -> AgentRuntimeKind {
        let routed_runtime = self.thread_runtime_routes().get(key).cloned();
        if let Some(runtime_kind) = routed_runtime.clone()
            && runtime_kind != "codex"
        {
            return runtime_kind;
        }

        if let Some(thread) = self.app_store.thread_snapshot(key) {
            if thread.agent_runtime_kind != "codex" {
                return thread.agent_runtime_kind;
            }
            if let Some(runtime_kind) = self.non_codex_runtime_for_thread_metadata(key, &thread) {
                return runtime_kind;
            }
        }

        routed_runtime.unwrap_or_else(|| "codex".to_string())
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

        if self
            .app_store
            .snapshot()
            .servers
            .get(server_id)
            .is_some_and(|server| {
                server.agent_runtimes.len() == 1 && server.agent_runtimes[0].kind == "local-studio"
            })
        {
            return "local-studio".to_string();
        }

        "codex".to_string()
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
                runtime_kind: candidate.agent_runtime_kind.clone(),
            });
        }

        if let Some(candidate) = models
            .iter()
            .find(|candidate| candidate.model == selected_model)
        {
            return Some(ResolvedModelSelection {
                model: candidate.id.clone(),
                runtime_kind: candidate.agent_runtime_kind.clone(),
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
        let supports_permission_overrides =
            self.runtime_supports_thread_permission_overrides(&runtime_kind);
        let defaults_to_full_access = runtime_kind == "pi" || runtime_kind == "local-studio";
        match request {
            upstream::ClientRequest::ThreadStart { params, .. } => {
                self.normalize_thread_model_for_runtime(
                    server_id,
                    runtime_kind.clone(),
                    &mut params.model,
                );
                if defaults_to_full_access {
                    params.approval_policy = Some(upstream::AskForApproval::Never);
                    params.sandbox = Some(upstream::SandboxMode::DangerFullAccess);
                } else if !supports_permission_overrides {
                    params.approval_policy = None;
                    params.sandbox = None;
                }
            }
            upstream::ClientRequest::ThreadResume { params, .. } => {
                self.normalize_thread_model_for_runtime(
                    server_id,
                    runtime_kind.clone(),
                    &mut params.model,
                );
                if defaults_to_full_access {
                    params.approval_policy = Some(upstream::AskForApproval::Never);
                    params.sandbox = Some(upstream::SandboxMode::DangerFullAccess);
                } else if !supports_permission_overrides {
                    params.approval_policy = None;
                    params.sandbox = None;
                }
            }
            upstream::ClientRequest::ThreadFork { params, .. } => {
                self.normalize_thread_model_for_runtime(
                    server_id,
                    runtime_kind.clone(),
                    &mut params.model,
                );
                if defaults_to_full_access {
                    params.approval_policy = Some(upstream::AskForApproval::Never);
                    params.sandbox = Some(upstream::SandboxMode::DangerFullAccess);
                } else if !supports_permission_overrides {
                    params.approval_policy = None;
                    params.sandbox = None;
                }
            }
            upstream::ClientRequest::TurnStart { params, .. } => {
                if let Some(selected_model) = params.model.as_deref().and_then(non_empty_trimmed)
                    && let Some(resolved) =
                        self.resolve_model_for_runtime(server_id, runtime_kind, selected_model)
                {
                    params.model = Some(resolved);
                }
                if defaults_to_full_access {
                    params.approval_policy = Some(upstream::AskForApproval::Never);
                    params.sandbox_policy = Some(upstream::SandboxPolicy::DangerFullAccess);
                } else if !supports_permission_overrides {
                    params.approval_policy = None;
                    params.sandbox_policy = None;
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
                && runtime_kind != "codex".to_string()
            {
                return Some(runtime_kind);
            }
        }

        if let Some(runtime_kind) = thread
            .info
            .model_provider
            .as_deref()
            .and_then(runtime_for_model_hint)
            .filter(|runtime_kind| *runtime_kind != "codex".to_string())
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
    /// inserting into the session map, and queuing post-connect warmup.
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
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);
        self.app_store
            .update_server_agent_runtimes(server_id, runtime_infos);
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
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

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
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

        self.sessions_write()
            .insert(server_id.clone(), Arc::clone(&session));
        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_post_connect_warmup(server_id.clone(), session);

        info!("MobileClient: connected remote server {server_id}");
        Ok(server_id)
    }

    pub async fn connect_remote_over_slingshot(
        &self,
        server_id: String,
        display_name: String,
        base_url: String,
        access_token: String,
        account_id: String,
        environment_id: String,
        step_up_token: String,
    ) -> Result<String, TransportError> {
        if self.existing_active_session(server_id.as_str()).is_some() {
            info!("MobileClient: reusing existing Slingshot server session {server_id}");
            return Ok(server_id);
        }

        let base_url = Url::parse(base_url.trim()).map_err(|error| {
            TransportError::ConnectionFailed(format!("invalid Slingshot base URL: {error}"))
        })?;
        let access_token = access_token.trim().to_string();
        if access_token.is_empty() {
            return Err(TransportError::ConnectionFailed(
                "missing ChatGPT access token for Slingshot".to_string(),
            ));
        }
        let account_id = account_id.trim().to_string();
        if account_id.is_empty() {
            return Err(TransportError::ConnectionFailed(
                "missing ChatGPT account id for Slingshot enrollment".to_string(),
            ));
        }
        let environment_id = environment_id.trim().to_string();
        if environment_id.is_empty() {
            return Err(TransportError::ConnectionFailed(
                "missing Slingshot environment id".to_string(),
            ));
        }
        let step_up_token = step_up_token.trim().to_string();
        let cache_key = slingshot_api_cache_key(&base_url, &account_id);
        let cached_api = match self.slingshot_apis.lock() {
            Ok(guard) => guard.get(&cache_key).cloned(),
            Err(error) => error.into_inner().get(&cache_key).cloned(),
        }
        .and_then(|api| {
            if api
                .controller_session()
                .as_ref()
                .is_some_and(slingshot_session_is_usable)
            {
                Some(api)
            } else {
                info!(
                    target: "codex_slingshot",
                    %server_id,
                    %environment_id,
                    "MobileClient: cached Slingshot enrollment missing or expired"
                );
                None
            }
        });
        let api = if step_up_token.is_empty() {
            if let Some(api) = cached_api {
                info!(
                    target: "codex_slingshot",
                    %server_id,
                    %environment_id,
                    has_access_token = true,
                    has_step_up_token = false,
                    "MobileClient: reusing cached Slingshot enrollment"
                );
                api
            } else if let Some(session) =
                self.load_persisted_slingshot_session(&base_url, &account_id)
            {
                let session_is_usable = slingshot_session_is_usable(&session);
                let api = codex_slingshot::SlingshotApi::new(codex_slingshot::SlingshotConfig {
                    base_url: base_url.clone(),
                    auth_token: access_token.clone(),
                    user_agent: slingshot_user_agent(),
                    account_id: Some(account_id.clone()),
                    originator: Some("Codex Desktop".to_string()),
                    client_id: Some(session.client_id.clone()),
                });
                if session_is_usable {
                    api.restore_controller_session(session);
                    info!(
                        target: "codex_slingshot",
                        %server_id,
                        %environment_id,
                        has_access_token = true,
                        has_step_up_token = false,
                        "MobileClient: restored persisted Slingshot enrollment"
                    );
                } else {
                    info!(
                        target: "codex_slingshot",
                        %server_id,
                        %environment_id,
                        client_id = %session.client_id,
                        expires_at = %session.expires_at,
                        has_access_token = true,
                        has_step_up_token = false,
                        "MobileClient: refreshing expired Slingshot enrollment"
                    );
                    api.refresh_with_device_key(&session)
                        .await
                        .map_err(|error| {
                            warn!(
                                target: "codex_slingshot",
                                %server_id,
                                %environment_id,
                                %error,
                                "MobileClient: Slingshot enrollment refresh failed"
                            );
                            TransportError::ConnectionFailed(
                                "missing Slingshot remote-control authorization token".to_string(),
                            )
                        })?;
                    if let Some(session) = api.controller_session() {
                        self.persist_slingshot_session(&base_url, &account_id, &session);
                    }
                    info!(
                        target: "codex_slingshot",
                        %server_id,
                        %environment_id,
                        has_access_token = true,
                        has_step_up_token = false,
                        "MobileClient: refreshed persisted Slingshot enrollment"
                    );
                }
                match self.slingshot_apis.lock() {
                    Ok(mut guard) => {
                        guard.insert(cache_key.clone(), api.clone());
                    }
                    Err(error) => {
                        error.into_inner().insert(cache_key.clone(), api.clone());
                    }
                }
                api
            } else {
                warn!(
                    target: "codex_slingshot",
                    %server_id,
                    %environment_id,
                    has_access_token = true,
                    has_step_up_token = false,
                    "MobileClient: no persisted Slingshot enrollment available"
                );
                return Err(TransportError::ConnectionFailed(
                    "missing Slingshot remote-control authorization token".to_string(),
                ));
            }
        } else {
            let api = codex_slingshot::SlingshotApi::new(codex_slingshot::SlingshotConfig {
                base_url: base_url.clone(),
                auth_token: access_token.clone(),
                user_agent: slingshot_user_agent(),
                account_id: Some(account_id.clone()),
                originator: Some("Codex Desktop".to_string()),
                client_id: None,
            });
            info!(
                target: "codex_slingshot",
                %server_id,
                %environment_id,
                has_access_token = true,
                has_step_up_token = true,
                "MobileClient: starting Slingshot enrollment"
            );
            api.enroll_with_step_up_token(&step_up_token)
                .await
                .map_err(|error| TransportError::ConnectionFailed(error.to_string()))?;
            if let Some(session) = api.controller_session() {
                self.persist_slingshot_session(&base_url, &account_id, &session);
            }
            match self.slingshot_apis.lock() {
                Ok(mut guard) => {
                    guard.insert(cache_key, api.clone());
                }
                Err(error) => {
                    error.into_inner().insert(cache_key, api.clone());
                }
            }
            info!(
                target: "codex_slingshot",
                %server_id,
                %environment_id,
                "MobileClient: Slingshot enrollment complete"
            );
            api
        };

        let config = ServerConfig {
            server_id: server_id.clone(),
            display_name,
            host: environment_id.clone(),
            port: 0,
            websocket_url: build_slingshot_connection_url(&environment_id, base_url.as_str()),
            is_local: false,
            tls: true,
        };
        self.app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting);
        self.replace_existing_session(server_id.as_str()).await;

        let (_, args) = remote_connect_args(&config);
        let initial_client = connect_slingshot_with_startup_retries(
            api.clone(),
            environment_id.clone(),
            &args,
            &server_id,
        )
        .await
        .inspect_err(|_| {
            self.app_store
                .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
        })?;
        let trait_transport: Arc<dyn crate::session::remote_transport::RemoteTransport> =
            Arc::new(SlingshotReconnectTransport {
                api,
                environment_id: environment_id.clone(),
            });
        let resource = RuntimeRemoteSessionResource {
            runtime_kind: "codex".to_string(),
            client: initial_client,
            transport: Some(trait_transport),
            keepalive: None,
        };
        let session = match ServerSession::connect_remote_multiplexed(
            config,
            vec![resource],
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
        let runtime_infos = vec![AgentRuntimeInfo {
            kind: "codex".to_string(),
            name: "codex".to_string(),
            display_name: "Codex".to_string(),
            available: true,
        }];
        self.attach_remote_session(&server_id, session, runtime_infos);
        info!("MobileClient: connected Slingshot server {server_id}");
        Ok(server_id)
    }

    pub async fn list_alleycat_agents(
        &self,
        params: ParsedAlleycatPairPayload,
        wait_for_registration: bool,
    ) -> Result<Vec<AlleycatAgentInfo>, TransportError> {
        let endpoint = self
            .alleycat_endpoint()
            .await
            .map_err(|error| TransportError::ConnectionFailed(error.to_string()))?;
        let mut agents = crate::alleycat::list_agents(&endpoint, params.clone())
            .await
            .map_err(|error| TransportError::ConnectionFailed(error.to_string()))?;
        for delay_ms in alleycat_inventory_refresh_delays(wait_for_registration) {
            tokio::time::sleep(std::time::Duration::from_millis(*delay_ms)).await;
            match crate::alleycat::list_agents(&endpoint, params.clone()).await {
                Ok(refreshed) => merge_alleycat_agent_inventory(&mut agents, refreshed),
                Err(error) => warn!(
                    "MobileClient: Alleycat inventory refresh failed node_id={} delay_ms={} error={}",
                    params.node_id, delay_ms, error
                ),
            }
        }
        // Cache metadata so platforms can render labels/icons/capability
        // flags from anywhere in the app, not just at probe time.
        self.agent_metadata
            .upsert_all(agents.iter().map(|agent| crate::store::AppAgentMetadata {
                name: agent.name.clone(),
                display_name: agent.display_name.clone(),
                presentation: agent.presentation.clone().map(Into::into),
                capabilities: agent.capabilities.clone().map(Into::into),
            }));
        Ok(agents)
    }

    fn runtime_supports_thread_permission_overrides(&self, runtime_kind: &str) -> bool {
        if matches!(runtime_kind, "pi" | "local-studio") {
            return false;
        }
        self.agent_metadata
            .get(runtime_kind)
            .and_then(|metadata| metadata.capabilities)
            .map(|capabilities| capabilities.supports_thread_permission_overrides)
            // Legacy daemon/client metadata did not expose this capability; keep
            // existing behaviour until a daemon explicitly says overrides are
            // unsupported for the runtime.
            .unwrap_or(true)
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
        let local_studio_controller = is_local_studio_controller(&server_id);
        let selected_agent_names = selected_agent_names
            .into_iter()
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty())
            .collect::<Vec<_>>();
        let selected_agent_intent = if local_studio_controller {
            "local-studio".to_string()
        } else {
            selected_agent_names.join(",")
        };
        let selected_agent_names = selected_agent_names
            .into_iter()
            .collect::<std::collections::HashSet<_>>();
        let agent_inventory = self
            .list_alleycat_agents(params.clone(), local_studio_controller)
            .await?;
        let mut seen_runtime_kinds = std::collections::HashSet::new();
        let requested_agents = agent_inventory
            .into_iter()
            .filter_map(|agent| {
                if !alleycat_agent_is_requested(
                    local_studio_controller,
                    &selected_agent_names,
                    &agent.name,
                ) {
                    return None;
                }
                let runtime_kind =
                    crate::alleycat::agent_runtime_kind(&agent.name, &agent.display_name)?;
                if !seen_runtime_kinds.insert(runtime_kind.clone()) {
                    return None;
                }
                (agent.available).then_some((runtime_kind, agent))
            })
            .collect::<Vec<_>>();
        let runtime_agents = if requested_agents.is_empty() {
            let fallback_agent_name = if local_studio_controller {
                "local-studio".to_string()
            } else {
                agent_name.clone()
            };
            if !alleycat_agent_is_requested(
                local_studio_controller,
                &selected_agent_names,
                &fallback_agent_name,
            ) {
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                return Err(TransportError::ConnectionFailed(
                    "no selected Alleycat runtime streams are available".to_string(),
                ));
            }
            let runtime_kind =
                crate::alleycat::agent_runtime_kind(&fallback_agent_name, &fallback_agent_name)
                    .unwrap_or("codex".to_string());
            vec![(
                runtime_kind,
                AlleycatAgentInfo {
                    name: fallback_agent_name,
                    display_name: display_name.clone(),
                    wire,
                    available: true,
                    presentation: None,
                    capabilities: None,
                },
            )]
        } else {
            requested_agents
        };
        let requested_runtime_kinds = alleycat_requested_runtime_kinds(&runtime_agents);
        let requested_agent_names = alleycat_runtime_agent_names(&runtime_agents);
        let persisted_agent_names = if selected_agent_intent.is_empty() {
            requested_agent_names.clone()
        } else {
            selected_agent_intent
        };
        let visible_server_id = format!("alleycat:{}", params.node_id);
        let server_id = if server_id.starts_with(&visible_server_id) {
            visible_server_id
        } else {
            server_id
        };

        // Short-circuit if a healthy session for this server already
        // exists. Otherwise the saved-server reconnect path can race with
        // `AlleycatReconnectTransport`'s own auto-retry: the transport
        // self-heals after a `BrokenPipe`, fires a Disconnected→Connected
        // health transition that schedules `run_post_reconnect_resubscribe`
        // against the now-healthy old session, and the saved-server
        // reconnect tears that session down via `replace_existing_session`
        // before the resubscribe finishes — every pending `thread/resume`
        // then fails with `transport error: disconnected`.
        if let Some(existing) = self.sessions_read().get(server_id.as_str()).cloned() {
            let health = existing.health().borrow().clone();
            if matches!(
                health,
                crate::session::connection::ConnectionHealth::Connected
            ) {
                let runtime_kinds = existing.runtime_kinds();
                let missing = missing_runtime_kinds(&runtime_kinds, &requested_runtime_kinds);
                if missing.is_empty() {
                    info!(
                        "MobileClient: connect_remote_over_alleycat short-circuit; healthy session exists server_id={} runtimes={:?}",
                        server_id, runtime_kinds,
                    );
                    return Ok(AlleycatConnectOutcome {
                        server_id,
                        node_id: params.node_id.clone(),
                        agent_name: persisted_agent_names,
                    });
                }
                info!(
                    "MobileClient: connect_remote_over_alleycat rebuilding healthy session server_id={} existing_runtimes={:?} missing_selected_runtimes={:?}",
                    server_id, runtime_kinds, missing,
                );
            }
        }

        let config = ServerConfig {
            server_id: server_id.clone(),
            display_name,
            host: params.node_id.clone(),
            port: 0,
            websocket_url: Some(format!("ws://alleycat/{}", params.node_id)),
            is_local: false,
            tls: false,
        };
        match self.alleycat_restart_targets.lock() {
            Ok(mut guard) => {
                guard.insert(
                    server_id.clone(),
                    AlleycatRestartTarget {
                        params: params.clone(),
                    },
                );
            }
            Err(error) => {
                error.into_inner().insert(
                    server_id.clone(),
                    AlleycatRestartTarget {
                        params: params.clone(),
                    },
                );
            }
        }
        self.app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting);
        self.replace_existing_session(server_id.as_str()).await;

        let endpoint = match self.alleycat_endpoint().await {
            Ok(endpoint) => endpoint,
            Err(error) => {
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                return Err(TransportError::ConnectionFailed(error.to_string()));
            }
        };

        let dial_retry_delays = alleycat_dial_retry_delays(local_studio_controller);
        let dial_tasks = runtime_agents.into_iter().map(|(runtime_kind, agent)| {
            let reconnect_transport = AlleycatReconnectTransport::new(
                params.clone(),
                agent.name.clone(),
                agent.wire,
                endpoint.clone(),
            );
            async move {
                let mut dialed = reconnect_transport.connect_initial().await;
                for (attempt, delay_ms) in dial_retry_delays.iter().copied().enumerate() {
                    let Err(crate::alleycat::AlleycatError::Transport(error)) = &dialed else {
                        break;
                    };
                    warn!(
                        "MobileClient: retrying Alleycat agent={} attempt={} error={}",
                        agent.name,
                        attempt + 1,
                        error
                    );
                    tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                    dialed = reconnect_transport.connect_initial().await;
                }
                (runtime_kind, agent, reconnect_transport, dialed)
            }
        });
        let mut runtime_resources = Vec::new();
        let mut runtime_infos = Vec::new();
        for (runtime_kind, agent, reconnect_transport, dialed) in
            futures::future::join_all(dial_tasks).await
        {
            let (remote_client, alleycat_session) = match dialed {
                Ok(result) => result,
                Err(error) => {
                    warn!(
                        "MobileClient: alleycat connect failed server_id={} agent={} error={}",
                        server_id, agent.name, error
                    );
                    continue;
                }
            };
            // Register the freshly-built session with the transport so
            // `close_current_connection()` can target this Connection
            // before the worker has had to call `reconnect()`.
            reconnect_transport
                .register_initial_session(Arc::clone(&alleycat_session))
                .await;
            runtime_infos.push(AgentRuntimeInfo {
                kind: runtime_kind.clone(),
                name: agent.name.clone(),
                display_name: agent.display_name.clone(),
                available: true,
            });
            let trait_transport: Arc<dyn crate::session::remote_transport::RemoteTransport> =
                Arc::new(reconnect_transport);
            let keepalive: Arc<dyn crate::session::remote_transport::SessionKeepalive> =
                alleycat_session;
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
        if local_studio_controller {
            let connected_runtime_kinds = runtime_resources
                .iter()
                .map(|resource| resource.runtime_kind.clone())
                .collect::<Vec<_>>();
            let missing = missing_runtime_kinds(&connected_runtime_kinds, &requested_runtime_kinds);
            if !missing.is_empty() {
                warn!(
                    "MobileClient: refusing incomplete Local Studio session server_id={} missing_runtimes={:?}",
                    server_id, missing
                );
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                return Err(TransportError::ConnectionFailed(format!(
                    "Local Studio did not connect its advertised runtime: {}",
                    missing.join(", ")
                )));
            }
        }

        info!(
            "MobileClient: alleycat building multiplexed session server_id={} runtime_kinds={:?}",
            server_id,
            runtime_resources
                .iter()
                .map(|r| r.runtime_kind.clone())
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

        // Preserve the user's *intent* in the saved-server record rather
        // than only the agents that successfully attached on this call.
        // If a transient failure drops one runtime (e.g. devin's ACP
        // child hits a stale session lock once), the next reconnect
        // should still try every agent the user originally picked, not
        // silently shrink to the survivors. Falls back to the connected
        // set if the user didn't explicitly select anything (legacy
        // single-agent callers).
        let persisted_agents = if !persisted_agent_names.is_empty() {
            persisted_agent_names
        } else {
            runtime_infos
                .iter()
                .map(|runtime| runtime.name.clone())
                .collect::<Vec<_>>()
                .join(",")
        };

        Ok(AlleycatConnectOutcome {
            server_id,
            node_id: params.node_id,
            agent_name: persisted_agents,
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
            .upsert_server(&config, ServerHealthSnapshot::Connecting);
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
                .map(|resource| resource.runtime_kind.clone())
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
            .upsert_server(&config, ServerHealthSnapshot::Connecting);
        self.app_store.update_server_connection_progress(
            server_id.as_str(),
            Some(AppConnectionProgressSnapshot::ssh_bootstrap()),
        );
        // SSH-backed sessions depend on a local tunnel that may be torn down
        // while the app is backgrounded even if the session health never
        // observed a clean disconnect. Prefer replacing any existing session
        // so resume can rebuild the full SSH transport.
        self.replace_existing_session(server_id.as_str()).await;

        let ssh_client = Arc::new(
            SshClient::connect(
                ssh_credentials.clone(),
                Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
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
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        trace!(
            "MobileClient: finish_connect_remote_over_ssh start server_id={} host={} bootstrap_remote_port={} bootstrap_local_port={} pid={:?}",
            server_id,
            ssh_credentials.host.as_str(),
            bootstrap.server_port,
            bootstrap.tunnel_local_port,
            bootstrap.pid
        );

        match bootstrap.transport {
            SshBootstrapTransport::AppServerProxy => {
                config.port = 0;
                config.websocket_url = Some(format!("app-server-proxy://{}", config.server_id));
            }
            SshBootstrapTransport::WebSocketTunnel => {
                config.port = bootstrap.server_port;
                config.websocket_url =
                    Some(format!("ws://127.0.0.1:{}", bootstrap.tunnel_local_port));
            }
        }
        config.is_local = false;
        config.tls = false;
        let ssh_pid = Arc::new(StdMutex::new(bootstrap.pid));
        let ssh_reconnect_transport = SshReconnectTransport::from_bootstrap(
            Arc::clone(&ssh_client),
            &bootstrap,
            working_dir,
            config.host.contains(':'),
            Arc::clone(&ssh_pid),
        );

        // Eagerly establish the Codex client now that the SSH bootstrap is up.
        // Surfacing connect errors here matches the eager-connect semantics used
        // by `connect_remote_over_alleycat` and the multi-runtime SSH-bridges
        // path, so `connect_remote_multiplexed` only sees populated clients.
        let (_, connect_args) = crate::session::connection::remote_connect_args(&config);
        let initial_connect = match bootstrap.transport {
            SshBootstrapTransport::AppServerProxy => {
                crate::session::connection::connect_remote_client_over_app_server_proxy(
                    &ssh_client,
                    &connect_args,
                    &bootstrap.codex_path,
                    bootstrap.shell,
                )
                .await
            }
            SshBootstrapTransport::WebSocketTunnel => {
                crate::session::connection::connect_remote_client(&connect_args).await
            }
        };
        let initial_client = match initial_connect {
            Ok(client) => client,
            Err(error) => {
                warn!(
                    "MobileClient: remote ssh codex connect failed server_id={} host={} error={}",
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
            runtime_kind: "codex".to_string(),
            client: initial_client,
            transport: Some(trait_transport),
            keepalive: None,
        };
        let extras = RemoteSessionExtras {
            ssh_client: Some(Arc::clone(&ssh_client)),
            ssh_pid: Some(Arc::clone(&ssh_pid)),
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
            kind: "codex".to_string(),
            name: "codex".to_string(),
            display_name: "Codex".to_string(),
            available: true,
        };
        self.attach_remote_session(&server_id, session, vec![codex_runtime_info]);

        info!("MobileClient: connected remote SSH server {server_id}");
        Ok(server_id)
    }

    /// Hint every active session that the host network may have changed
    /// (e.g. iOS just resumed the app from background suspension). For
    /// alleycat/iroh-backed sessions this triggers `Endpoint::network_change()`,
    /// letting QUIC re-evaluate paths and refresh relays without waiting for
    /// the idle timeout. TCP-based sessions default to a no-op since the
    /// kernel already surfaces those changes.
    pub async fn notify_network_change(&self) {
        let sessions: Vec<Arc<ServerSession>> = self.sessions_read().values().cloned().collect();
        for session in sessions {
            session.notify_network_change().await;
        }
    }

    /// Forcibly abandon the currently-installed underlying connection
    /// for every active session. The session worker observes the close
    /// on the next `client.next_event()` poll and rebuilds via its
    /// existing reconnect path — the post-reconnect resubscribe in
    /// `spawn_health_reader` re-attaches the new `ConnectionId` to each
    /// loaded thread's subscription set.
    ///
    /// Called from the platform lifecycle when we have out-of-band
    /// knowledge that the connection is dead (e.g. iOS resumed us after
    /// suspension longer than iroh's per-path idle timeout, so the
    /// existing path is silently dead and `network_change()` alone
    /// would only refresh the endpoint's discovery layer — not the
    /// connection-level path). See `ReconnectController::on_long_resume`.
    pub async fn abandon_alleycat_connections(&self) {
        let sessions: Vec<Arc<ServerSession>> = self.sessions_read().values().cloned().collect();
        for session in sessions {
            // Direct-resume markers are scoped to a live `ConnectionId`. Once
            // we close the underlying Connection, any subsequent
            // `external_resume_thread` for this server must re-issue
            // `thread/resume` against the new connection — otherwise it
            // would short-circuit on the stale marker and the new
            // `ConnectionId` would never be added to the per-thread
            // subscription set, silencing turn-stream events. The
            // post-reconnect resubscribe in `spawn_health_reader` also
            // clears these on Disconnected→Connected, but doing it eagerly
            // here lets a refresh issued before the new connection is up
            // (e.g. push-wake `refreshTrackedThreads`) take the slow path.
            self.clear_direct_resume_markers_for_server(session.config().server_id.as_str());
            session.close_current_connections().await;
        }
    }

    /// Gracefully close the shared alleycat iroh `Endpoint` if it has
    /// been initialized. Awaits iroh's close handshake (sends
    /// CONNECTION_CLOSE to peers, drains in-flight ACKs). Idempotent —
    /// calling on an already-closed or never-initialized endpoint is a
    /// no-op.
    pub async fn shutdown_alleycat_endpoint(&self) {
        let Some(endpoint) = self.alleycat_endpoint.get().cloned() else {
            return;
        };
        if endpoint.is_closed() {
            return;
        }
        info!("MobileClient: shutting down alleycat endpoint");
        endpoint.close().await;
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
        match self.alleycat_restart_targets.lock() {
            Ok(mut guard) => {
                guard.remove(server_id);
            }
            Err(error) => {
                error.into_inner().remove(server_id);
            }
        }
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
        let alleycat_restart_target = match self.alleycat_restart_targets.lock() {
            Ok(guard) => guard.get(server_id).cloned(),
            Err(error) => error.into_inner().get(server_id).cloned(),
        };
        if let Some(target) = alleycat_restart_target {
            let endpoint = self
                .alleycat_endpoint()
                .await
                .map_err(|error| TransportError::ConnectionFailed(error.to_string()))?;
            crate::alleycat::restart_agent(&endpoint, target.params, "codex".to_string())
                .await
                .map_err(|error| TransportError::ConnectionFailed(error.to_string()))?;
        }
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

        let params = upstream::LoginAccountParams::Chatgpt {
            codex_streamlined_login: false,
        };
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
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let reconcile_active_items = self.app_store.thread_snapshot(&key).is_some_and(|thread| {
            thread.active_turn_id.is_some()
                || matches!(thread.info.status, ThreadSummaryStatus::Active)
        });
        self.external_resume_thread_inner(server_id, thread_id, host_id, reconcile_active_items)
            .await?;
        maybe_send_next_local_queued_follow_up(
            Arc::clone(&self.app_store),
            Arc::clone(&self.sessions),
            key,
        )
        .await;
        Ok(())
    }

    /// Force a fresh `thread/resume` against the server even if a direct
    /// listener was already attached for the current session, and feed
    /// `reconcile_active_turn` enough turn-status info to clear a
    /// locally-cached `active_turn_id` whose underlying turn has finished
    /// while the client was disconnected.
    ///
    /// On paginated remotes (`supports_turn_pagination`) the resume runs
    /// with `exclude_turns: true` and a small follow-up
    /// `thread/turns/list?limit=5&items_view=notLoaded` query supplies the
    /// turn skeletons for reconcile — pulling the entire embedded turn
    /// archive here would OOM mobile clients on long threads. Legacy
    /// remotes that don't implement `thread/turns/list` still pull the
    /// embedded turn list (`exclude_turns: false`), since there is no
    /// other way to learn turn status there.
    ///
    pub async fn force_refresh_thread_authoritative(
        &self,
        server_id: &str,
        thread_id: &str,
    ) -> Result<(), RpcError> {
        self.external_resume_thread_inner(server_id, thread_id, None, true)
            .await?;
        maybe_send_next_local_queued_follow_up(
            Arc::clone(&self.app_store),
            Arc::clone(&self.sessions),
            ThreadKey {
                server_id: server_id.to_string(),
                thread_id: thread_id.to_string(),
            },
        )
        .await;
        Ok(())
    }

    async fn external_resume_thread_inner(
        &self,
        server_id: &str,
        thread_id: &str,
        host_id: Option<String>,
        force_authoritative: bool,
    ) -> Result<(), RpcError> {
        let session = self.get_session(server_id)?;
        if host_id.is_some() {
            trace!(
                "external_resume_thread ignoring explicit host_id for server={} thread={}",
                server_id, thread_id
            );
        }
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let resume_lock = self.resume_lock(&key);
        let (waited, _resume_guard) = match resume_lock.try_lock() {
            Ok(guard) => (false, guard),
            Err(_) => (true, resume_lock.lock().await),
        };
        if can_reuse_waited_resume(
            waited,
            force_authoritative,
            self.has_direct_resume_marker(&key),
        ) {
            self.app_store.mark_thread_resumed(&key, true);
            return Ok(());
        }

        // Force path skips both short-circuits — caller has out-of-band
        // knowledge that the locally-cached snapshot may have missed
        // turn-completion events.
        if !force_authoritative {
            if self.has_direct_resume_marker(&key) {
                // The marker is set after a successful `thread/resume`
                // for the current session — server-side this means the
                // connection is in the per-thread subscription set. We
                // can skip a duplicate resume when *either* of:
                //   - the thread has loaded turns (items / initial_turns_loaded);
                //   - the server is using pagination (`supports_turn_pagination`),
                //     so a `thread/resume` under `exclude_turns: true`
                //     intentionally returned empty — the data path is
                //     `thread/turns/list`, not another resume.
                // Otherwise (thread truly empty AND pagination off), we
                // need to refresh because the previous resume returned
                // nothing usable.
                let thread_has_loaded_turns = self
                    .app_store
                    .thread_snapshot(&key)
                    .is_some_and(|thread| !thread.items.is_empty() || thread.initial_turns_loaded);
                let pagination_supported =
                    self.app_store.server_supports_turn_pagination(server_id);
                if thread_has_loaded_turns || pagination_supported {
                    debug!(
                        "external_resume_thread: skipping RPC for server={} thread={} — direct listener already attached for current session (loaded={} pagination={})",
                        server_id, thread_id, thread_has_loaded_turns, pagination_supported
                    );
                    self.app_store.mark_thread_resumed(&key, true);
                    return Ok(());
                }
                debug!(
                    "external_resume_thread: direct listener exists but thread has no loaded turns and pagination is off, refreshing server={} thread={}",
                    server_id, thread_id
                );
            }
        } else {
            debug!(
                "external_resume_thread: force-authoritative refresh server={} thread={}",
                server_id, thread_id
            );
        }
        let available_runtimes = session.runtime_kinds();
        let mut runtime_candidates = Vec::new();
        let preferred_runtime = self.runtime_for_thread(&key);
        if available_runtimes.contains(&preferred_runtime) {
            runtime_candidates.push(preferred_runtime);
        }
        for runtime_kind in available_runtimes {
            if !runtime_candidates.contains(&runtime_kind) {
                runtime_candidates.push(runtime_kind);
            }
        }

        let mut lookup_errors = Vec::new();
        for runtime_kind in runtime_candidates.iter().cloned() {
            let supports_pagination = self.app_store.server_supports_turn_pagination(server_id);
            // Paginated servers always exclude turns from the resume
            // response; we never want to pull the full embedded archive,
            // even on the authoritative refresh path — for huge threads
            // that response can be hundreds of MB and OOMs the device.
            // For the authoritative refresh path on paginated servers we
            // run a separate small `thread/turns/list` probe below to give
            // `reconcile_active_turn` the turn-status info it needs to
            // clear a stale local `active_turn_id`.
            // Legacy servers that do not implement `thread/turns/list`
            // still need the embedded turn list, since there is no other
            // way to learn turn status — so `exclude_turns=false` there.
            let exclude_turns = supports_pagination;
            match self
                .resume_thread_for_runtime(
                    server_id,
                    thread_id,
                    &key,
                    runtime_kind.clone(),
                    exclude_turns,
                )
                .await
            {
                Ok(()) => {
                    self.note_thread_runtime(key.clone(), runtime_kind.clone());
                    let post_resume_active = self
                        .app_store
                        .thread_snapshot(&key)
                        .is_some_and(|thread| {
                            thread.active_turn_id.is_some()
                                || matches!(thread.info.status, ThreadSummaryStatus::Active)
                        });
                    if supports_pagination && (force_authoritative || post_resume_active) {
                        self.reconcile_active_turn_via_turn_list_probe(
                            server_id,
                            thread_id,
                            &key,
                            runtime_kind,
                        )
                        .await;
                    }
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
                    self.read_thread_metadata_only_for_runtime(
                        server_id,
                        thread_id,
                        runtime_kind.clone(),
                    )
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
                .read_thread_metadata_only_for_runtime(server_id, thread_id, runtime_kind.clone())
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
                runtime_kind.clone(),
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
        if exclude_turns && !server_honored_exclude_turns {
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
        snapshot.agent_runtime_kind = runtime_kind.clone();
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

    /// On the authoritative refresh path (`force_refresh_thread_authoritative`)
    /// for paginated remotes, run a small `thread/turns/list` query that
    /// returns turn skeletons only (no item bodies). The result is fed into
    /// `reconcile_active_turn`, then a bounded full page repairs item bodies
    /// for a turn that was active before the disconnect. That second read is
    /// necessary even when the turn is still running: tool-start and output
    /// events may have crossed the transport while iOS was suspended.
    /// Failures here are logged and ignored — the next streamed event or
    /// foreground refresh gets another chance to reconcile.
    async fn reconcile_active_turn_via_turn_list_probe(
        &self,
        server_id: &str,
        thread_id: &str,
        key: &ThreadKey,
        runtime_kind: AgentRuntimeKind,
    ) {
        const PROBE_LIMIT: u32 = 5;
        let request = upstream::ClientRequest::ThreadTurnsList {
            request_id: upstream::RequestId::Integer(crate::next_request_id()),
            params: upstream::ThreadTurnsListParams {
                thread_id: thread_id.to_string(),
                cursor: None,
                limit: Some(PROBE_LIMIT),
                sort_direction: Some(upstream::SortDirection::Desc),
                items_view: Some(upstream::TurnItemsView::NotLoaded),
            },
        };
        let response = match self
            .request_typed_for_server_runtime::<upstream::ThreadTurnsListResponse>(
                server_id,
                runtime_kind.clone(),
                request,
            )
            .await
        {
            Ok(response) => response,
            Err(error) => {
                if is_method_not_found(&error) {
                    // Some non-Codex runtimes can resume a thread but do not
                    // implement the lightweight turn-list probe. Fall back to
                    // one embedded-turn resume so reconcile_active_turn can
                    // still clear a stale active turn after mobile reconnects.
                    if runtime_kind == "codex" {
                        self.app_store
                            .set_server_supports_turn_pagination(server_id, false);
                    }
                    if let Err(fallback_error) = self
                        .resume_thread_for_runtime(
                            server_id,
                            thread_id,
                            key,
                            runtime_kind.clone(),
                            false,
                        )
                        .await
                    {
                        warn!(
                            "force_authoritative: embedded resume fallback failed server={} thread={} runtime={:?} error={}",
                            server_id, thread_id, runtime_kind, fallback_error
                        );
                    }
                } else {
                    warn!(
                        "force_authoritative: turn-list probe failed server={} thread={} error={}",
                        server_id, thread_id, error
                    );
                }
                return;
            }
        };
        let Some(existing) = self.app_store.thread_snapshot(key) else {
            return;
        };
        let was_active = existing.active_turn_id.is_some()
            || matches!(existing.info.status, ThreadSummaryStatus::Active);
        let mut target = existing.clone();
        // Clear the field on the target so reconcile_active_turn can decide
        // whether to restore it from `existing` based on the turn list.
        target.active_turn_id = None;
        reconcile_active_turn(Some(&existing), &mut target, &response.data);
        let is_active = target.active_turn_id.is_some()
            || matches!(target.info.status, ThreadSummaryStatus::Active);
        if target.active_turn_id != existing.active_turn_id
            || target.info.status != existing.info.status
        {
            self.app_store.upsert_thread_snapshot(target);
        }
        if (was_active || is_active)
            && let Err(error) = self
                .load_thread_turns_page(server_id, thread_id, None, Some(PROBE_LIMIT))
                .await
        {
            warn!(
                "force_authoritative: active-turn repair page failed server={} thread={}: {}",
                server_id, thread_id, error
            );
        }
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
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        if !self.app_store.server_supports_turn_pagination(server_id) {
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
            items_view: None,
        };
        let request = upstream::ClientRequest::ThreadTurnsList {
            request_id: upstream::RequestId::Integer(crate::next_request_id()),
            params,
        };
        let runtime_kind = self.runtime_for_thread(&key);
        match self
            .request_typed_for_server_runtime::<upstream::ThreadTurnsListResponse>(
                server_id,
                runtime_kind.clone(),
                request,
            )
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
                if runtime_kind == "codex".to_string() {
                    self.app_store
                        .set_server_supports_turn_pagination(server_id, false);
                }
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
        self.get_session(server_id)?;
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
        if let Some(thread) = thread_snapshot.as_ref()
            && !self.runtime_supports_thread_permission_overrides(&thread.agent_runtime_kind)
        {
            if params.approval_policy.is_some() || params.sandbox_policy.is_some() {
                info!(
                    server_id = %server_id,
                    thread_id = %params.thread_id,
                    runtime = %thread.agent_runtime_kind,
                    "MobileClient: dropping non-authoritative turn permission overrides"
                );
            }
            params.approval_policy = None;
            params.sandbox_policy = None;
        }
        let has_active_turn = thread_snapshot.as_ref().is_some_and(|thread| {
            thread.active_turn_id.is_some()
                || matches!(thread.info.status, ThreadSummaryStatus::Active)
        });
        let direct_params = params.clone();
        let queued_draft = has_active_turn
            .then(|| {
                queued_follow_up_draft_from_inputs(&params.input, AppQueuedFollowUpKind::Message)
            })
            .flatten()
            .map(|mut draft| {
                draft.turn_start_params = Some(direct_params.clone());
                draft
            });
        if let Some(draft) = queued_draft.clone() {
            self.app_store
                .enqueue_thread_follow_up_draft(&thread_key, draft.clone());
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

        let Some(reservation_turn_id) = self.app_store.reserve_local_turn_start(&thread_key) else {
            // A TurnStarted/status event won the race after the snapshot was
            // read. Preserve this input as the next message instead of firing
            // a conflicting second turn/start.
            if let Some(mut draft) = queued_follow_up_draft_from_inputs(
                &params.input,
                AppQueuedFollowUpKind::Message,
            ) {
                draft.turn_start_params = Some(direct_params.clone());
                self.app_store
                    .enqueue_thread_follow_up_draft(&thread_key, draft);
                return Ok(());
            }
            return Err(RpcError::Deserialization(
                "thread became active before the turn could be reserved".to_string(),
            ));
        };
        // Stage an optimistic local overlay so the user sees their message
        // immediately, before the server echoes it back.
        let optimistic_overlay_id = self
            .app_store
            .stage_local_user_message_overlay(&thread_key, &params.input);
        let direct_command_id = self.app_store.begin_server_mutating_command(
            server_id,
            ServerMutatingCommandKind::StartTurn,
            &params.thread_id,
        );
        let response_result = self
            .request_typed_for_server::<upstream::TurnStartResponse>(
                server_id,
                upstream::ClientRequest::TurnStart {
                    request_id: upstream::RequestId::Integer(crate::next_request_id()),
                    params: direct_params,
                },
            )
            .await;
        let response = match response_result {
            Ok(response) => response,
            Err(error) => {
                if self
                    .app_store
                    .release_local_turn_start(&thread_key, &reservation_turn_id)
                {
                    self.app_store
                        .finish_server_mutating_command_failure(server_id, &direct_command_id);
                    if let Some(overlay_id) = optimistic_overlay_id.as_ref() {
                        self.app_store
                            .remove_local_overlay_item(&thread_key, overlay_id);
                    }
                    return Err(RpcError::Deserialization(error));
                }
                // A live TurnStarted/TurnCompleted event already replaced the
                // reservation, so the server accepted the turn even though
                // its response raced a transport failure.
                self.app_store
                    .finish_server_mutating_command_success(server_id, &direct_command_id);
                return Ok(());
            }
        };
        self.app_store
            .finish_server_mutating_command_success(server_id, &direct_command_id);
        if let Some(overlay_id) = optimistic_overlay_id.as_ref() {
            self.app_store.bind_local_user_message_overlay_to_turn(
                &thread_key,
                overlay_id,
                &response.turn.id,
            );
        }
        self.app_store.resolve_local_turn_start(
            &thread_key,
            &reservation_turn_id,
            &response.turn.id,
        );
        Ok(())
    }

    pub async fn steer_queued_follow_up(
        &self,
        key: &ThreadKey,
        preview_id: &str,
    ) -> Result<(), RpcError> {
        self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        if !thread
            .queued_follow_up_drafts
            .iter()
            .any(|draft| draft.preview.id == preview_id)
        {
            return Err(RpcError::Deserialization(format!(
                "queued follow-up not found: {preview_id}"
            )));
        }

        // Atomically flip the draft's kind to PendingSteer. If it's already
        // pending (concurrent/duplicate tap), drop this request so we don't
        // fire a second steer that would inject another copy of the user
        // message.
        let Some((draft, _next_drafts)) = self
            .app_store
            .try_begin_steer_queued_follow_up(key, preview_id)
        else {
            return Ok(());
        };

        let active_turn_id = thread.active_turn_id.ok_or_else(|| {
            RpcError::Deserialization("no active turn available to steer".to_string())
        })?;

        let direct_command_id = self.app_store.begin_server_mutating_command(
            &key.server_id,
            ServerMutatingCommandKind::SteerQueuedFollowUp,
            &key.thread_id,
        );
        if let Err(error) = self
            .request_typed_for_server::<upstream::TurnSteerResponse>(
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
        {
            self.app_store
                .finish_server_mutating_command_failure(&key.server_id, &direct_command_id);
            return Err(RpcError::Deserialization(error));
        }
        self.app_store
            .finish_server_mutating_command_success(&key.server_id, &direct_command_id);
        // Keep draft visible as PendingSteer; TurnCompleted will clean it up.
        Ok(())
    }

    pub async fn delete_queued_follow_up(
        &self,
        key: &ThreadKey,
        preview_id: &str,
    ) -> Result<(), RpcError> {
        self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        let next_drafts = thread
            .queued_follow_up_drafts
            .into_iter()
            .filter(|draft| draft.preview.id != preview_id)
            .collect::<Vec<_>>();

        let direct_command_id = self.app_store.begin_server_mutating_command(
            &key.server_id,
            ServerMutatingCommandKind::DeleteQueuedFollowUp,
            &key.thread_id,
        );
        self.app_store.set_thread_follow_up_drafts(key, next_drafts);
        self.app_store
            .finish_server_mutating_command_success(&key.server_id, &direct_command_id);
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
        let response_json = approval_response_json(&approval, approval_seed.as_ref(), decision)?;
        let response_request_id =
            server_request_id_json(approval_request_id(&approval, approval_seed.as_ref()));
        let runtime_kind = approval
            .thread_id
            .as_ref()
            .map(|thread_id| {
                self.runtime_for_thread(&ThreadKey {
                    server_id: approval.server_id.clone(),
                    thread_id: thread_id.clone(),
                })
            })
            .unwrap_or_else(|| "codex".to_string());
        let direct_command_id = self.app_store.begin_server_mutating_command(
            &approval.server_id,
            ServerMutatingCommandKind::ApprovalResponse,
            approval.thread_id.as_deref().unwrap_or(""),
        );
        if let Err(error) = session
            .respond_for_runtime(runtime_kind, response_request_id, response_json)
            .await
        {
            self.app_store
                .finish_server_mutating_command_failure(&approval.server_id, &direct_command_id);
            return Err(error);
        }
        self.app_store
            .finish_server_mutating_command_success(&approval.server_id, &direct_command_id);
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
        let seed = self
            .app_store
            .pending_user_input_seed(&request.server_id, &request.id);
        let normalized_answers = normalize_pending_user_input_answers(&request, &answers);
        let answered_inputs = normalized_answers.clone();
        let session = self.get_session(&request.server_id)?;
        if let Some(seed) = seed.as_ref()
            && matches!(
                seed.response_kind,
                PendingUserInputResponseKind::McpServerElicitation
            )
        {
            let response_json = mcp_elicitation_response_json(seed, &answers)?;
            let response_request_id = server_request_id_json(seed.request_id.clone());
            let runtime_kind = self.runtime_for_thread(&ThreadKey {
                server_id: request.server_id.clone(),
                thread_id: request.thread_id.clone(),
            });
            let direct_command_id = self.app_store.begin_server_mutating_command(
                &request.server_id,
                ServerMutatingCommandKind::UserInputResponse,
                &request.thread_id,
            );
            if let Err(error) = session
                .respond_for_runtime(runtime_kind, response_request_id, response_json)
                .await
            {
                self.app_store
                    .finish_server_mutating_command_failure(&request.server_id, &direct_command_id);
                return Err(error);
            }
            self.app_store
                .finish_server_mutating_command_success(&request.server_id, &direct_command_id);
            debug!(
                "MobileClient: MCP elicitation response sent for server={} request_id={}",
                request.server_id, request_id
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
        let response_request_id = server_request_id_json(
            seed.as_ref()
                .filter(|seed| {
                    matches!(
                        seed.response_kind,
                        PendingUserInputResponseKind::ToolRequestUserInput
                    )
                })
                .map(|seed| seed.request_id.clone())
                .unwrap_or_else(|| fallback_server_request_id(&request.id)),
        );
        let runtime_kind = self.runtime_for_thread(&ThreadKey {
            server_id: request.server_id.clone(),
            thread_id: request.thread_id.clone(),
        });
        let direct_command_id = self.app_store.begin_server_mutating_command(
            &request.server_id,
            ServerMutatingCommandKind::UserInputResponse,
            &request.thread_id,
        );
        if let Err(error) = session
            .respond_for_runtime(runtime_kind, response_request_id, response_json)
            .await
        {
            self.app_store
                .finish_server_mutating_command_failure(&request.server_id, &direct_command_id);
            return Err(error);
        }
        self.app_store
            .finish_server_mutating_command_success(&request.server_id, &direct_command_id);
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

    /// Open a new terminal session, store the strong handle on the
    /// client, register a snapshot entry on the reducer, and wire output
    /// bytes back into the ring buffer. Returns the generated session
    /// id.
    pub async fn open_terminal_session(
        &self,
        kind: crate::terminal::TerminalBackendKind,
        size: crate::terminal::TerminalSize,
        trust_store: Option<Arc<crate::terminal::TerminalSshTrustStore>>,
    ) -> Result<String, crate::terminal::TerminalError> {
        let session = match trust_store {
            Some(store) => {
                crate::terminal::TerminalSession::open_with_trust_store(kind.clone(), size, store)
                    .await?
            }
            None => crate::terminal::TerminalSession::open(kind.clone(), size).await?,
        };
        let session = Arc::new(session);
        let id = uuid::Uuid::new_v4().to_string();
        self.terminal_sessions
            .lock()
            .expect("terminal_sessions poisoned")
            .insert(id.clone(), Arc::clone(&session));
        self.app_store
            .open_terminal_session_record(id.clone(), kind, size.cols, size.rows);

        // Subscribe to the session's output to feed the ring buffer.
        let reducer = Arc::clone(&self.app_store);
        let id_for_listener = id.clone();
        let strong = Arc::clone(&session);
        let sessions = Arc::clone(&self.terminal_sessions);
        let listener: Box<dyn crate::terminal::TerminalOutputListener> =
            Box::new(TerminalRingListener {
                reducer,
                id: id_for_listener,
                sessions,
            });
        strong.subscribe_output(listener);
        Ok(id)
    }

    /// Close a terminal session: drop the strong handle (which kills the
    /// underlying backend on the last reference being released), then
    /// mark the snapshot as exited. The snapshot's output_tail is
    /// retained until [`MobileClient::forget_terminal_session`].
    pub async fn close_terminal_session(
        &self,
        id: &str,
    ) -> Result<(), crate::terminal::TerminalError> {
        let session = self
            .terminal_sessions
            .lock()
            .expect("terminal_sessions poisoned")
            .remove(id);
        if let Some(session) = session {
            session.close_session().await?;
        }
        self.app_store.mark_terminal_exited(id, 0);
        Ok(())
    }

    /// Forget a session entirely (drop the snapshot's buffered output).
    pub fn forget_terminal_session(&self, id: &str) {
        self.terminal_sessions
            .lock()
            .expect("terminal_sessions poisoned")
            .remove(id);
        self.app_store.remove_terminal_session_record(id);
    }

    /// Return the live session handle for `id`, or `None` if the session
    /// has been closed.
    pub fn terminal_session_handle(
        &self,
        id: &str,
    ) -> Option<Arc<crate::terminal::TerminalSession>> {
        self.terminal_sessions
            .lock()
            .expect("terminal_sessions poisoned")
            .get(id)
            .cloned()
    }

    /// Write `bytes` to the currently-active terminal session, if any.
    /// Returns `Ok(false)` if there is no active session.
    pub async fn write_to_active_terminal(
        &self,
        bytes: Vec<u8>,
    ) -> Result<bool, crate::terminal::TerminalError> {
        let active_id = self.app_store.snapshot().active_terminal_id.clone();
        let Some(id) = active_id else {
            return Ok(false);
        };
        let Some(session) = self.terminal_session_handle(&id) else {
            return Ok(false);
        };
        session.write_input(bytes).await?;
        Ok(true)
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_active_thread(key);
    }

    pub async fn set_thread_collaboration_mode(
        &self,
        key: &ThreadKey,
        mode: AppModeKind,
    ) -> Result<(), RpcError> {
        self.get_session(&key.server_id)?;
        self.app_store.set_thread_collaboration_mode(key, mode);
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
                runtime_workspace_roots: None,
                approval_policy: None,
                approvals_reviewer: None,
                sandbox_policy: None,
                environments: None,
                permissions: None,
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

/// Listener that feeds session output bytes into the reducer's ring
/// buffer and marks the session exited when the backend reports exit.
struct TerminalRingListener {
    reducer: Arc<AppStoreReducer>,
    id: String,
    sessions: Arc<StdMutex<HashMap<String, Arc<crate::terminal::TerminalSession>>>>,
}

impl crate::terminal::TerminalOutputListener for TerminalRingListener {
    fn on_bytes(&self, data: Vec<u8>) {
        self.reducer.append_terminal_output(&self.id, &data);
    }
    fn on_exit(&self, code: i32) {
        self.reducer.mark_terminal_exited(&self.id, code);
        self.sessions
            .lock()
            .expect("terminal_sessions poisoned")
            .remove(&self.id);
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
        let runtime_kinds = session.runtime_kinds();
        if !runtime_kinds_support_account_sync(&runtime_kinds) {
            trace!(
                "MobileClient: {label} account sync skipped server_id={server_id} runtime_kinds={runtime_kinds:?}"
            );
            return;
        }
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

pub(super) fn runtime_kinds_support_account_sync(runtime_kinds: &[AgentRuntimeKind]) -> bool {
    runtime_kinds
        .iter()
        .any(|runtime_kind| runtime_kind == "codex")
}

pub(super) fn run_post_reconnect_resubscribe(app_store: Arc<AppStoreReducer>, server_id: String) {
    MobileClient::spawn_detached(async move {
        let Some(client) = crate::ffi::shared::shared_mobile_client_if_initialized() else {
            return;
        };
        client.clear_direct_resume_markers_for_server(&server_id);

        let snapshot = app_store.snapshot();
        let mut keys_to_resume: Vec<ThreadKey> = Vec::new();
        if let Some(active) = snapshot.active_thread.as_ref()
            && active.server_id == server_id
        {
            keys_to_resume.push(active.clone());
        }
        for (key, thread) in snapshot.threads.iter() {
            if key.server_id != server_id {
                continue;
            }
            if keys_to_resume.iter().any(|k| k == key) {
                continue;
            }
            if thread.active_turn_id.is_some() || !thread.queued_follow_ups.is_empty() {
                keys_to_resume.push(key.clone());
            }
        }

        if keys_to_resume.is_empty() {
            debug!(
                "MobileClient: post-reconnect resubscribe nothing to do server_id={}",
                server_id
            );
            return;
        }

        info!(
            "MobileClient: post-reconnect resubscribe server_id={} thread_count={}",
            server_id,
            keys_to_resume.len()
        );

        for key in keys_to_resume {
            match client
                .force_refresh_thread_authoritative(&key.server_id, &key.thread_id)
                .await
            {
                Ok(()) => debug!(
                    "MobileClient: post-reconnect resubscribe ok server_id={} thread_id={}",
                    key.server_id, key.thread_id
                ),
                Err(error) => warn!(
                    "MobileClient: post-reconnect resubscribe failed server_id={} thread_id={}: {}",
                    key.server_id, key.thread_id, error
                ),
            }
        }
    });
}
