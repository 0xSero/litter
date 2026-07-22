use std::collections::{HashMap, HashSet};
use std::ffi::{OsStr, OsString};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Duration;
use alleycat_bridge_core::{ChildProcess, ProcessLauncher, ProcessSpec};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, SecondsFormat, Utc};
use futures::future::BoxFuture;
use iroh::{Endpoint, SecretKey};
use regex::Regex;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use uuid::Uuid;
use crate::alleycat::{AgentInfo, AgentWire, AlleycatSession, AlleycatStream, ParsedPairPayload};
use crate::reconnect::SavedServerRecord;
use crate::ssh::{RemoteShell, SshClient, SshError};
pub const LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION: u32 = 1;
pub(crate) const RUNTIME_KIND: &str = "local-studio";
const LOCAL_STUDIO_AGENT_NAME: &str = "local-studio";
const LOCAL_STUDIO_REQUEST_DOMAIN: &[u8] = b"litter-bridge-request-v1";
const LOCAL_STUDIO_RPC_TIMEOUT: Duration = Duration::from_secs(10);
const LOCAL_STUDIO_SESSION_MAX_PAGE_ITEMS: usize = 200;
const LOCAL_STUDIO_AGENT_TURN_MAX_UTF16_CODE_UNITS: usize = 100_000;
const LOCAL_STUDIO_SHORT_TEXT_MAX_CHARS: usize = 4_096;
const LOCAL_STUDIO_WIRE_TEXT_MAX_CHARS: usize = 4_000_000;
const LOCAL_STUDIO_JSON_TEXT_MAX_CHARS: usize = 1_000_000;
const LOCAL_STUDIO_CURSOR_MAX_CHARS: usize = 2_048;
const FIND_AGENT_DIR: &str = r#"find_local_studio_agent_dir() {
  for candidate in \
    "${LOCAL_STUDIO_DATA_DIR:+$LOCAL_STUDIO_DATA_DIR/pi-agent}" \
    "$HOME/Library/Application Support/Local Studio/pi-agent" \
    "$HOME/.vllm-studio/pi-agent" \
    "$HOME/.local-studio/pi-agent"
  do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate/models.json" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}"#;
pub(crate) fn probe_script() -> String {
    format!(
        r#"{FIND_AGENT_DIR}
agent_dir=$(find_local_studio_agent_dir 2>/dev/null || true)
pi_bin=$(command -v pi-coding-agent 2>/dev/null || command -v pi 2>/dev/null || true)
if [ -n "$agent_dir" ] && [ -n "$pi_bin" ]; then
  printf 'local-studio\t%s\n' "$agent_dir"
else
  printf 'local-studio\t\n'
fi"#
    )
}
pub(crate) async fn resolve_agent_dir(
    ssh: &SshClient,
    shell: RemoteShell,
) -> Result<Option<String>, SshError> {
    let result = ssh
        .exec_shell(
            &format!("{FIND_AGENT_DIR}\nfind_local_studio_agent_dir"),
            shell,
        )
        .await?;
    if result.exit_code != 0 {
        return Ok(None);
    }
    Ok(result
        .stdout
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(ToOwned::to_owned))
}
pub(crate) fn session_scan_prefix(agent_dir: &str) -> String {
    format!(
        "PI_CODING_AGENT_DIR={}\nexport PI_CODING_AGENT_DIR",
        crate::ssh::shell_quote(agent_dir)
    )
}
pub(crate) fn launcher(
    inner: Arc<dyn ProcessLauncher>,
    agent_dir: &str,
) -> Arc<dyn ProcessLauncher> {
    Arc::new(EnvironmentOverlayLauncher {
        inner,
        key: OsString::from("PI_CODING_AGENT_DIR"),
        value: OsStr::new(agent_dir).to_os_string(),
    })
}
#[derive(Clone)]
struct EnvironmentOverlayLauncher {
    inner: Arc<dyn ProcessLauncher>,
    key: OsString,
    value: OsString,
}
impl ProcessLauncher for EnvironmentOverlayLauncher {
    fn launch(
        &self,
        mut spec: ProcessSpec,
    ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
        let key = self.key.clone();
        let value = self.value.clone();
        Box::pin(async move {
            if !spec.env.iter().any(|(candidate, _)| candidate == &key) {
                spec.env.push((key, value));
            }
            self.inner.launch(spec).await
        })
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum LocalStudioCapability {
    #[serde(rename = "stats.read")]
    StatsRead,
    #[serde(rename = "models.control")]
    ModelsControl,
    #[serde(rename = "sessions.read")]
    SessionsRead,
    #[serde(rename = "sessions.write")]
    SessionsWrite,
    #[serde(rename = "agent.turn")]
    AgentTurn,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioControllerActionKind {
    StartRecipe,
    CancelLaunch,
    EvictModel,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioAdvertisement {
    pub protocol_version: u32,
    pub bridge_id: String,
    pub controller_id: String,
    pub issued_at: String,
    pub capabilities: Vec<LocalStudioCapability>,
    pub actions: Vec<LocalStudioControllerActionKind>,
}
impl LocalStudioCapability {
    fn as_str(self) -> &'static str {
        match self {
            Self::StatsRead => "stats.read",
            Self::ModelsControl => "models.control",
            Self::SessionsRead => "sessions.read",
            Self::SessionsWrite => "sessions.write",
            Self::AgentTurn => "agent.turn",
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioErrorCode {
    InvalidRequest,
    Unauthorized,
    Forbidden,
    ExpiredRequest,
    ReplayDetected,
    UnsupportedVersion,
    CapabilityDenied,
    NotFound,
    RevisionConflict,
    RateLimited,
    PayloadTooLarge,
    IntegrityFailed,
    ControllerUnavailable,
    SectionUnavailable,
    AgentRuntimeUnavailable,
    Internal,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum LocalStudioSectionName {
    #[serde(rename = "health")]
    Health,
    #[serde(rename = "status")]
    Status,
    #[serde(rename = "gpus")]
    Gpus,
    #[serde(rename = "metrics")]
    Metrics,
    #[serde(rename = "agent-runtime")]
    AgentRuntime,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioErrorDetails {
    #[serde(deserialize_with = "deserialize_optional_identifier")]
    pub field: Option<String>,
    #[serde(deserialize_with = "deserialize_required_option")]
    pub section: Option<LocalStudioSectionName>,
    #[serde(deserialize_with = "deserialize_optional_safe_u64")]
    pub expected_revision: Option<u64>,
    #[serde(deserialize_with = "deserialize_optional_safe_u64")]
    pub current_revision: Option<u64>,
    #[serde(deserialize_with = "deserialize_optional_safe_u64")]
    pub retry_after_ms: Option<u64>,
    #[serde(deserialize_with = "deserialize_optional_safe_u64")]
    pub limit_bytes: Option<u64>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioBridgeError {
    pub code: LocalStudioErrorCode,
    pub message: String,
    pub retriable: bool,
    #[serde(deserialize_with = "deserialize_optional_identifier")]
    pub request_id: Option<String>,
    #[serde(deserialize_with = "deserialize_required_option")]
    pub details: Option<LocalStudioErrorDetails>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioErrorResult {
    pub protocol_version: u32,
    pub request_id: String,
    pub error: LocalStudioBridgeError,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioFreshness {
    pub observed_at: Option<String>,
    pub age_ms: Option<u64>,
    pub max_age_ms: u64,
    pub stale: bool,
    pub source_revision: Option<u64>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioComponentState {
    Ok,
    Degraded,
    Unavailable,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioSnapshotState {
    Healthy,
    Degraded,
    Unavailable,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioControllerHealth {
    pub state: LocalStudioComponentState,
    pub reachable: bool,
    pub checked_at: String,
    pub latency_ms: Option<f64>,
    pub controller_version: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioControllerStatus {
    pub running: bool,
    pub inference_port: Option<u64>,
    pub launching_recipe_id: Option<String>,
    pub active_launch_id: Option<String>,
    pub active_model_ids: Vec<String>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioGpuDevice {
    pub id: String,
    pub index: u64,
    pub name: String,
    pub memory_total_bytes: u64,
    pub memory_used_bytes: Option<u64>,
    pub memory_free_bytes: Option<u64>,
    pub utilization_percent: Option<f64>,
    pub temperature_celsius: Option<f64>,
    pub power_watts: Option<f64>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioGpuSnapshot {
    pub count: u64,
    pub devices: Vec<LocalStudioGpuDevice>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioMetrics {
    pub requests_active: Option<u64>,
    pub requests_queued: Option<u64>,
    pub prompt_tokens_per_second: Option<f64>,
    pub generation_tokens_per_second: Option<f64>,
    pub time_to_first_token_ms: Option<f64>,
    pub cache_usage_percent: Option<f64>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioAgentRuntimeStats {
    pub state: LocalStudioComponentState,
    pub reachable: bool,
    pub running_session_count: u64,
    pub active_turn_count: u64,
    pub persisted_session_count: Option<u64>,
    pub event_sequence: Option<u64>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioHealthSection {
    pub value: Option<LocalStudioControllerHealth>,
    pub error: Option<LocalStudioBridgeError>,
    pub freshness: LocalStudioFreshness,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioStatusSection {
    pub value: Option<LocalStudioControllerStatus>,
    pub error: Option<LocalStudioBridgeError>,
    pub freshness: LocalStudioFreshness,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioGpusSection {
    pub value: Option<LocalStudioGpuSnapshot>,
    pub error: Option<LocalStudioBridgeError>,
    pub freshness: LocalStudioFreshness,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioMetricsSection {
    pub value: Option<LocalStudioMetrics>,
    pub error: Option<LocalStudioBridgeError>,
    pub freshness: LocalStudioFreshness,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioAgentRuntimeSection {
    pub value: Option<LocalStudioAgentRuntimeStats>,
    pub error: Option<LocalStudioBridgeError>,
    pub freshness: LocalStudioFreshness,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioControllerSections {
    pub health: LocalStudioHealthSection,
    pub status: LocalStudioStatusSection,
    pub gpus: LocalStudioGpusSection,
    pub metrics: LocalStudioMetricsSection,
    pub agent_runtime: LocalStudioAgentRuntimeSection,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioControllerSnapshot {
    pub protocol_version: u32,
    pub snapshot_id: String,
    pub controller_id: String,
    pub display_name: String,
    pub generated_at: String,
    pub revision: u64,
    pub state: LocalStudioSnapshotState,
    pub capabilities: Vec<LocalStudioCapability>,
    pub sections: LocalStudioControllerSections,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioCapabilitiesManifest {
    pub protocol_version: u32,
    pub bridge_id: String,
    pub controller_id: String,
    pub issued_at: String,
    pub capabilities: Vec<LocalStudioCapability>,
}
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LocalStudioControllerLoadResult {
    Loaded {
        manifest: LocalStudioCapabilitiesManifest,
        snapshot: LocalStudioControllerSnapshot,
    },
    Error {
        error: LocalStudioErrorResult,
    },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioSessionIdentityKind {
    ExternalSession,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum LocalStudioSessionAuthority {
    LocalStudio,
    Litter,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioExternalSessionIdentity {
    pub kind: LocalStudioSessionIdentityKind,
    pub authority: LocalStudioSessionAuthority,
    pub installation_id: String,
    pub session_id: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioSessionOrigin {
    pub application: LocalStudioSessionAuthority,
    pub installation_id: String,
    pub device_id: Option<String>,
    pub exported_at: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioSessionMetadata {
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub model_id: Option<String>,
    pub provider_id: Option<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioSessionListCursorKind {
    SessionListCursor,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioSessionListCursor {
    #[serde(rename = "type")]
    pub cursor_type: LocalStudioSessionListCursorKind,
    pub token: String,
    pub revision: u64,
    pub has_more: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioSessionDescriptor {
    pub session: LocalStudioExternalSessionIdentity,
    pub metadata: LocalStudioSessionMetadata,
    pub revision: u64,
    pub archived: bool,
    pub active: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioSessionListPage {
    pub protocol_version: u32,
    pub request_id: String,
    pub controller_id: String,
    pub revision: u64,
    pub sessions: Vec<LocalStudioSessionDescriptor>,
    pub cursor: Option<LocalStudioSessionListCursor>,
}
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LocalStudioSessionListResult {
    Page { page: LocalStudioSessionListPage },
    Error { error: LocalStudioErrorResult },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioMessageRole {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum LocalStudioMessagePart {
    Text { text: String },
    Reasoning { text: String },
    ToolRef { tool_call_id: String },
    AttachmentRef { attachment_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioMessageDescriptor {
    pub message_id: String,
    pub parent_message_id: Option<String>,
    pub sequence: u64,
    pub role: LocalStudioMessageRole,
    pub created_at: String,
    pub edited_at: Option<String>,
    pub parts: Vec<LocalStudioMessagePart>,
    pub content_hash: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioToolState {
    Requested,
    Running,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioToolDescriptor {
    pub tool_call_id: String,
    pub message_id: String,
    pub name: String,
    pub state: LocalStudioToolState,
    pub arguments_json: String,
    pub arguments_hash: String,
    pub result_json: Option<String>,
    pub result_hash: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioAttachmentAvailability {
    MetadataOnly,
    Available,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioAttachmentDescriptor {
    pub attachment_id: String,
    pub message_id: String,
    pub file_name: String,
    pub media_type: String,
    pub byte_length: u64,
    pub content_hash: String,
    pub blob_id: Option<String>,
    pub availability: LocalStudioAttachmentAvailability,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioHashReference {
    pub id: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum LocalStudioContentHashAlgorithm {
    Sha256,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioContentHashes {
    pub algorithm: LocalStudioContentHashAlgorithm,
    pub session: String,
    pub messages: Vec<LocalStudioHashReference>,
    pub tools: Vec<LocalStudioHashReference>,
    pub attachments: Vec<LocalStudioHashReference>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioTransferCursorKind {
    SessionTransferCursor,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioTransferCursor {
    #[serde(rename = "type")]
    pub cursor_type: LocalStudioTransferCursorKind,
    pub token: String,
    pub revision: u64,
    pub after_sequence: u64,
    pub has_more: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioSessionPage {
    pub protocol_version: u32,
    pub request_id: String,
    pub page_id: String,
    pub canonical_session: LocalStudioExternalSessionIdentity,
    pub origin: LocalStudioSessionOrigin,
    pub metadata: LocalStudioSessionMetadata,
    pub revision: u64,
    pub messages: Vec<LocalStudioMessageDescriptor>,
    pub tools: Vec<LocalStudioToolDescriptor>,
    pub attachments: Vec<LocalStudioAttachmentDescriptor>,
    pub content_hashes: LocalStudioContentHashes,
    pub cursor: Option<LocalStudioTransferCursor>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LocalStudioSessionReadResult {
    Page { page: LocalStudioSessionPage },
    Error { error: LocalStudioErrorResult },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioAgentTurnOutcome {
    Accepted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioAgentTurnAck {
    pub protocol_version: u32,
    pub request_id: String,
    pub idempotency_key: String,
    pub dispatch_id: String,
    pub canonical_session: LocalStudioExternalSessionIdentity,
    pub message_id: String,
    pub content_hash: String,
    pub base_revision: u64,
    pub pi_session_id: String,
    pub model_id: String,
    pub outcome: LocalStudioAgentTurnOutcome,
    pub accepted_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioConflictOperation {
    ControllerAction,
    SessionTransfer,
    AgentTurn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum LocalStudioConflictResolution {
    Retry,
    ForkRequired,
    Manual,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalStudioConflictResult {
    pub protocol_version: u32,
    pub request_id: String,
    pub operation: LocalStudioConflictOperation,
    pub expected_revision: u64,
    pub current_revision: u64,
    pub resolution: LocalStudioConflictResolution,
    #[serde(deserialize_with = "deserialize_required_option")]
    pub canonical_session: Option<LocalStudioExternalSessionIdentity>,
    #[serde(deserialize_with = "deserialize_required_option")]
    pub cursor: Option<LocalStudioTransferCursor>,
    pub error: LocalStudioBridgeError,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LocalStudioAgentTurnResult {
    Accepted { ack: LocalStudioAgentTurnAck },
    Conflict { conflict: LocalStudioConflictResult },
    Error { error: LocalStudioErrorResult },
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum LocalStudioClientError {
    #[error("no saved paired Alleycat target exists for server `{0}`")]
    TargetNotFound(String),
    #[error("multiple saved paired Alleycat targets use server id `{0}`")]
    AmbiguousTarget(String),
    #[error("local-studio agent advertisement is missing")]
    AgentNotAdvertised,
    #[error("local-studio agent advertisement is ambiguous")]
    AmbiguousAgentAdvertisement,
    #[error("local-studio agent is unavailable")]
    AgentUnavailable,
    #[error("local-studio agent must use the jsonl wire")]
    UnsupportedAgentWire,
    #[error("local-studio bridge protocol error: {0}")]
    Protocol(String),
    #[error("local-studio transport error: {0}")]
    Transport(String),
}

#[derive(Debug, Clone)]
enum TargetEntry {
    Unique(ParsedPairPayload),
    Ambiguous,
}

#[derive(Debug, Default)]
pub(crate) struct LocalStudioTargetRegistry {
    targets: RwLock<HashMap<String, TargetEntry>>,
}

impl LocalStudioTargetRegistry {
    pub(crate) fn register(&self, server_id: String, target: ParsedPairPayload) {
        match self.targets.write() {
            Ok(mut guard) => {
                guard.insert(server_id, TargetEntry::Unique(target));
            }
            Err(error) => {
                error
                    .into_inner()
                    .insert(server_id, TargetEntry::Unique(target));
            }
        }
    }

    pub(crate) fn sync(&self, servers: &[SavedServerRecord]) {
        let mut targets = HashMap::new();
        for server in servers {
            let (Some(node_id), Some(token)) = (
                server.alleycat_node_id.as_ref(),
                server.alleycat_token.as_ref(),
            ) else {
                continue;
            };
            if server.id.is_empty() || node_id.is_empty() || token.is_empty() {
                continue;
            }
            let target = ParsedPairPayload {
                version: crate::alleycat::ALLEYCAT_PROTOCOL_VERSION,
                node_id: node_id.clone(),
                token: token.clone(),
                relay: server.alleycat_relay.clone(),
                host_name: None,
            };
            match targets.entry(server.id.clone()) {
                std::collections::hash_map::Entry::Vacant(entry) => {
                    entry.insert(TargetEntry::Unique(target));
                }
                std::collections::hash_map::Entry::Occupied(mut entry) => {
                    entry.insert(TargetEntry::Ambiguous);
                }
            }
        }
        match self.targets.write() {
            Ok(mut guard) => *guard = targets,
            Err(error) => *error.into_inner() = targets,
        }
    }
    pub(crate) fn resolve(
        &self,
        server_id: &str,
    ) -> Result<ParsedPairPayload, LocalStudioClientError> {
        let guard = match self.targets.read() {
            Ok(guard) => guard,
            Err(error) => error.into_inner(),
        };
        match guard.get(server_id) {
            Some(TargetEntry::Unique(target)) => Ok(target.clone()),
            Some(TargetEntry::Ambiguous) => Err(LocalStudioClientError::AmbiguousTarget(
                server_id.to_string(),
            )),
            None => Err(LocalStudioClientError::TargetNotFound(
                server_id.to_string(),
            )),
        }
    }
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceAuth {
    device_id: String,
    key_id: String,
    algorithm: &'static str,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReadAuth {
    device: DeviceAuth,
    request_id: String,
    issued_at: String,
    expires_at: String,
    nonce: String,
    body_hash: String,
    signature: String,
    capability: LocalStudioCapability,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MutationAuth {
    device: DeviceAuth,
    request_id: String,
    issued_at: String,
    expires_at: String,
    nonce: String,
    body_hash: String,
    signature: String,
    capability: LocalStudioCapability,
    idempotency_key: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UnsignedControllerSnapshotRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    controller_id: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ControllerSnapshotRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    auth: ReadAuth,
    controller_id: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UnsignedSessionReadRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    session: Option<&'a LocalStudioExternalSessionIdentity>,
    cursor: Option<&'a LocalStudioTransferCursor>,
    limit: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionReadRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    auth: ReadAuth,
    session: Option<&'a LocalStudioExternalSessionIdentity>,
    cursor: Option<&'a LocalStudioTransferCursor>,
    limit: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UnsignedSessionListRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    cursor: Option<&'a LocalStudioSessionListCursor>,
    limit: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionListRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    auth: ReadAuth,
    cursor: Option<&'a LocalStudioSessionListCursor>,
    limit: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UnsignedAgentTurnRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    session: &'a LocalStudioExternalSessionIdentity,
    expected_revision: u64,
    message_id: &'a str,
    model_id: Option<&'a str>,
    content: &'a str,
    content_hash: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentTurnRequest<'a> {
    #[serde(rename = "type")]
    request_type: &'static str,
    protocol_version: u32,
    auth: MutationAuth,
    session: &'a LocalStudioExternalSessionIdentity,
    expected_revision: u64,
    message_id: &'a str,
    model_id: Option<&'a str>,
    content: &'a str,
    content_hash: String,
}

#[derive(Debug)]
enum CapabilitiesCallResult {
    Capabilities(LocalStudioCapabilitiesManifest),
    Error(LocalStudioErrorResult),
}

#[derive(Debug)]
enum ControllerReadCallResult {
    Snapshot(LocalStudioControllerSnapshot),
    Error(LocalStudioErrorResult),
}

#[derive(Debug)]
enum SessionReadCallResult {
    Page(LocalStudioSessionPage),
    Error(LocalStudioErrorResult),
}

#[derive(Debug)]
enum SessionListCallResult {
    Page(LocalStudioSessionListPage),
    Error(LocalStudioErrorResult),
}

#[derive(Debug)]
enum AgentTurnCallResult {
    Ack(LocalStudioAgentTurnAck),
    Conflict(LocalStudioConflictResult),
    Error(LocalStudioErrorResult),
}

#[derive(Debug)]
enum LocalStudioOperation<'a> {
    Capabilities,
    ControllerRead(&'a ControllerSnapshotRequest<'a>),
    SessionList(&'a SessionListRequest<'a>),
    SessionRead(&'a SessionReadRequest<'a>),
    AgentTurn(&'a AgentTurnRequest<'a>),
}

impl LocalStudioOperation<'_> {
    fn method(&self) -> &'static str {
        match self {
            Self::Capabilities => "localStudio/capabilities",
            Self::ControllerRead(_) => "localStudio/controller/read",
            Self::SessionList(_) => "localStudio/session/list",
            Self::SessionRead(_) => "localStudio/session/read",
            Self::AgentTurn(_) => "localStudio/agent/turn",
        }
    }

    fn params(&self) -> Result<Value, LocalStudioClientError> {
        match self {
            Self::Capabilities => Ok(json!({
                "protocolVersion": LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
            })),
            Self::ControllerRead(request) => serde_json::to_value(request).map_err(|error| {
                LocalStudioClientError::Protocol(format!(
                    "encoding controller snapshot request: {error}"
                ))
            }),
            Self::SessionList(request) => serde_json::to_value(request).map_err(|error| {
                LocalStudioClientError::Protocol(format!("encoding session list request: {error}"))
            }),
            Self::SessionRead(request) => serde_json::to_value(request).map_err(|error| {
                LocalStudioClientError::Protocol(format!("encoding session read request: {error}"))
            }),
            Self::AgentTurn(request) => serde_json::to_value(request).map_err(|error| {
                LocalStudioClientError::Protocol(format!("encoding agent turn request: {error}"))
            }),
        }
    }
}

struct LocalStudioJsonlSession {
    reader: BufReader<tokio::io::ReadHalf<AlleycatStream>>,
    writer: tokio::io::WriteHalf<AlleycatStream>,
    keepalive: std::sync::Arc<AlleycatSession>,
}

impl LocalStudioJsonlSession {
    async fn connect(
        endpoint: &Endpoint,
        params: ParsedPairPayload,
    ) -> Result<Self, LocalStudioClientError> {
        let (stream, keepalive) = crate::alleycat::connect_jsonl_agent_stream(
            endpoint,
            params,
            LOCAL_STUDIO_AGENT_NAME.to_string(),
        )
        .await
        .map_err(|error| LocalStudioClientError::Transport(error.to_string()))?;
        let (reader, writer) = tokio::io::split(stream);
        Ok(Self {
            reader: BufReader::new(reader),
            writer,
            keepalive,
        })
    }

    async fn request(
        &mut self,
        operation: LocalStudioOperation<'_>,
    ) -> Result<Value, LocalStudioClientError> {
        let request_id = Uuid::new_v4().to_string();
        let frame = json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": operation.method(),
            "params": operation.params()?,
        });
        let mut bytes = serde_json::to_vec(&frame).map_err(|error| {
            LocalStudioClientError::Protocol(format!("encoding JSON-RPC request: {error}"))
        })?;
        if bytes.len() + 1 > crate::alleycat::MAX_FRAME_BYTES {
            return Err(LocalStudioClientError::Protocol(format!(
                "JSON-RPC request exceeds {} bytes",
                crate::alleycat::MAX_FRAME_BYTES
            )));
        }
        bytes.push(b'\n');
        tokio::time::timeout(LOCAL_STUDIO_RPC_TIMEOUT, async {
            self.writer.write_all(&bytes).await?;
            self.writer.flush().await
        })
        .await
        .map_err(|_| {
            LocalStudioClientError::Transport("writing JSON-RPC request timed out".into())
        })?
        .map_err(|error| {
            LocalStudioClientError::Transport(format!("writing JSON-RPC request: {error}"))
        })?;

        let mut response = Vec::new();
        let read = async {
            let mut limited =
                (&mut self.reader).take((crate::alleycat::MAX_FRAME_BYTES + 1) as u64);
            limited.read_until(b'\n', &mut response).await
        };
        let read_bytes = tokio::time::timeout(LOCAL_STUDIO_RPC_TIMEOUT, read)
            .await
            .map_err(|_| {
                LocalStudioClientError::Transport("reading JSON-RPC response timed out".into())
            })?
            .map_err(|error| {
                LocalStudioClientError::Transport(format!("reading JSON-RPC response: {error}"))
            })?;
        if read_bytes == 0 {
            return Err(LocalStudioClientError::Transport(
                "local-studio JSON-RPC stream closed".into(),
            ));
        }
        if response.len() > crate::alleycat::MAX_FRAME_BYTES || !response.ends_with(b"\n") {
            return Err(LocalStudioClientError::Protocol(format!(
                "JSON-RPC response exceeds {} bytes or is not newline terminated",
                crate::alleycat::MAX_FRAME_BYTES
            )));
        }
        response.pop();
        let envelope: JsonRpcResponse = serde_json::from_slice(&response).map_err(|error| {
            LocalStudioClientError::Protocol(format!("decoding JSON-RPC response: {error}"))
        })?;
        envelope.into_result(&request_id)
    }

    fn close(&self) {
        self.keepalive.close();
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct JsonRpcResponse {
    jsonrpc: String,
    id: String,
    #[serde(rename = "_alleycat_seq")]
    alleycat_seq: u64,
    #[serde(default)]
    result: Option<Value>,
    #[serde(default)]
    error: Option<JsonRpcError>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct JsonRpcError {
    code: i64,
    message: String,
}

impl JsonRpcResponse {
    fn into_result(self, expected_id: &str) -> Result<Value, LocalStudioClientError> {
        if self.jsonrpc != "2.0" {
            return Err(LocalStudioClientError::Protocol(
                "JSON-RPC version must be 2.0".into(),
            ));
        }
        if self.id != expected_id {
            return Err(LocalStudioClientError::Protocol(
                "JSON-RPC response id does not match request".into(),
            ));
        }
        if self.alleycat_seq == 0 {
            return Err(LocalStudioClientError::Protocol(
                "AlleyCat response sequence must be positive".into(),
            ));
        }
        match (self.result, self.error) {
            (Some(result), None) => Ok(result),
            (None, Some(error)) => Err(LocalStudioClientError::Protocol(format!(
                "JSON-RPC error {}: {}",
                error.code, error.message
            ))),
            _ => Err(LocalStudioClientError::Protocol(
                "JSON-RPC response must contain exactly one of result or error".into(),
            )),
        }
    }
}

pub(crate) async fn load_local_studio_controller(
    endpoint: &Endpoint,
    params: ParsedPairPayload,
) -> Result<LocalStudioControllerLoadResult, LocalStudioClientError> {
    let advertised = crate::alleycat::list_agents(endpoint, params.clone())
        .await
        .map_err(|error| LocalStudioClientError::Transport(error.to_string()))?;
    let advertisement = validate_local_studio_advertisement(&advertised)?;

    let mut session = LocalStudioJsonlSession::connect(endpoint, params).await?;
    let result = async {
        let manifest = match local_studio_capabilities(&mut session).await? {
            CapabilitiesCallResult::Capabilities(manifest) => manifest,
            CapabilitiesCallResult::Error(error) => {
                return Ok(LocalStudioControllerLoadResult::Error { error });
            }
        };
        if !manifest
            .capabilities
            .contains(&LocalStudioCapability::StatsRead)
        {
            return Err(LocalStudioClientError::Protocol(
                "local-studio manifest does not grant stats.read".into(),
            ));
        }
        validate_manifest_matches_advertisement(&manifest, &advertisement)?;
        let request = signed_controller_snapshot_request(
            endpoint.secret_key(),
            &manifest.controller_id,
            Utc::now(),
            Uuid::new_v4().to_string(),
            Uuid::new_v4().to_string(),
        )?;
        let snapshot = match local_studio_controller_read(&mut session, &request).await? {
            ControllerReadCallResult::Snapshot(snapshot) => snapshot,
            ControllerReadCallResult::Error(error) => {
                if error.request_id != request.auth.request_id {
                    return Err(LocalStudioClientError::Protocol(
                        "controller error request identity does not match signed request".into(),
                    ));
                }
                return Ok(LocalStudioControllerLoadResult::Error { error });
            }
        };
        if snapshot.controller_id != manifest.controller_id {
            return Err(LocalStudioClientError::Protocol(
                "controller snapshot identity does not match capabilities manifest".into(),
            ));
        }
        if snapshot
            .capabilities
            .iter()
            .any(|capability| !manifest.capabilities.contains(capability))
        {
            return Err(LocalStudioClientError::Protocol(
                "controller snapshot claims capabilities absent from manifest".into(),
            ));
        }
        Ok(LocalStudioControllerLoadResult::Loaded { manifest, snapshot })
    }
    .await;
    session.close();
    result
}

pub(crate) async fn list_local_studio_sessions(
    endpoint: &Endpoint,
    params: ParsedPairPayload,
    limit: u64,
) -> Result<LocalStudioSessionListResult, LocalStudioClientError> {
    list_local_studio_sessions_target(endpoint, params, None, limit).await
}

pub(crate) async fn continue_local_studio_session_list(
    endpoint: &Endpoint,
    params: ParsedPairPayload,
    cursor: &LocalStudioSessionListCursor,
    limit: u64,
) -> Result<LocalStudioSessionListResult, LocalStudioClientError> {
    validate_session_list_cursor(cursor, "cursor")?;
    if !cursor.has_more {
        return Err(LocalStudioClientError::Protocol(
            "session list cursor does not advertise another page".into(),
        ));
    }
    list_local_studio_sessions_target(endpoint, params, Some(cursor), limit).await
}

async fn list_local_studio_sessions_target(
    endpoint: &Endpoint,
    params: ParsedPairPayload,
    cursor: Option<&LocalStudioSessionListCursor>,
    limit: u64,
) -> Result<LocalStudioSessionListResult, LocalStudioClientError> {
    validate_session_list_request(cursor, limit)?;
    let advertised = crate::alleycat::list_agents(endpoint, params.clone())
        .await
        .map_err(|error| LocalStudioClientError::Transport(error.to_string()))?;
    let advertisement = validate_local_studio_advertisement(&advertised)?;

    let mut session = LocalStudioJsonlSession::connect(endpoint, params).await?;
    let result = async {
        let manifest = match local_studio_capabilities(&mut session).await? {
            CapabilitiesCallResult::Capabilities(manifest) => manifest,
            CapabilitiesCallResult::Error(error) => {
                return Ok(LocalStudioSessionListResult::Error { error });
            }
        };
        validate_manifest_matches_advertisement(&manifest, &advertisement)?;

        // Do not short-circuit an absent sessions.read grant here. The bridge intentionally
        // returns a signed-request-bound, typed capability_denied response for this operation.

        let request = signed_session_list_request(
            endpoint.secret_key(),
            cursor,
            limit,
            Utc::now(),
            Uuid::new_v4().to_string(),
            Uuid::new_v4().to_string(),
        )?;
        let response = local_studio_session_list(&mut session, &request).await?;
        match response {
            SessionListCallResult::Page(page) => {
                validate_session_list_page_context(
                    &page,
                    &manifest,
                    &request.auth.request_id,
                    cursor,
                    limit,
                )?;
                Ok(LocalStudioSessionListResult::Page { page })
            }
            SessionListCallResult::Error(error) => {
                validate_error_request_identity(&error, &request.auth.request_id)?;
                Ok(LocalStudioSessionListResult::Error { error })
            }
        }
    }
    .await;
    session.close();
    result
}

async fn local_studio_capabilities(
    session: &mut LocalStudioJsonlSession,
) -> Result<CapabilitiesCallResult, LocalStudioClientError> {
    let value = session.request(LocalStudioOperation::Capabilities).await?;
    decode_capabilities_result(value)
}

async fn local_studio_controller_read(
    session: &mut LocalStudioJsonlSession,
    request: &ControllerSnapshotRequest<'_>,
) -> Result<ControllerReadCallResult, LocalStudioClientError> {
    let value = session
        .request(LocalStudioOperation::ControllerRead(request))
        .await?;
    decode_controller_read_result(value)
}

async fn local_studio_session_list(
    session: &mut LocalStudioJsonlSession,
    request: &SessionListRequest<'_>,
) -> Result<SessionListCallResult, LocalStudioClientError> {
    let value = session
        .request(LocalStudioOperation::SessionList(request))
        .await?;
    decode_session_list_result(value)
}

async fn local_studio_session_read(
    session: &mut LocalStudioJsonlSession,
    request: &SessionReadRequest<'_>,
) -> Result<SessionReadCallResult, LocalStudioClientError> {
    let value = session
        .request(LocalStudioOperation::SessionRead(request))
        .await?;
    decode_session_read_result(value)
}

async fn local_studio_agent_turn(
    session: &mut LocalStudioJsonlSession,
    request: &AgentTurnRequest<'_>,
) -> Result<AgentTurnCallResult, LocalStudioClientError> {
    let value = session
        .request(LocalStudioOperation::AgentTurn(request))
        .await?;
    decode_agent_turn_result(value)
}

fn validate_local_studio_advertisement(
    agents: &[AgentInfo],
) -> Result<LocalStudioAdvertisement, LocalStudioClientError> {
    let matches = agents
        .iter()
        .filter(|agent| agent.name == LOCAL_STUDIO_AGENT_NAME)
        .collect::<Vec<_>>();
    let agent = match matches.as_slice() {
        [] => return Err(LocalStudioClientError::AgentNotAdvertised),
        [agent] => *agent,
        _ => return Err(LocalStudioClientError::AmbiguousAgentAdvertisement),
    };
    if !agent.available {
        return Err(LocalStudioClientError::AgentUnavailable);
    }
    if agent.wire != AgentWire::Jsonl {
        return Err(LocalStudioClientError::UnsupportedAgentWire);
    }
    let advertisement = agent.local_studio.clone().ok_or_else(|| {
        LocalStudioClientError::Protocol(
            "local-studio agent is missing its per-client advertisement".into(),
        )
    })?;
    validate_protocol_version(advertisement.protocol_version)?;
    validate_identifier(&advertisement.bridge_id, "advertisement.bridgeId")?;
    validate_identifier(&advertisement.controller_id, "advertisement.controllerId")?;
    validate_timestamp(&advertisement.issued_at, "advertisement.issuedAt")?;
    validate_unique_capabilities(&advertisement.capabilities)?;
    let mut actions = HashSet::new();
    if !advertisement
        .actions
        .iter()
        .copied()
        .all(|action| actions.insert(action))
    {
        return Err(LocalStudioClientError::Protocol(
            "advertised controller actions must be unique".into(),
        ));
    }
    Ok(advertisement)
}
fn capability_set(capabilities: &[LocalStudioCapability]) -> HashSet<LocalStudioCapability> {
    capabilities.iter().copied().collect()
}
fn validate_manifest_matches_advertisement(
    manifest: &LocalStudioCapabilitiesManifest,
    advertisement: &LocalStudioAdvertisement,
) -> Result<(), LocalStudioClientError> {
    if manifest.bridge_id == advertisement.bridge_id
        && manifest.controller_id == advertisement.controller_id
        && capability_set(&manifest.capabilities) == capability_set(&advertisement.capabilities)
    {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(
            "local-studio manifest does not match its authenticated advertisement".into(),
        ))
    }
}
fn decode_capabilities_result(
    value: Value,
) -> Result<CapabilitiesCallResult, LocalStudioClientError> {
    match result_type(&value)? {
        "capabilities" => {
            let manifest: LocalStudioCapabilitiesManifest = decode_typed_value(value)?;
            validate_manifest(&manifest)?;
            Ok(CapabilitiesCallResult::Capabilities(manifest))
        }
        "error" => {
            let error: LocalStudioErrorResult = decode_typed_value(value)?;
            validate_error_result(&error)?;
            Ok(CapabilitiesCallResult::Error(error))
        }
        kind => Err(LocalStudioClientError::Protocol(format!(
            "unexpected capabilities result type `{kind}`"
        ))),
    }
}
fn decode_controller_read_result(
    value: Value,
) -> Result<ControllerReadCallResult, LocalStudioClientError> {
    match result_type(&value)? {
        "controller_snapshot" => {
            let snapshot: LocalStudioControllerSnapshot = decode_typed_value(value)?;
            validate_snapshot(&snapshot)?;
            Ok(ControllerReadCallResult::Snapshot(snapshot))
        }
        "error" => {
            let error: LocalStudioErrorResult = decode_typed_value(value)?;
            validate_error_result(&error)?;
            Ok(ControllerReadCallResult::Error(error))
        }
        kind => Err(LocalStudioClientError::Protocol(format!(
            "unexpected controller read result type `{kind}`"
        ))),
    }
}
fn decode_session_list_result(
    value: Value,
) -> Result<SessionListCallResult, LocalStudioClientError> {
    match result_type(&value)? {
        "session_list_page" => {
            let page: LocalStudioSessionListPage = decode_typed_value(value)?;
            validate_session_list_page(&page)?;
            Ok(SessionListCallResult::Page(page))
        }
        "error" => {
            let error: LocalStudioErrorResult = decode_typed_value(value)?;
            validate_error_result(&error)?;
            Ok(SessionListCallResult::Error(error))
        }
        kind => Err(LocalStudioClientError::Protocol(format!(
            "unexpected session list result type `{kind}`"
        ))),
    }
}
fn decode_session_read_result(
    value: Value,
) -> Result<SessionReadCallResult, LocalStudioClientError> {
    match result_type(&value)? {
        "session_page" => {
            let page: LocalStudioSessionPage = decode_typed_value(value)?;
            validate_session_page(&page)?;
            Ok(SessionReadCallResult::Page(page))
        }
        "error" => {
            let error: LocalStudioErrorResult = decode_typed_value(value)?;
            validate_error_result(&error)?;
            Ok(SessionReadCallResult::Error(error))
        }
        kind => Err(LocalStudioClientError::Protocol(format!(
            "unexpected session read result type `{kind}`"
        ))),
    }
}
fn decode_agent_turn_result(value: Value) -> Result<AgentTurnCallResult, LocalStudioClientError> {
    match result_type(&value)? {
        "agent_turn_ack" => {
            let ack: LocalStudioAgentTurnAck = decode_typed_value(value)?;
            validate_agent_turn_ack(&ack)?;
            Ok(AgentTurnCallResult::Ack(ack))
        }
        "conflict" => {
            let conflict: LocalStudioConflictResult = decode_typed_value(value)?;
            validate_conflict_result(&conflict)?;
            Ok(AgentTurnCallResult::Conflict(conflict))
        }
        "error" => {
            let error: LocalStudioErrorResult = decode_typed_value(value)?;
            validate_error_result(&error)?;
            Ok(AgentTurnCallResult::Error(error))
        }
        kind => Err(LocalStudioClientError::Protocol(format!(
            "unexpected agent turn result type `{kind}`"
        ))),
    }
}
fn result_type(value: &Value) -> Result<&str, LocalStudioClientError> {
    value
        .as_object()
        .and_then(|object| object.get("type"))
        .and_then(Value::as_str)
        .ok_or_else(|| LocalStudioClientError::Protocol("result is missing string type".into()))
}
fn decode_typed_value<T>(mut value: Value) -> Result<T, LocalStudioClientError>
where
    T: for<'de> Deserialize<'de>,
{
    value
        .as_object_mut()
        .ok_or_else(|| LocalStudioClientError::Protocol("result must be an object".into()))?
        .remove("type");
    serde_json::from_value(value)
        .map_err(|error| LocalStudioClientError::Protocol(format!("invalid result: {error}")))
}
fn signed_controller_snapshot_request<'a>(
    secret_key: &SecretKey,
    controller_id: &'a str,
    issued_at: DateTime<Utc>,
    request_id: String,
    nonce: String,
) -> Result<ControllerSnapshotRequest<'a>, LocalStudioClientError> {
    validate_identifier(controller_id, "controllerId")?;
    let unsigned = UnsignedControllerSnapshotRequest {
        request_type: "controller_snapshot_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        controller_id,
    };
    let body_hash = canonical_body_hash(&unsigned)?;
    let auth = signed_read_auth(
        secret_key,
        LocalStudioCapability::StatsRead,
        body_hash,
        issued_at,
        request_id,
        nonce,
    )?;
    Ok(ControllerSnapshotRequest {
        request_type: "controller_snapshot_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        auth,
        controller_id,
    })
}
fn signed_session_list_request<'a>(
    secret_key: &SecretKey,
    cursor: Option<&'a LocalStudioSessionListCursor>,
    limit: u64,
    issued_at: DateTime<Utc>,
    request_id: String,
    nonce: String,
) -> Result<SessionListRequest<'a>, LocalStudioClientError> {
    validate_session_list_request(cursor, limit)?;
    let unsigned = UnsignedSessionListRequest {
        request_type: "session_list_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        cursor,
        limit,
    };
    let body_hash = canonical_body_hash(&unsigned)?;
    let auth = signed_read_auth(
        secret_key,
        LocalStudioCapability::SessionsRead,
        body_hash,
        issued_at,
        request_id,
        nonce,
    )?;
    Ok(SessionListRequest {
        request_type: "session_list_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        auth,
        cursor,
        limit,
    })
}
fn signed_session_read_request<'a>(
    secret_key: &SecretKey,
    session: Option<&'a LocalStudioExternalSessionIdentity>,
    cursor: Option<&'a LocalStudioTransferCursor>,
    limit: u64,
    issued_at: DateTime<Utc>,
    request_id: String,
    nonce: String,
) -> Result<SessionReadRequest<'a>, LocalStudioClientError> {
    validate_session_read_target(session, cursor, limit)?;
    let unsigned = UnsignedSessionReadRequest {
        request_type: "session_read_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        session,
        cursor,
        limit,
    };
    let body_hash = canonical_body_hash(&unsigned)?;
    let auth = signed_read_auth(
        secret_key,
        LocalStudioCapability::SessionsRead,
        body_hash,
        issued_at,
        request_id,
        nonce,
    )?;
    Ok(SessionReadRequest {
        request_type: "session_read_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        auth,
        session,
        cursor,
        limit,
    })
}
#[allow(clippy::too_many_arguments)]
fn signed_agent_turn_request<'a>(
    secret_key: &SecretKey,
    session: &'a LocalStudioExternalSessionIdentity,
    expected_revision: u64,
    message_id: &'a str,
    idempotency_key: &'a str,
    content: &'a str,
    model_id: Option<&'a str>,
    issued_at: DateTime<Utc>,
    request_id: String,
    nonce: String,
) -> Result<AgentTurnRequest<'a>, LocalStudioClientError> {
    validate_agent_turn_input(
        &session.session_id,
        expected_revision,
        message_id,
        idempotency_key,
        content,
        model_id,
    )?;
    validate_external_session_identity(session, "session")?;
    if session.authority != LocalStudioSessionAuthority::LocalStudio {
        return Err(LocalStudioClientError::Protocol(
            "agent turn session authority must be local-studio".into(),
        ));
    }
    let content_hash = hex::encode(Sha256::digest(content.as_bytes()));
    let unsigned = UnsignedAgentTurnRequest {
        request_type: "agent_turn_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        session,
        expected_revision,
        message_id,
        model_id,
        content,
        content_hash: &content_hash,
    };
    let body_hash = canonical_body_hash(&unsigned)?;
    let auth = signed_mutation_auth(
        secret_key,
        LocalStudioCapability::AgentTurn,
        body_hash,
        idempotency_key.to_string(),
        issued_at,
        request_id,
        nonce,
    )?;
    Ok(AgentTurnRequest {
        request_type: "agent_turn_request",
        protocol_version: LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION,
        auth,
        session,
        expected_revision,
        message_id,
        model_id,
        content,
        content_hash,
    })
}
fn signed_read_auth(
    secret_key: &SecretKey,
    capability: LocalStudioCapability,
    body_hash: String,
    issued_at: DateTime<Utc>,
    request_id: String,
    nonce: String,
) -> Result<ReadAuth, LocalStudioClientError> {
    validate_identifier(&request_id, "requestId")?;
    validate_nonce(&nonce)?;
    let issued_at_text = issued_at.to_rfc3339_opts(SecondsFormat::Millis, true);
    let expires_at_text =
        (issued_at + chrono::Duration::seconds(30)).to_rfc3339_opts(SecondsFormat::Millis, true);
    let device_id = secret_key.public().to_string();
    let preimage = signature_preimage(&SignatureFields {
        device_id: &device_id,
        key_id: &device_id,
        request_id: &request_id,
        issued_at: &issued_at_text,
        expires_at: &expires_at_text,
        nonce: &nonce,
        capability,
        idempotency_key: None,
        body_hash: &body_hash,
    })?;
    let signature = URL_SAFE_NO_PAD.encode(secret_key.sign(&preimage).to_bytes());
    Ok(ReadAuth {
        device: DeviceAuth {
            device_id: device_id.clone(),
            key_id: device_id,
            algorithm: "ed25519",
        },
        request_id,
        issued_at: issued_at_text,
        expires_at: expires_at_text,
        nonce,
        body_hash,
        signature,
        capability,
    })
}
fn signed_mutation_auth(
    secret_key: &SecretKey,
    capability: LocalStudioCapability,
    body_hash: String,
    idempotency_key: String,
    issued_at: DateTime<Utc>,
    request_id: String,
    nonce: String,
) -> Result<MutationAuth, LocalStudioClientError> {
    validate_identifier(&request_id, "requestId")?;
    validate_identifier(&idempotency_key, "idempotencyKey")?;
    validate_nonce(&nonce)?;
    let issued_at_text = issued_at.to_rfc3339_opts(SecondsFormat::Millis, true);
    let expires_at_text =
        (issued_at + chrono::Duration::seconds(30)).to_rfc3339_opts(SecondsFormat::Millis, true);
    let device_id = secret_key.public().to_string();
    let preimage = signature_preimage(&SignatureFields {
        device_id: &device_id,
        key_id: &device_id,
        request_id: &request_id,
        issued_at: &issued_at_text,
        expires_at: &expires_at_text,
        nonce: &nonce,
        capability,
        idempotency_key: Some(&idempotency_key),
        body_hash: &body_hash,
    })?;
    let signature = URL_SAFE_NO_PAD.encode(secret_key.sign(&preimage).to_bytes());
    Ok(MutationAuth {
        device: DeviceAuth {
            device_id: device_id.clone(),
            key_id: device_id,
            algorithm: "ed25519",
        },
        request_id,
        issued_at: issued_at_text,
        expires_at: expires_at_text,
        nonce,
        body_hash,
        signature,
        capability,
        idempotency_key,
    })
}
struct SignatureFields<'a> {
    device_id: &'a str,
    key_id: &'a str,
    request_id: &'a str,
    issued_at: &'a str,
    expires_at: &'a str,
    nonce: &'a str,
    capability: LocalStudioCapability,
    idempotency_key: Option<&'a str>,
    body_hash: &'a str,
}
fn signature_preimage(fields: &SignatureFields<'_>) -> Result<Vec<u8>, LocalStudioClientError> {
    let mut preimage = Vec::with_capacity(LOCAL_STUDIO_REQUEST_DOMAIN.len() + 512);
    preimage.extend_from_slice(LOCAL_STUDIO_REQUEST_DOMAIN);
    for field in [
        fields.device_id,
        fields.key_id,
        fields.request_id,
        fields.issued_at,
        fields.expires_at,
        fields.nonce,
        fields.capability.as_str(),
        fields.idempotency_key.unwrap_or(""),
        fields.body_hash,
    ] {
        let len = u32::try_from(field.len()).map_err(|_| {
            LocalStudioClientError::Protocol("signature field exceeds u32 length".into())
        })?;
        preimage.extend_from_slice(&len.to_be_bytes());
        preimage.extend_from_slice(field.as_bytes());
    }
    Ok(preimage)
}
fn canonical_body_hash<T>(value: &T) -> Result<String, LocalStudioClientError>
where
    T: Serialize,
{
    let value = serde_json::to_value(value).map_err(|error| {
        LocalStudioClientError::Protocol(format!("encoding canonical JSON value: {error}"))
    })?;
    let bytes = canonical_json_bytes(value)?;
    Ok(hex::encode(Sha256::digest(bytes)))
}
fn canonical_json_bytes(value: Value) -> Result<Vec<u8>, LocalStudioClientError> {
    serde_json::to_vec(&canonicalize_json(value)?).map_err(|error| {
        LocalStudioClientError::Protocol(format!("encoding canonical JSON: {error}"))
    })
}
fn canonicalize_json(value: Value) -> Result<Value, LocalStudioClientError> {
    match value {
        Value::Array(values) => values
            .into_iter()
            .map(canonicalize_json)
            .collect::<Result<Vec<_>, _>>()
            .map(Value::Array),
        Value::Object(values) => {
            let mut entries = values.into_iter().collect::<Vec<_>>();
            entries.sort_by(|(left, _), (right, _)| left.cmp(right));
            let mut ordered = Map::new();
            for (key, value) in entries {
                ordered.insert(key, canonicalize_json(value)?);
            }
            Ok(Value::Object(ordered))
        }
        Value::Number(number) => {
            const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
            let safe = number
                .as_i64()
                .map(|value| {
                    (-(MAX_SAFE_INTEGER as i64)..=MAX_SAFE_INTEGER as i64).contains(&value)
                })
                .or_else(|| number.as_u64().map(|value| value <= MAX_SAFE_INTEGER))
                .unwrap_or(false);
            if safe {
                Ok(Value::Number(number))
            } else {
                Err(LocalStudioClientError::Protocol(
                    "canonical JSON accepts only safe decimal integers".into(),
                ))
            }
        }
        scalar @ (Value::Null | Value::Bool(_) | Value::String(_)) => Ok(scalar),
    }
}

fn validate_manifest(
    manifest: &LocalStudioCapabilitiesManifest,
) -> Result<(), LocalStudioClientError> {
    validate_protocol_version(manifest.protocol_version)?;
    validate_identifier(&manifest.bridge_id, "bridgeId")?;
    validate_identifier(&manifest.controller_id, "controllerId")?;
    validate_timestamp(&manifest.issued_at, "issuedAt")?;
    validate_unique_capabilities(&manifest.capabilities)
}

fn validate_snapshot(
    snapshot: &LocalStudioControllerSnapshot,
) -> Result<(), LocalStudioClientError> {
    validate_protocol_version(snapshot.protocol_version)?;
    validate_identifier(&snapshot.snapshot_id, "snapshotId")?;
    validate_identifier(&snapshot.controller_id, "controllerId")?;
    validate_identifier(&snapshot.display_name, "displayName")?;
    validate_timestamp(&snapshot.generated_at, "generatedAt")?;
    validate_unique_capabilities(&snapshot.capabilities)?;
    validate_health_section(&snapshot.sections.health)?;
    validate_status_section(&snapshot.sections.status)?;
    validate_gpus_section(&snapshot.sections.gpus)?;
    validate_metrics_section(&snapshot.sections.metrics)?;
    validate_agent_runtime_section(&snapshot.sections.agent_runtime)
}

fn validate_session_list_request(
    cursor: Option<&LocalStudioSessionListCursor>,
    limit: u64,
) -> Result<(), LocalStudioClientError> {
    validate_session_limit(limit)?;
    if let Some(cursor) = cursor {
        validate_session_list_cursor(cursor, "cursor")?;
        if !cursor.has_more {
            return Err(LocalStudioClientError::Protocol(
                "session list cursor does not advertise another page".into(),
            ));
        }
    }
    Ok(())
}

fn validate_session_list_cursor(
    cursor: &LocalStudioSessionListCursor,
    field: &str,
) -> Result<(), LocalStudioClientError> {
    validate_safe_u64(cursor.revision, &format!("{field}.revision"))?;
    let length = cursor.token.chars().count();
    if cursor.token.is_empty()
        || cursor.token.trim() != cursor.token
        || length > LOCAL_STUDIO_CURSOR_MAX_CHARS
    {
        Err(LocalStudioClientError::Protocol(format!(
            "{field}.token must be a non-empty trimmed opaque token of at most {LOCAL_STUDIO_CURSOR_MAX_CHARS} characters"
        )))
    } else {
        Ok(())
    }
}

fn validate_session_descriptor(
    descriptor: &LocalStudioSessionDescriptor,
    controller_id: &str,
) -> Result<(), LocalStudioClientError> {
    validate_external_session_identity(&descriptor.session, "sessions.session")?;
    if descriptor.session.kind != LocalStudioSessionIdentityKind::ExternalSession
        || descriptor.session.authority != LocalStudioSessionAuthority::LocalStudio
        || descriptor.session.installation_id != controller_id
    {
        return Err(LocalStudioClientError::Protocol(
            "session descriptor identity does not belong to the response controller".into(),
        ));
    }
    validate_session_metadata(&descriptor.metadata)?;
    validate_safe_u64(descriptor.revision, "sessions.revision")
}

fn validate_session_list_page(
    page: &LocalStudioSessionListPage,
) -> Result<(), LocalStudioClientError> {
    validate_protocol_version(page.protocol_version)?;
    validate_identifier(&page.request_id, "requestId")?;
    validate_identifier(&page.controller_id, "controllerId")?;
    validate_safe_u64(page.revision, "revision")?;
    if page.sessions.len() > LOCAL_STUDIO_SESSION_MAX_PAGE_ITEMS {
        return Err(LocalStudioClientError::Protocol(format!(
            "session list page must not exceed {LOCAL_STUDIO_SESSION_MAX_PAGE_ITEMS} sessions"
        )));
    }

    let mut session_ids = HashSet::new();
    for descriptor in &page.sessions {
        validate_session_descriptor(descriptor, &page.controller_id)?;
        if !session_ids.insert(descriptor.session.session_id.as_str()) {
            return Err(LocalStudioClientError::Protocol(
                "session list page contains duplicate canonical session identities".into(),
            ));
        }
    }

    if let Some(cursor) = &page.cursor {
        validate_session_list_cursor(cursor, "cursor")?;
        if !cursor.has_more {
            return Err(LocalStudioClientError::Protocol(
                "a present session list cursor must advertise another page".into(),
            ));
        }
        if cursor.revision != page.revision {
            return Err(LocalStudioClientError::Protocol(
                "session list cursor revision does not match page revision".into(),
            ));
        }
    }
    Ok(())
}

fn validate_session_list_page_context(
    page: &LocalStudioSessionListPage,
    manifest: &LocalStudioCapabilitiesManifest,
    request_id: &str,
    requested_cursor: Option<&LocalStudioSessionListCursor>,
    limit: u64,
) -> Result<(), LocalStudioClientError> {
    if page.request_id != request_id {
        return Err(LocalStudioClientError::Protocol(
            "session list page request identity does not match signed request".into(),
        ));
    }
    if page.controller_id != manifest.controller_id {
        return Err(LocalStudioClientError::Protocol(
            "session list page controller identity does not match capabilities manifest".into(),
        ));
    }
    if page.sessions.len() > limit as usize {
        return Err(LocalStudioClientError::Protocol(
            "session list page contains more sessions than the requested limit".into(),
        ));
    }
    if let Some(requested_cursor) = requested_cursor {
        if page.revision != requested_cursor.revision {
            return Err(LocalStudioClientError::Protocol(
                "continued session list page revision does not match its opaque cursor".into(),
            ));
        }
        if page
            .cursor
            .as_ref()
            .is_some_and(|cursor| cursor.token == requested_cursor.token)
        {
            return Err(LocalStudioClientError::Protocol(
                "continued session list cursor did not advance".into(),
            ));
        }
    }
    Ok(())
}

fn validate_session_read_target(
    session: Option<&LocalStudioExternalSessionIdentity>,
    cursor: Option<&LocalStudioTransferCursor>,
    limit: u64,
) -> Result<(), LocalStudioClientError> {
    validate_session_limit(limit)?;
    match (session, cursor) {
        (Some(session), None) => validate_external_session_identity(session, "session"),
        (None, Some(cursor)) => validate_transfer_cursor(cursor, "cursor"),
        _ => Err(LocalStudioClientError::Protocol(
            "session read requires exactly one of session or cursor".into(),
        )),
    }
}

fn validate_session_limit(limit: u64) -> Result<(), LocalStudioClientError> {
    if (1..=LOCAL_STUDIO_SESSION_MAX_PAGE_ITEMS as u64).contains(&limit) {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "session read limit must be between 1 and {LOCAL_STUDIO_SESSION_MAX_PAGE_ITEMS}"
        )))
    }
}

fn validate_external_session_identity(
    identity: &LocalStudioExternalSessionIdentity,
    field: &str,
) -> Result<(), LocalStudioClientError> {
    validate_identifier(
        &identity.installation_id,
        &format!("{field}.installationId"),
    )?;
    validate_pi_session_id(&identity.session_id, &format!("{field}.sessionId"))
}

fn validate_pi_session_id(value: &str, field: &str) -> Result<(), LocalStudioClientError> {
    static PI_SESSION_ID: OnceLock<Regex> = OnceLock::new();
    let pattern = PI_SESSION_ID.get_or_init(|| {
        Regex::new(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$")
            .expect("valid Pi session id regex")
    });
    validate_identifier(value, field)?;
    if pattern.is_match(value) {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} is not an exact Pi session header identifier"
        )))
    }
}

fn validate_transfer_cursor(
    cursor: &LocalStudioTransferCursor,
    field: &str,
) -> Result<(), LocalStudioClientError> {
    validate_safe_u64(cursor.revision, &format!("{field}.revision"))?;
    validate_safe_u64(cursor.after_sequence, &format!("{field}.afterSequence"))?;
    let length = cursor.token.chars().count();
    if cursor.token.is_empty()
        || cursor.token.trim() != cursor.token
        || length > LOCAL_STUDIO_CURSOR_MAX_CHARS
    {
        Err(LocalStudioClientError::Protocol(format!(
            "{field}.token must be a non-empty trimmed opaque token of at most {LOCAL_STUDIO_CURSOR_MAX_CHARS} characters"
        )))
    } else {
        Ok(())
    }
}

fn validate_session_page(page: &LocalStudioSessionPage) -> Result<(), LocalStudioClientError> {
    validate_protocol_version(page.protocol_version)?;
    validate_identifier(&page.request_id, "requestId")?;
    validate_identifier(&page.page_id, "pageId")?;
    validate_external_session_identity(&page.canonical_session, "canonicalSession")?;
    validate_session_origin(&page.origin)?;
    validate_session_metadata(&page.metadata)?;
    validate_safe_u64(page.revision, "revision")?;
    if page.messages.len() > LOCAL_STUDIO_SESSION_MAX_PAGE_ITEMS {
        return Err(LocalStudioClientError::Protocol(format!(
            "session page must not exceed {LOCAL_STUDIO_SESSION_MAX_PAGE_ITEMS} messages"
        )));
    }
    validate_messages(&page.messages)?;
    validate_tools(&page.tools)?;
    validate_attachments(&page.attachments)?;
    validate_content_hashes(page)?;
    if let Some(cursor) = &page.cursor {
        validate_transfer_cursor(cursor, "cursor")?;
        if !cursor.has_more {
            return Err(LocalStudioClientError::Protocol(
                "a present session cursor must advertise another page".into(),
            ));
        }
        if cursor.revision != page.revision {
            return Err(LocalStudioClientError::Protocol(
                "session cursor revision does not match page revision".into(),
            ));
        }
        if let Some(message) = page.messages.last()
            && cursor.after_sequence != message.sequence
        {
            return Err(LocalStudioClientError::Protocol(
                "session cursor does not match the final message sequence".into(),
            ));
        }
    }
    Ok(())
}

fn validate_session_page_context(
    page: &LocalStudioSessionPage,
    manifest: &LocalStudioCapabilitiesManifest,
    request_id: &str,
    requested_session: Option<&LocalStudioExternalSessionIdentity>,
    requested_cursor: Option<&LocalStudioTransferCursor>,
    limit: u64,
) -> Result<(), LocalStudioClientError> {
    if page.request_id != request_id {
        return Err(LocalStudioClientError::Protocol(
            "session page request identity does not match signed request".into(),
        ));
    }
    if page.canonical_session.kind != LocalStudioSessionIdentityKind::ExternalSession
        || page.canonical_session.authority != LocalStudioSessionAuthority::LocalStudio
        || page.canonical_session.installation_id != manifest.controller_id
    {
        return Err(LocalStudioClientError::Protocol(
            "session page canonical identity does not belong to the advertised Local Studio installation"
                .into(),
        ));
    }
    if let Some(requested_session) = requested_session
        && &page.canonical_session != requested_session
    {
        return Err(LocalStudioClientError::Protocol(
            "session page canonical identity does not match the exact requested Pi session".into(),
        ));
    }
    if let Some(requested_cursor) = requested_cursor
        && page.revision != requested_cursor.revision
    {
        return Err(LocalStudioClientError::Protocol(
            "continued session page revision does not match its opaque cursor".into(),
        ));
    }
    if let Some(requested_cursor) = requested_cursor {
        if let Some(message) = page.messages.first()
            && message.sequence <= requested_cursor.after_sequence
        {
            return Err(LocalStudioClientError::Protocol(
                "continued session page does not advance beyond its opaque cursor".into(),
            ));
        }
        if let Some(next_cursor) = &page.cursor
            && next_cursor.after_sequence < requested_cursor.after_sequence
        {
            return Err(LocalStudioClientError::Protocol(
                "continued session cursor regresses its message sequence".into(),
            ));
        }
    }
    if page.messages.len() > limit as usize {
        return Err(LocalStudioClientError::Protocol(
            "session page contains more messages than the requested limit".into(),
        ));
    }
    if page.origin.application == LocalStudioSessionAuthority::LocalStudio
        && page.origin.installation_id != manifest.controller_id
    {
        return Err(LocalStudioClientError::Protocol(
            "Local Studio session origin does not match the advertised installation".into(),
        ));
    }
    Ok(())
}

fn validate_agent_turn_input(
    session_id: &str,
    expected_revision: u64,
    message_id: &str,
    idempotency_key: &str,
    content: &str,
    model_id: Option<&str>,
) -> Result<(), LocalStudioClientError> {
    validate_pi_session_id(session_id, "sessionId")?;
    validate_safe_u64(expected_revision, "expectedRevision")?;
    validate_identifier(message_id, "messageId")?;
    validate_identifier(idempotency_key, "idempotencyKey")?;
    if let Some(model_id) = model_id {
        validate_identifier(model_id, "modelId")?;
    }
    if content.is_empty() {
        return Err(LocalStudioClientError::Protocol(
            "agent turn content must not be empty".into(),
        ));
    }
    if content
        .encode_utf16()
        .take(LOCAL_STUDIO_AGENT_TURN_MAX_UTF16_CODE_UNITS + 1)
        .count()
        > LOCAL_STUDIO_AGENT_TURN_MAX_UTF16_CODE_UNITS
    {
        return Err(LocalStudioClientError::Protocol(format!(
            "agent turn content exceeds {LOCAL_STUDIO_AGENT_TURN_MAX_UTF16_CODE_UNITS} UTF-16 code units"
        )));
    }
    Ok(())
}

fn validate_agent_turn_ack(ack: &LocalStudioAgentTurnAck) -> Result<(), LocalStudioClientError> {
    validate_protocol_version(ack.protocol_version)?;
    validate_identifier(&ack.request_id, "requestId")?;
    validate_identifier(&ack.idempotency_key, "idempotencyKey")?;
    validate_identifier(&ack.dispatch_id, "dispatchId")?;
    validate_external_session_identity(&ack.canonical_session, "canonicalSession")?;
    validate_identifier(&ack.message_id, "messageId")?;
    validate_sha256(&ack.content_hash, "contentHash")?;
    validate_safe_u64(ack.base_revision, "baseRevision")?;
    validate_pi_session_id(&ack.pi_session_id, "piSessionId")?;
    validate_identifier(&ack.model_id, "modelId")?;
    validate_timestamp(&ack.accepted_at, "acceptedAt")
}

fn validate_conflict_result(
    conflict: &LocalStudioConflictResult,
) -> Result<(), LocalStudioClientError> {
    validate_protocol_version(conflict.protocol_version)?;
    validate_identifier(&conflict.request_id, "requestId")?;
    validate_safe_u64(conflict.expected_revision, "expectedRevision")?;
    validate_safe_u64(conflict.current_revision, "currentRevision")?;
    if let Some(identity) = &conflict.canonical_session {
        validate_external_session_identity(identity, "canonicalSession")?;
    }
    if let Some(cursor) = &conflict.cursor {
        validate_transfer_cursor(cursor, "cursor")?;
    }
    validate_bridge_error(&conflict.error)
}

fn validate_agent_turn_ack_context(
    ack: &LocalStudioAgentTurnAck,
    request: &AgentTurnRequest<'_>,
) -> Result<(), LocalStudioClientError> {
    if ack.request_id != request.auth.request_id
        || ack.idempotency_key != request.auth.idempotency_key
        || &ack.canonical_session != request.session
        || ack.message_id != request.message_id
        || ack.content_hash != request.content_hash
        || ack.base_revision != request.expected_revision
        || ack.pi_session_id != request.session.session_id
        || request
            .model_id
            .is_some_and(|requested_model| ack.model_id != requested_model)
    {
        return Err(LocalStudioClientError::Protocol(
            "agent turn acknowledgement does not match the signed request".into(),
        ));
    }
    Ok(())
}

fn validate_agent_turn_conflict_context(
    conflict: &LocalStudioConflictResult,
    request: &AgentTurnRequest<'_>,
) -> Result<(), LocalStudioClientError> {
    if conflict.request_id != request.auth.request_id
        || conflict.operation != LocalStudioConflictOperation::AgentTurn
        || conflict.expected_revision != request.expected_revision
        || conflict.canonical_session.as_ref() != Some(request.session)
        || conflict.cursor.is_some()
        || conflict.error.code != LocalStudioErrorCode::RevisionConflict
        || conflict
            .error
            .request_id
            .as_ref()
            .is_some_and(|request_id| request_id != &request.auth.request_id)
        || conflict
            .error
            .details
            .as_ref()
            .and_then(|details| details.expected_revision)
            .is_some_and(|revision| revision != request.expected_revision)
        || conflict
            .error
            .details
            .as_ref()
            .and_then(|details| details.current_revision)
            .is_some_and(|revision| revision != conflict.current_revision)
    {
        return Err(LocalStudioClientError::Protocol(
            "agent turn conflict does not match the signed request".into(),
        ));
    }
    Ok(())
}

fn validate_error_request_identity(
    error: &LocalStudioErrorResult,
    request_id: &str,
) -> Result<(), LocalStudioClientError> {
    if error.request_id != request_id
        || error
            .error
            .request_id
            .as_ref()
            .is_some_and(|nested| nested != request_id)
    {
        Err(LocalStudioClientError::Protocol(
            "bridge error request identity does not match signed request".into(),
        ))
    } else {
        Ok(())
    }
}

fn validate_session_origin(
    origin: &LocalStudioSessionOrigin,
) -> Result<(), LocalStudioClientError> {
    validate_identifier(&origin.installation_id, "origin.installationId")?;
    if let Some(device_id) = &origin.device_id {
        validate_identifier(device_id, "origin.deviceId")?;
    }
    validate_timestamp(&origin.exported_at, "origin.exportedAt")
}

fn validate_session_metadata(
    metadata: &LocalStudioSessionMetadata,
) -> Result<(), LocalStudioClientError> {
    if let Some(title) = &metadata.title {
        validate_bounded_text(title, LOCAL_STUDIO_SHORT_TEXT_MAX_CHARS, "metadata.title")?;
    }
    if let Some(cwd) = &metadata.cwd {
        validate_identifier(cwd, "metadata.cwd")?;
    }
    let created_at = parse_timestamp(&metadata.created_at, "metadata.createdAt")?;
    let updated_at = parse_timestamp(&metadata.updated_at, "metadata.updatedAt")?;
    if updated_at < created_at {
        return Err(LocalStudioClientError::Protocol(
            "metadata.updatedAt precedes metadata.createdAt".into(),
        ));
    }
    if let Some(model_id) = &metadata.model_id {
        validate_identifier(model_id, "metadata.modelId")?;
    }
    if let Some(provider_id) = &metadata.provider_id {
        validate_identifier(provider_id, "metadata.providerId")?;
    }
    Ok(())
}

fn validate_messages(
    messages: &[LocalStudioMessageDescriptor],
) -> Result<(), LocalStudioClientError> {
    let mut ids = HashSet::new();
    let mut previous_sequence = None;
    for message in messages {
        validate_identifier(&message.message_id, "messages.messageId")?;
        if !ids.insert(message.message_id.as_str()) {
            return Err(LocalStudioClientError::Protocol(
                "session message IDs must be unique".into(),
            ));
        }
        validate_safe_u64(message.sequence, "messages.sequence")?;
        if previous_sequence.is_some_and(|previous| message.sequence <= previous) {
            return Err(LocalStudioClientError::Protocol(
                "session message sequences must be strictly increasing".into(),
            ));
        }
        previous_sequence = Some(message.sequence);
        if let Some(parent_id) = &message.parent_message_id {
            validate_identifier(parent_id, "messages.parentMessageId")?;
        }
        let created_at = parse_timestamp(&message.created_at, "messages.createdAt")?;
        if let Some(edited_at) = &message.edited_at
            && parse_timestamp(edited_at, "messages.editedAt")? < created_at
        {
            return Err(LocalStudioClientError::Protocol(
                "message editedAt precedes createdAt".into(),
            ));
        }
        for part in &message.parts {
            match part {
                LocalStudioMessagePart::Text { text } => validate_bounded_text(
                    text,
                    LOCAL_STUDIO_WIRE_TEXT_MAX_CHARS,
                    "messages.parts.text",
                )?,
                LocalStudioMessagePart::Reasoning { text } => validate_bounded_text(
                    text,
                    LOCAL_STUDIO_WIRE_TEXT_MAX_CHARS,
                    "messages.parts.reasoning",
                )?,
                LocalStudioMessagePart::ToolRef { tool_call_id } => {
                    validate_identifier(tool_call_id, "messages.parts.toolCallId")?
                }
                LocalStudioMessagePart::AttachmentRef { attachment_id } => {
                    validate_identifier(attachment_id, "messages.parts.attachmentId")?
                }
            }
        }
        validate_sha256(&message.content_hash, "messages.contentHash")?;
        let expected_hash = local_studio_message_hash(message)?;
        if message.content_hash != expected_hash {
            return Err(LocalStudioClientError::Protocol(
                "message contentHash does not match the canonical descriptor".into(),
            ));
        }
    }
    Ok(())
}

fn validate_tools(tools: &[LocalStudioToolDescriptor]) -> Result<(), LocalStudioClientError> {
    let mut ids = HashSet::new();
    for tool in tools {
        validate_identifier(&tool.tool_call_id, "tools.toolCallId")?;
        if !ids.insert(tool.tool_call_id.as_str()) {
            return Err(LocalStudioClientError::Protocol(
                "session tool call IDs must be unique".into(),
            ));
        }
        validate_identifier(&tool.message_id, "tools.messageId")?;
        validate_identifier(&tool.name, "tools.name")?;
        validate_json_text(&tool.arguments_json, "tools.argumentsJson")?;
        validate_sha256(&tool.arguments_hash, "tools.argumentsHash")?;
        if tool.arguments_hash != sha256_utf8(&tool.arguments_json) {
            return Err(LocalStudioClientError::Protocol(
                "tool argumentsHash does not match argumentsJson".into(),
            ));
        }
        match (&tool.result_json, &tool.result_hash) {
            (Some(result), Some(hash)) => {
                validate_json_text(result, "tools.resultJson")?;
                validate_sha256(hash, "tools.resultHash")?;
                if hash != &sha256_utf8(result) {
                    return Err(LocalStudioClientError::Protocol(
                        "tool resultHash does not match resultJson".into(),
                    ));
                }
            }
            (None, None) => {}
            _ => {
                return Err(LocalStudioClientError::Protocol(
                    "tool resultJson and resultHash must both be present or absent".into(),
                ));
            }
        }
        let started_at = tool
            .started_at
            .as_deref()
            .map(|value| parse_timestamp(value, "tools.startedAt"))
            .transpose()?;
        let completed_at = tool
            .completed_at
            .as_deref()
            .map(|value| parse_timestamp(value, "tools.completedAt"))
            .transpose()?;
        if let (Some(started), Some(completed)) = (started_at, completed_at)
            && completed < started
        {
            return Err(LocalStudioClientError::Protocol(
                "tool completedAt precedes startedAt".into(),
            ));
        }
    }
    Ok(())
}

fn validate_attachments(
    attachments: &[LocalStudioAttachmentDescriptor],
) -> Result<(), LocalStudioClientError> {
    let mut ids = HashSet::new();
    for attachment in attachments {
        validate_identifier(&attachment.attachment_id, "attachments.attachmentId")?;
        if !ids.insert(attachment.attachment_id.as_str()) {
            return Err(LocalStudioClientError::Protocol(
                "session attachment IDs must be unique".into(),
            ));
        }
        validate_identifier(&attachment.message_id, "attachments.messageId")?;
        validate_identifier(&attachment.file_name, "attachments.fileName")?;
        validate_identifier(&attachment.media_type, "attachments.mediaType")?;
        validate_safe_u64(attachment.byte_length, "attachments.byteLength")?;
        validate_sha256(&attachment.content_hash, "attachments.contentHash")?;
        if let Some(blob_id) = &attachment.blob_id {
            validate_identifier(blob_id, "attachments.blobId")?;
        }
    }
    Ok(())
}

fn validate_content_hashes(page: &LocalStudioSessionPage) -> Result<(), LocalStudioClientError> {
    let hashes = &page.content_hashes;
    let messages = &page.messages;
    let tools = &page.tools;
    let attachments = &page.attachments;
    validate_sha256(&hashes.session, "contentHashes.session")?;
    validate_hash_references(&hashes.messages, "contentHashes.messages")?;
    validate_hash_references(&hashes.tools, "contentHashes.tools")?;
    validate_hash_references(&hashes.attachments, "contentHashes.attachments")?;
    if hashes.messages.len() != messages.len()
        || hashes.tools.len() != tools.len()
        || hashes.attachments.len() != attachments.len()
    {
        return Err(LocalStudioClientError::Protocol(
            "content hash reference arrays must match descriptor arrays".into(),
        ));
    }
    for (reference, message) in hashes.messages.iter().zip(messages) {
        if reference.id != message.message_id || reference.sha256 != message.content_hash {
            return Err(LocalStudioClientError::Protocol(
                "message hash references do not match message descriptors".into(),
            ));
        }
    }
    for (reference, tool) in hashes.tools.iter().zip(tools) {
        if reference.id != tool.tool_call_id || reference.sha256 != local_studio_tool_hash(tool)? {
            return Err(LocalStudioClientError::Protocol(
                "tool hash references do not match tool descriptors".into(),
            ));
        }
    }
    for (reference, attachment) in hashes.attachments.iter().zip(attachments) {
        if reference.id != attachment.attachment_id || reference.sha256 != attachment.content_hash {
            return Err(LocalStudioClientError::Protocol(
                "attachment hash references do not match attachment descriptors".into(),
            ));
        }
    }
    if hashes.session != local_studio_session_hash(page)? {
        return Err(LocalStudioClientError::Protocol(
            "session content hash does not match the canonical page identity and references".into(),
        ));
    }
    Ok(())
}

fn validate_hash_references(
    references: &[LocalStudioHashReference],
    field: &str,
) -> Result<(), LocalStudioClientError> {
    let mut ids = HashSet::new();
    for reference in references {
        validate_identifier(&reference.id, &format!("{field}.id"))?;
        validate_sha256(&reference.sha256, &format!("{field}.sha256"))?;
        if !ids.insert(reference.id.as_str()) {
            return Err(LocalStudioClientError::Protocol(format!(
                "{field} IDs must be unique"
            )));
        }
    }
    Ok(())
}

fn local_studio_message_hash(
    message: &LocalStudioMessageDescriptor,
) -> Result<String, LocalStudioClientError> {
    let mut descriptor = serde_json::to_value(message).map_err(|error| {
        LocalStudioClientError::Protocol(format!("encoding message hash descriptor: {error}"))
    })?;
    descriptor
        .as_object_mut()
        .ok_or_else(|| {
            LocalStudioClientError::Protocol("message hash descriptor must be an object".into())
        })?
        .remove("contentHash")
        .ok_or_else(|| {
            LocalStudioClientError::Protocol(
                "message hash descriptor is missing contentHash".into(),
            )
        })?;
    canonical_body_hash(&json!(["litter-bridge-message-v1", descriptor]))
}

fn local_studio_tool_hash(
    tool: &LocalStudioToolDescriptor,
) -> Result<String, LocalStudioClientError> {
    canonical_body_hash(&json!(["litter-bridge-tool-v1", tool]))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionHashInput<'a> {
    canonical_session: &'a LocalStudioExternalSessionIdentity,
    metadata: &'a LocalStudioSessionMetadata,
    revision: u64,
    messages: &'a [LocalStudioHashReference],
    tools: &'a [LocalStudioHashReference],
    attachments: &'a [LocalStudioHashReference],
}

fn local_studio_session_hash(
    page: &LocalStudioSessionPage,
) -> Result<String, LocalStudioClientError> {
    canonical_body_hash(&json!([
        "litter-bridge-session-v1",
        SessionHashInput {
            canonical_session: &page.canonical_session,
            metadata: &page.metadata,
            revision: page.revision,
            messages: &page.content_hashes.messages,
            tools: &page.content_hashes.tools,
            attachments: &page.content_hashes.attachments,
        }
    ]))
}

fn sha256_utf8(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

fn deserialize_required_option<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

fn deserialize_optional_identifier<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    if let Some(value) = &value {
        validate_identifier(value, "nullable identifier").map_err(D::Error::custom)?;
    }
    Ok(value)
}

fn deserialize_optional_safe_u64<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<u64>::deserialize(deserializer)?;
    if let Some(value) = value {
        validate_safe_u64(value, "nullable integer").map_err(D::Error::custom)?;
    }
    Ok(value)
}

fn validate_safe_u64(value: u64, field: &str) -> Result<(), LocalStudioClientError> {
    const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
    if value <= MAX_SAFE_INTEGER {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} exceeds the canonical JSON safe-integer range"
        )))
    }
}

fn validate_sha256(value: &str, field: &str) -> Result<(), LocalStudioClientError> {
    static SHA256: OnceLock<Regex> = OnceLock::new();
    let pattern =
        SHA256.get_or_init(|| Regex::new(r"^[a-f0-9]{64}$").expect("valid SHA-256 regex"));
    if pattern.is_match(value) {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} must be a lowercase SHA-256 digest"
        )))
    }
}

fn validate_bounded_text(
    value: &str,
    max_chars: usize,
    field: &str,
) -> Result<(), LocalStudioClientError> {
    if value.chars().count() <= max_chars {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} exceeds {max_chars} characters"
        )))
    }
}

fn validate_json_text(value: &str, field: &str) -> Result<(), LocalStudioClientError> {
    validate_bounded_text(value, LOCAL_STUDIO_JSON_TEXT_MAX_CHARS, field)?;
    serde_json::from_str::<Value>(value)
        .map(|_| ())
        .map_err(|_| LocalStudioClientError::Protocol(format!("{field} is not valid JSON text")))
}

fn parse_timestamp(value: &str, field: &str) -> Result<DateTime<Utc>, LocalStudioClientError> {
    validate_timestamp(value, field)?;
    DateTime::parse_from_rfc3339(value)
        .map(|timestamp| timestamp.with_timezone(&Utc))
        .map_err(|_| {
            LocalStudioClientError::Protocol(format!("{field} must be an RFC3339 UTC timestamp"))
        })
}

fn validate_protocol_version(version: u32) -> Result<(), LocalStudioClientError> {
    if version == LOCAL_STUDIO_BRIDGE_PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "unsupported bridge protocol version {version}"
        )))
    }
}

fn validate_unique_capabilities(
    capabilities: &[LocalStudioCapability],
) -> Result<(), LocalStudioClientError> {
    let mut unique = HashSet::new();
    if capabilities
        .iter()
        .copied()
        .all(|capability| unique.insert(capability))
    {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(
            "capabilities must be unique".into(),
        ))
    }
}

fn validate_health_section(
    section: &LocalStudioHealthSection,
) -> Result<(), LocalStudioClientError> {
    validate_freshness(&section.freshness)?;
    if let Some(error) = &section.error {
        validate_bridge_error(error)?;
    }
    if let Some(value) = &section.value {
        validate_timestamp(&value.checked_at, "checkedAt")?;
        if let Some(latency) = value.latency_ms {
            validate_non_negative_finite(latency, "latencyMs")?;
        }
        if let Some(version) = &value.controller_version {
            validate_identifier(version, "controllerVersion")?;
        }
    }
    Ok(())
}

fn validate_status_section(
    section: &LocalStudioStatusSection,
) -> Result<(), LocalStudioClientError> {
    validate_freshness(&section.freshness)?;
    if let Some(error) = &section.error {
        validate_bridge_error(error)?;
    }
    if let Some(value) = &section.value {
        if value.inference_port == Some(0) {
            return Err(LocalStudioClientError::Protocol(
                "inferencePort must be positive".into(),
            ));
        }
        for (field, id) in [
            ("launchingRecipeId", value.launching_recipe_id.as_ref()),
            ("activeLaunchId", value.active_launch_id.as_ref()),
        ] {
            if let Some(id) = id {
                validate_identifier(id, field)?;
            }
        }
        for id in &value.active_model_ids {
            validate_identifier(id, "activeModelIds")?;
        }
    }
    Ok(())
}

fn validate_gpus_section(section: &LocalStudioGpusSection) -> Result<(), LocalStudioClientError> {
    validate_freshness(&section.freshness)?;
    if let Some(error) = &section.error {
        validate_bridge_error(error)?;
    }
    if let Some(value) = &section.value {
        for device in &value.devices {
            validate_identifier(&device.id, "gpu.id")?;
            validate_identifier(&device.name, "gpu.name")?;
            if let Some(utilization) = device.utilization_percent {
                validate_percentage(utilization, "utilizationPercent")?;
            }
            if let Some(temperature) = device.temperature_celsius {
                validate_finite(temperature, "temperatureCelsius")?;
            }
            if let Some(power) = device.power_watts {
                validate_non_negative_finite(power, "powerWatts")?;
            }
        }
    }
    Ok(())
}

fn validate_metrics_section(
    section: &LocalStudioMetricsSection,
) -> Result<(), LocalStudioClientError> {
    validate_freshness(&section.freshness)?;
    if let Some(error) = &section.error {
        validate_bridge_error(error)?;
    }
    if let Some(value) = &section.value {
        for (field, number) in [
            ("promptTokensPerSecond", value.prompt_tokens_per_second),
            (
                "generationTokensPerSecond",
                value.generation_tokens_per_second,
            ),
            ("timeToFirstTokenMs", value.time_to_first_token_ms),
        ] {
            if let Some(number) = number {
                validate_non_negative_finite(number, field)?;
            }
        }
        if let Some(percentage) = value.cache_usage_percent {
            validate_percentage(percentage, "cacheUsagePercent")?;
        }
    }
    Ok(())
}

fn validate_agent_runtime_section(
    section: &LocalStudioAgentRuntimeSection,
) -> Result<(), LocalStudioClientError> {
    validate_freshness(&section.freshness)?;
    if let Some(error) = &section.error {
        validate_bridge_error(error)?;
    }
    Ok(())
}

fn validate_freshness(freshness: &LocalStudioFreshness) -> Result<(), LocalStudioClientError> {
    if let Some(observed_at) = &freshness.observed_at {
        validate_timestamp(observed_at, "observedAt")?;
    }
    Ok(())
}

fn validate_error_result(result: &LocalStudioErrorResult) -> Result<(), LocalStudioClientError> {
    validate_protocol_version(result.protocol_version)?;
    validate_identifier(&result.request_id, "requestId")?;
    validate_bridge_error(&result.error)
}

fn validate_bridge_error(error: &LocalStudioBridgeError) -> Result<(), LocalStudioClientError> {
    if error.message.chars().count() > 4096 {
        return Err(LocalStudioClientError::Protocol(
            "error message exceeds 4096 characters".into(),
        ));
    }
    if let Some(request_id) = &error.request_id {
        validate_identifier(request_id, "error.requestId")?;
    }
    if let Some(details) = &error.details {
        if let Some(field) = &details.field {
            validate_identifier(field, "error.details.field")?;
        }
    }
    Ok(())
}

fn validate_identifier(value: &str, field: &str) -> Result<(), LocalStudioClientError> {
    if value.is_empty() || value.trim() != value || value.len() > 512 {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} must be a non-empty trimmed identifier of at most 512 UTF-8 bytes"
        )))
    } else {
        Ok(())
    }
}

fn validate_nonce(value: &str) -> Result<(), LocalStudioClientError> {
    let len = value.chars().count();
    if !(16..=512).contains(&len)
        || value.trim() != value
        || !value.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '_' || character == '-'
        })
    {
        Err(LocalStudioClientError::Protocol(
            "invalid request nonce".into(),
        ))
    } else {
        Ok(())
    }
}

fn validate_timestamp(value: &str, field: &str) -> Result<(), LocalStudioClientError> {
    static TIMESTAMP: OnceLock<Regex> = OnceLock::new();
    let timestamp = TIMESTAMP.get_or_init(|| {
        Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$")
            .expect("valid timestamp regex")
    });
    if timestamp.is_match(value) && DateTime::parse_from_rfc3339(value).is_ok() {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} must be an RFC3339 UTC timestamp"
        )))
    }
}

fn validate_finite(value: f64, field: &str) -> Result<(), LocalStudioClientError> {
    if value.is_finite() {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} must be finite"
        )))
    }
}

fn validate_non_negative_finite(value: f64, field: &str) -> Result<(), LocalStudioClientError> {
    validate_finite(value, field)?;
    if value >= 0.0 {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} must be non-negative"
        )))
    }
}

fn validate_percentage(value: f64, field: &str) -> Result<(), LocalStudioClientError> {
    validate_finite(value, field)?;
    if (0.0..=100.0).contains(&value) {
        Ok(())
    } else {
        Err(LocalStudioClientError::Protocol(format!(
            "{field} must be between 0 and 100"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_and_validation_contracts() {
        let script = probe_script();
        for marker in [
            "Library/Application Support/Local Studio/pi-agent",
            ".vllm-studio/pi-agent",
            ".local-studio/pi-agent",
            "local-studio\\t%s",
        ] {
            assert!(script.contains(marker));
        }
        assert_eq!(
            session_scan_prefix("/tmp/Local Studio/pi-agent"),
            "PI_CODING_AGENT_DIR='/tmp/Local Studio/pi-agent'\nexport PI_CODING_AGENT_DIR"
        );
        assert!(validate_nonce("short").is_err());
        assert!(validate_percentage(f64::NAN, "gpu").is_err());
        assert!(validate_percentage(101.0, "gpu").is_err());

        let target = ParsedPairPayload {
            version: 2,
            node_id: "node".into(),
            token: "token".into(),
            relay: None,
            host_name: None,
        };
        let registry = LocalStudioTargetRegistry::default();
        registry.register("server".into(), target.clone());
        assert_eq!(registry.resolve("server").unwrap(), target);
    }

    #[tokio::test]
    #[ignore = "requires a paired KittyLitter daemon and running Local Studio gateway"]
    async fn live_controller_and_session_catalog_round_trip() {
        let pair = ParsedPairPayload {
            version: crate::alleycat::ALLEYCAT_PROTOCOL_VERSION,
            node_id: std::env::var("LITTER_LIVE_ALLEYCAT_NODE_ID").unwrap(),
            token: std::env::var("LITTER_LIVE_ALLEYCAT_TOKEN").unwrap(),
            relay: std::env::var("LITTER_LIVE_ALLEYCAT_RELAY")
                .ok()
                .filter(|value| !value.is_empty()),
            host_name: Some("litter-live-local-studio".into()),
        };
        let endpoint = crate::alleycat::bind_alleycat_endpoint(Some([7; 32]))
            .await
            .unwrap();
        assert!(matches!(
            load_local_studio_controller(&endpoint, pair.clone())
                .await
                .unwrap(),
            LocalStudioControllerLoadResult::Loaded { .. }
        ));
        assert!(matches!(
            list_local_studio_sessions(&endpoint, pair, 20)
                .await
                .unwrap(),
            LocalStudioSessionListResult::Page { .. }
        ));
        endpoint.close().await;
    }
}
