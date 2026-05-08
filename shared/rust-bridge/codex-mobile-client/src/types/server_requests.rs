//! Mobile-owned server request projections.
//!
//! Upstream protocol request and response wrappers are the canonical protocol
//! surface. This module is reserved for UI-specific projections that do not
//! exist upstream.

use crate::RpcClientError;
use codex_app_server_protocol as upstream;
use codex_protocol::openai_models::ReasoningEffort as CoreReasoningEffort;
use codex_utils_absolute_path::AbsolutePathBuf;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use super::enums::ApprovalKind;
use super::{
    AbsolutePath, AppAskForApproval, AppDynamicToolSpec, AppMergeStrategy, AppReadOnlyAccess,
    AppRealtimeAudioChunk, AppReviewTarget, AppSandboxMode, AppSandboxPolicy, AppUserInput,
    ReasoningEffort, ServiceTier,
};

fn absolute_path_buf_from_mobile(value: AbsolutePath) -> Result<AbsolutePathBuf, RpcClientError> {
    AbsolutePathBuf::try_from(value.value).map_err(|error| {
        RpcClientError::Serialization(format!("convert AbsolutePath -> AbsolutePathBuf: {error}"))
    })
}

fn path_buf_from_mobile(value: AbsolutePath) -> PathBuf {
    PathBuf::from(value.value)
}

pub(crate) fn ask_for_approval_into_upstream(value: AppAskForApproval) -> upstream::AskForApproval {
    match value {
        AppAskForApproval::UnlessTrusted => upstream::AskForApproval::UnlessTrusted,
        AppAskForApproval::OnFailure => upstream::AskForApproval::OnFailure,
        AppAskForApproval::OnRequest => upstream::AskForApproval::OnRequest,
        AppAskForApproval::Granular {
            sandbox_approval,
            rules,
            skill_approval,
            request_permissions,
            mcp_elicitations,
        } => upstream::AskForApproval::Granular {
            sandbox_approval,
            rules,
            skill_approval,
            request_permissions,
            mcp_elicitations,
        },
        AppAskForApproval::Never => upstream::AskForApproval::Never,
    }
}

pub(crate) fn sandbox_mode_into_upstream(value: AppSandboxMode) -> upstream::SandboxMode {
    match value {
        AppSandboxMode::ReadOnly => upstream::SandboxMode::ReadOnly,
        AppSandboxMode::WorkspaceWrite => upstream::SandboxMode::WorkspaceWrite,
        AppSandboxMode::DangerFullAccess => upstream::SandboxMode::DangerFullAccess,
    }
}

/// Wire-format string for upstream `Option<Option<String>>` service_tier
/// fields. Matches `ServiceTier`'s `rename_all = "lowercase"` serde shape.
pub(crate) fn service_tier_into_upstream_string(value: ServiceTier) -> String {
    match value {
        ServiceTier::Fast => "fast".to_string(),
        ServiceTier::Flex => "flex".to_string(),
    }
}

pub(crate) fn reasoning_effort_into_upstream(value: ReasoningEffort) -> CoreReasoningEffort {
    match value {
        ReasoningEffort::None => CoreReasoningEffort::None,
        ReasoningEffort::Minimal => CoreReasoningEffort::Minimal,
        ReasoningEffort::Low => CoreReasoningEffort::Low,
        ReasoningEffort::Medium => CoreReasoningEffort::Medium,
        ReasoningEffort::High => CoreReasoningEffort::High,
        ReasoningEffort::XHigh => CoreReasoningEffort::XHigh,
    }
}

fn network_access_into_upstream(value: super::AppNetworkAccess) -> upstream::NetworkAccess {
    match value {
        super::AppNetworkAccess::Restricted => upstream::NetworkAccess::Restricted,
        super::AppNetworkAccess::Enabled => upstream::NetworkAccess::Enabled,
    }
}

fn ensure_read_only_access_supported(value: AppReadOnlyAccess) -> Result<(), RpcClientError> {
    match value {
        AppReadOnlyAccess::FullAccess => Ok(()),
        AppReadOnlyAccess::Restricted { .. } => Err(RpcClientError::Serialization(
            "restricted read access is no longer supported by SandboxPolicy; use permission profiles"
                .to_string(),
        )),
    }
}

fn sandbox_policy_into_upstream(
    value: AppSandboxPolicy,
) -> Result<upstream::SandboxPolicy, RpcClientError> {
    Ok(match value {
        AppSandboxPolicy::DangerFullAccess => upstream::SandboxPolicy::DangerFullAccess,
        AppSandboxPolicy::ReadOnly {
            access,
            network_access,
        } => {
            ensure_read_only_access_supported(access)?;
            upstream::SandboxPolicy::ReadOnly { network_access }
        }
        AppSandboxPolicy::ExternalSandbox { network_access } => {
            upstream::SandboxPolicy::ExternalSandbox {
                network_access: network_access_into_upstream(network_access),
            }
        }
        AppSandboxPolicy::WorkspaceWrite {
            writable_roots,
            read_only_access,
            network_access,
            exclude_tmpdir_env_var,
            exclude_slash_tmp,
        } => {
            ensure_read_only_access_supported(read_only_access)?;
            upstream::SandboxPolicy::WorkspaceWrite {
                writable_roots: writable_roots
                    .into_iter()
                    .map(absolute_path_buf_from_mobile)
                    .collect::<Result<Vec<_>, _>>()?,
                network_access,
                exclude_tmpdir_env_var,
                exclude_slash_tmp,
            }
        }
    })
}

fn byte_range_into_upstream(
    value: super::AppByteRange,
) -> Result<upstream::ByteRange, RpcClientError> {
    let start = usize::try_from(value.start).map_err(|error| {
        RpcClientError::Serialization(format!("byte range start out of range: {error}"))
    })?;
    let end = usize::try_from(value.end).map_err(|error| {
        RpcClientError::Serialization(format!("byte range end out of range: {error}"))
    })?;
    Ok(upstream::ByteRange { start, end })
}

fn text_element_into_upstream(
    value: super::AppTextElement,
) -> Result<upstream::TextElement, RpcClientError> {
    Ok(upstream::TextElement::new(
        byte_range_into_upstream(value.byte_range)?,
        None,
    ))
}

fn user_input_into_upstream(value: AppUserInput) -> Result<upstream::UserInput, RpcClientError> {
    Ok(match value {
        AppUserInput::Text {
            text,
            text_elements,
        } => upstream::UserInput::Text {
            text,
            text_elements: text_elements
                .into_iter()
                .map(text_element_into_upstream)
                .collect::<Result<Vec<_>, _>>()?,
        },
        AppUserInput::Image { url } => upstream::UserInput::Image { url },
        AppUserInput::LocalImage { path } => upstream::UserInput::LocalImage {
            path: path_buf_from_mobile(path),
        },
        AppUserInput::Skill { name, path } => upstream::UserInput::Skill {
            name,
            path: path_buf_from_mobile(path),
        },
        AppUserInput::Mention { name, path } => upstream::UserInput::Mention { name, path },
    })
}

fn dynamic_tool_spec_into_upstream(
    value: AppDynamicToolSpec,
) -> Result<codex_protocol::dynamic_tools::DynamicToolSpec, RpcClientError> {
    value.try_into()
}

fn review_target_into_upstream(value: AppReviewTarget) -> upstream::ReviewTarget {
    match value {
        AppReviewTarget::UncommittedChanges => upstream::ReviewTarget::UncommittedChanges,
        AppReviewTarget::BaseBranch { branch } => upstream::ReviewTarget::BaseBranch { branch },
        AppReviewTarget::Commit { sha, title } => upstream::ReviewTarget::Commit { sha, title },
        AppReviewTarget::Custom { instructions } => upstream::ReviewTarget::Custom { instructions },
    }
}

fn review_delivery_into_upstream(
    value: Option<String>,
) -> Result<Option<upstream::ReviewDelivery>, RpcClientError> {
    match value.as_deref() {
        None => Ok(None),
        Some("inline") => Ok(Some(upstream::ReviewDelivery::Inline)),
        Some("detached") => Ok(Some(upstream::ReviewDelivery::Detached)),
        Some(other) => Err(RpcClientError::Serialization(format!(
            "invalid review delivery: {other}"
        ))),
    }
}

fn merge_strategy_into_upstream(value: AppMergeStrategy) -> upstream::MergeStrategy {
    match value {
        AppMergeStrategy::Replace => upstream::MergeStrategy::Replace,
        AppMergeStrategy::Upsert => upstream::MergeStrategy::Upsert,
    }
}

/// A pending approval request from the server that needs user action.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct PendingApproval {
    /// The JSON-RPC request ID as a string (could originally be string or integer).
    pub id: String,
    /// Server that owns this approval.
    pub server_id: String,
    /// What kind of approval is being requested.
    pub kind: ApprovalKind,
    /// Thread this approval belongs to.
    pub thread_id: Option<String>,
    /// Turn this approval belongs to.
    pub turn_id: Option<String>,
    /// Item ID this approval is associated with.
    pub item_id: Option<String>,
    /// The command to approve, if applicable.
    pub command: Option<String>,
    /// The file path involved, if applicable.
    pub path: Option<String>,
    /// Grant root involved in a file change request, if applicable.
    pub grant_root: Option<String>,
    /// Working directory for the command, if applicable.
    pub cwd: Option<String>,
    /// Human-readable reason/explanation for the approval request.
    pub reason: Option<String>,
}

/// Rust-only raw request seed retained for IPC hydration and approval responses.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct PendingApprovalSeed {
    pub request_id: codex_app_server_protocol::RequestId,
    pub raw_params: serde_json::Value,
}

/// Internal pairing of the public approval projection with its raw request seed.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct PendingApprovalWithSeed {
    pub approval: PendingApproval,
    pub seed: PendingApprovalSeed,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct PendingApprovalKey {
    pub server_id: String,
    pub request_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct PendingUserInputOption {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct PendingUserInputQuestion {
    pub id: String,
    pub header: Option<String>,
    pub question: String,
    pub is_other_allowed: bool,
    pub is_secret: bool,
    pub options: Vec<PendingUserInputOption>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct PendingUserInputRequest {
    pub id: String,
    pub server_id: String,
    pub thread_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub questions: Vec<PendingUserInputQuestion>,
    pub requester_agent_nickname: Option<String>,
    pub requester_agent_role: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct PendingUserInputAnswer {
    pub question_id: String,
    pub answers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppStartThreadRequest {
    #[serde(default)]
    #[uniffi(default = None)]
    pub agent_runtime_kind: Option<crate::types::AgentRuntimeKind>,
    pub model: Option<String>,
    pub cwd: Option<String>,
    pub approval_policy: Option<AppAskForApproval>,
    pub sandbox: Option<AppSandboxMode>,
    pub developer_instructions: Option<String>,
    pub persist_extended_history: bool,
    pub dynamic_tools: Option<Vec<AppDynamicToolSpec>>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub ephemeral: Option<bool>,
}

impl TryFrom<AppStartThreadRequest> for upstream::ThreadStartParams {
    type Error = RpcClientError;

    fn try_from(value: AppStartThreadRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            model: value.model,
            model_provider: None,
            service_tier: None,
            cwd: value.cwd,
            approval_policy: value.approval_policy.map(ask_for_approval_into_upstream),
            approvals_reviewer: None,
            sandbox: value.sandbox.map(sandbox_mode_into_upstream),
            permissions: None,
            config: None,
            service_name: None,
            base_instructions: None,
            developer_instructions: value.developer_instructions,
            personality: None,
            ephemeral: value.ephemeral,
            session_start_source: None,
            thread_source: None,
            dynamic_tools: value
                .dynamic_tools
                .map(|tools| {
                    tools
                        .into_iter()
                        .map(|spec| {
                            let input_schema: serde_json::Value =
                                serde_json::from_str(&spec.input_schema_json).map_err(|e| {
                                    RpcClientError::Serialization(format!(
                                        "parse dynamic tool input_schema_json: {e}"
                                    ))
                                })?;
                            Ok(upstream::DynamicToolSpec {
                                name: spec.name,
                                description: spec.description,
                                input_schema,
                                namespace: None,
                                defer_loading: spec.defer_loading,
                            })
                        })
                        .collect::<Result<Vec<_>, RpcClientError>>()
                })
                .transpose()?,
            environments: None,
            mock_experimental_field: None,
            experimental_raw_events: false,
            persist_extended_history: value.persist_extended_history,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppResumeThreadRequest {
    pub thread_id: String,
    pub model: Option<String>,
    pub cwd: Option<String>,
    pub approval_policy: Option<AppAskForApproval>,
    pub sandbox: Option<AppSandboxMode>,
    pub developer_instructions: Option<String>,
    pub persist_extended_history: bool,
    #[serde(default)]
    #[uniffi(default = false)]
    pub exclude_turns: bool,
}

impl TryFrom<AppResumeThreadRequest> for upstream::ThreadResumeParams {
    type Error = RpcClientError;

    fn try_from(value: AppResumeThreadRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            thread_id: value.thread_id,
            history: None,
            path: None,
            model: value.model,
            model_provider: None,
            service_tier: None,
            cwd: value.cwd,
            approval_policy: value.approval_policy.map(ask_for_approval_into_upstream),
            approvals_reviewer: None,
            sandbox: value.sandbox.map(sandbox_mode_into_upstream),
            permissions: None,
            config: None,
            base_instructions: None,
            developer_instructions: value.developer_instructions,
            personality: None,
            exclude_turns: value.exclude_turns,
            persist_extended_history: value.persist_extended_history,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppForkThreadRequest {
    pub thread_id: String,
    pub model: Option<String>,
    pub cwd: Option<String>,
    pub approval_policy: Option<AppAskForApproval>,
    pub sandbox: Option<AppSandboxMode>,
    pub developer_instructions: Option<String>,
    pub persist_extended_history: bool,
    #[serde(default)]
    #[uniffi(default = false)]
    pub exclude_turns: bool,
}

impl TryFrom<AppForkThreadRequest> for upstream::ThreadForkParams {
    type Error = RpcClientError;

    fn try_from(value: AppForkThreadRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            thread_id: value.thread_id,
            path: None,
            model: value.model,
            model_provider: None,
            service_tier: None,
            cwd: value.cwd,
            approval_policy: value.approval_policy.map(ask_for_approval_into_upstream),
            approvals_reviewer: None,
            sandbox: value.sandbox.map(sandbox_mode_into_upstream),
            permissions: None,
            config: None,
            base_instructions: None,
            developer_instructions: value.developer_instructions,
            ephemeral: false,
            thread_source: None,
            exclude_turns: value.exclude_turns,
            persist_extended_history: value.persist_extended_history,
        })
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum AppTurnsSortDirection {
    Ascending,
    Descending,
}

impl From<AppTurnsSortDirection> for upstream::SortDirection {
    fn from(value: AppTurnsSortDirection) -> Self {
        match value {
            AppTurnsSortDirection::Ascending => upstream::SortDirection::Asc,
            AppTurnsSortDirection::Descending => upstream::SortDirection::Desc,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppListThreadTurnsRequest {
    pub thread_id: String,
    #[serde(default)]
    #[uniffi(default = None)]
    pub cursor: Option<String>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub limit: Option<u32>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub sort_direction: Option<AppTurnsSortDirection>,
}

impl TryFrom<AppListThreadTurnsRequest> for upstream::ThreadTurnsListParams {
    type Error = RpcClientError;

    fn try_from(value: AppListThreadTurnsRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            thread_id: value.thread_id,
            cursor: value.cursor,
            limit: value.limit,
            sort_direction: value.sort_direction.map(Into::into),
        })
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppListThreadTurnsResponse {
    pub turns: Vec<crate::conversation_uniffi::HydratedConversationItem>,
    pub next_cursor: Option<String>,
    pub backwards_cursor: Option<String>,
}

/// Outcome of a `load_thread_turns_page` store action.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppLoadThreadTurnsOutcome {
    /// True when a page of turns was merged into the store. False when the
    /// server does not support pagination (either known up front via
    /// capability flag, or discovered at runtime via `-32601`).
    pub loaded: bool,
    /// True when `next_cursor` was non-null, i.e. more older turns remain.
    pub has_more: bool,
}

impl From<upstream::ThreadTurnsListResponse> for AppListThreadTurnsResponse {
    fn from(value: upstream::ThreadTurnsListResponse) -> Self {
        let turns = crate::conversation::hydrate_turns(
            &value.data,
            &crate::conversation::HydrationOptions::default(),
        );
        Self {
            turns,
            next_cursor: value.next_cursor,
            backwards_cursor: value.backwards_cursor,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppForkThreadFromMessageRequest {
    pub model: Option<String>,
    pub cwd: Option<String>,
    pub approval_policy: Option<AppAskForApproval>,
    pub sandbox: Option<AppSandboxMode>,
    pub developer_instructions: Option<String>,
    pub persist_extended_history: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppArchiveThreadRequest {
    pub thread_id: String,
}

impl From<AppArchiveThreadRequest> for upstream::ThreadArchiveParams {
    fn from(value: AppArchiveThreadRequest) -> Self {
        Self {
            thread_id: value.thread_id,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppRenameThreadRequest {
    pub thread_id: String,
    pub name: String,
}

impl From<AppRenameThreadRequest> for upstream::ThreadSetNameParams {
    fn from(value: AppRenameThreadRequest) -> Self {
        Self {
            thread_id: value.thread_id,
            name: value.name,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppListThreadsRequest {
    #[uniffi(default = None)]
    pub cursor: Option<String>,
    #[uniffi(default = None)]
    pub limit: Option<u32>,
    #[uniffi(default = None)]
    pub sort_key: Option<crate::types::AppThreadSortKey>,
    #[uniffi(default = None)]
    pub sort_direction: Option<crate::types::AppSortDirection>,
    #[uniffi(default = None)]
    pub model_providers: Option<Vec<String>>,
    #[uniffi(default = None)]
    pub source_kinds: Option<Vec<crate::types::AppThreadSourceKind>>,
    #[uniffi(default = None)]
    pub archived: Option<bool>,
    #[uniffi(default = None)]
    pub cwd: Option<String>,
    #[uniffi(default = None)]
    pub search_term: Option<String>,
    #[serde(default)]
    #[uniffi(default = false)]
    pub use_state_db_only: bool,
    #[uniffi(default = None)]
    pub runtime_kinds: Option<Vec<crate::types::AgentRuntimeKind>>,
}

impl From<AppListThreadsRequest> for upstream::ThreadListParams {
    fn from(value: AppListThreadsRequest) -> Self {
        Self {
            cursor: value.cursor,
            limit: value.limit,
            sort_key: value.sort_key.map(Into::into),
            sort_direction: value.sort_direction.map(Into::into),
            model_providers: value.model_providers,
            source_kinds: value
                .source_kinds
                .map(|kinds| kinds.into_iter().map(Into::into).collect()),
            archived: value.archived,
            cwd: value.cwd.map(upstream::ThreadListCwdFilter::One),
            search_term: value.search_term,
            use_state_db_only: value.use_state_db_only,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppReadThreadRequest {
    pub thread_id: String,
    #[serde(default)]
    pub include_turns: bool,
}

impl From<AppReadThreadRequest> for upstream::ThreadReadParams {
    fn from(value: AppReadThreadRequest) -> Self {
        Self {
            thread_id: value.thread_id,
            include_turns: value.include_turns,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppInterruptTurnRequest {
    pub thread_id: String,
    pub turn_id: String,
}

impl From<AppInterruptTurnRequest> for upstream::TurnInterruptParams {
    fn from(value: AppInterruptTurnRequest) -> Self {
        Self {
            thread_id: value.thread_id,
            turn_id: value.turn_id,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppListSkillsRequest {
    pub cwds: Vec<String>,
    pub force_reload: bool,
}

impl From<AppListSkillsRequest> for upstream::SkillsListParams {
    fn from(value: AppListSkillsRequest) -> Self {
        Self {
            cwds: value.cwds.into_iter().map(PathBuf::from).collect(),
            force_reload: value.force_reload,
            per_cwd_extra_user_roots: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppListPluginsRequest {
    /// Working directories used to discover repo marketplaces. May be empty,
    /// in which case only home-scoped marketplaces and the curated marketplace
    /// are considered.
    pub cwds: Vec<String>,
}

impl TryFrom<AppListPluginsRequest> for upstream::PluginListParams {
    type Error = RpcClientError;

    fn try_from(value: AppListPluginsRequest) -> Result<Self, Self::Error> {
        let cwds = if value.cwds.is_empty() {
            None
        } else {
            let mut converted = Vec::with_capacity(value.cwds.len());
            for raw in value.cwds {
                let path = AbsolutePathBuf::try_from(raw).map_err(|error| {
                    RpcClientError::Serialization(format!(
                        "list_plugins cwd is not absolute: {error}"
                    ))
                })?;
                converted.push(path);
            }
            Some(converted)
        };
        Ok(Self {
            cwds,
            marketplace_kinds: None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppStartTurnRequest {
    pub thread_id: String,
    pub input: Vec<AppUserInput>,
    pub approval_policy: Option<AppAskForApproval>,
    pub sandbox_policy: Option<AppSandboxPolicy>,
    pub model: Option<String>,
    pub service_tier: Option<ServiceTier>,
    pub effort: Option<ReasoningEffort>,
    /// Raw JSON Schema that constrains the assistant's final message to
    /// valid JSON matching the schema. Forwarded verbatim to upstream
    /// `TurnStartParams.output_schema`.
    #[serde(default)]
    #[uniffi(default = None)]
    pub output_schema: Option<String>,
}

impl TryFrom<AppStartTurnRequest> for upstream::TurnStartParams {
    type Error = RpcClientError;

    fn try_from(value: AppStartTurnRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            thread_id: value.thread_id,
            input: value
                .input
                .into_iter()
                .map(user_input_into_upstream)
                .collect::<Result<Vec<_>, _>>()?,
            responsesapi_client_metadata: None,
            cwd: None,
            approval_policy: value.approval_policy.map(ask_for_approval_into_upstream),
            approvals_reviewer: None,
            sandbox_policy: value
                .sandbox_policy
                .map(sandbox_policy_into_upstream)
                .transpose()?,
            environments: None,
            permissions: None,
            model: value.model,
            service_tier: value
                .service_tier
                .map(service_tier_into_upstream_string)
                .map(Some),
            effort: value.effort.map(reasoning_effort_into_upstream),
            summary: None,
            personality: None,
            output_schema: value
                .output_schema
                .as_deref()
                .map(|raw| {
                    serde_json::from_str::<serde_json::Value>(raw).map_err(|e| {
                        RpcClientError::Serialization(format!(
                            "parse AppStartTurnRequest.output_schema: {e}"
                        ))
                    })
                })
                .transpose()?,
            collaboration_mode: None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppStartRealtimeSessionRequest {
    pub thread_id: String,
    pub prompt: String,
    pub session_id: Option<String>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub output_modality: Option<crate::types::models::AppRealtimeOutputModality>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub transport: Option<crate::types::models::AppRealtimeStartTransport>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub voice: Option<crate::types::models::AppRealtimeVoice>,
    pub client_controlled_handoff: bool,
    pub dynamic_tools: Option<Vec<AppDynamicToolSpec>>,
}

impl TryFrom<AppStartRealtimeSessionRequest> for upstream::ThreadRealtimeStartParams {
    type Error = RpcClientError;

    fn try_from(value: AppStartRealtimeSessionRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            thread_id: value.thread_id,
            prompt: Some(Some(value.prompt)),
            realtime_session_id: value.session_id,
            output_modality: value
                .output_modality
                .unwrap_or(crate::types::models::AppRealtimeOutputModality::Audio)
                .into(),
            transport: value.transport.map(Into::into),
            voice: value.voice.map(Into::into),
            client_controlled_handoff: value.client_controlled_handoff,
            dynamic_tools: value
                .dynamic_tools
                .map(|tools| {
                    tools
                        .into_iter()
                        .map(dynamic_tool_spec_into_upstream)
                        .collect::<Result<Vec<_>, _>>()
                })
                .transpose()?,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppAppendRealtimeAudioRequest {
    pub thread_id: String,
    pub audio: AppRealtimeAudioChunk,
}

impl From<AppAppendRealtimeAudioRequest> for upstream::ThreadRealtimeAppendAudioParams {
    fn from(value: AppAppendRealtimeAudioRequest) -> Self {
        Self {
            thread_id: value.thread_id,
            audio: upstream::ThreadRealtimeAudioChunk {
                data: value.audio.data,
                sample_rate: value.audio.sample_rate,
                num_channels: value.audio.num_channels as u16,
                samples_per_channel: value.audio.samples_per_channel,
                item_id: value.audio.item_id,
            },
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppAppendRealtimeTextRequest {
    pub thread_id: String,
    pub text: String,
}

impl From<AppAppendRealtimeTextRequest> for upstream::ThreadRealtimeAppendTextParams {
    fn from(value: AppAppendRealtimeTextRequest) -> Self {
        Self {
            thread_id: value.thread_id,
            text: value.text,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppStopRealtimeSessionRequest {
    pub thread_id: String,
}

impl From<AppStopRealtimeSessionRequest> for upstream::ThreadRealtimeStopParams {
    fn from(value: AppStopRealtimeSessionRequest) -> Self {
        Self {
            thread_id: value.thread_id,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppResolveRealtimeHandoffRequest {
    pub thread_id: String,
    pub tool_call_output: String,
}

impl From<AppResolveRealtimeHandoffRequest> for upstream::ThreadRealtimeResolveHandoffParams {
    fn from(value: AppResolveRealtimeHandoffRequest) -> Self {
        Self {
            thread_id: value.thread_id,
            tool_call_output: value.tool_call_output,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppFinalizeRealtimeHandoffRequest {
    pub thread_id: String,
}

impl From<AppFinalizeRealtimeHandoffRequest> for upstream::ThreadRealtimeFinalizeHandoffParams {
    fn from(value: AppFinalizeRealtimeHandoffRequest) -> Self {
        Self {
            thread_id: value.thread_id,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppStartReviewRequest {
    pub thread_id: String,
    pub target: AppReviewTarget,
    pub delivery: Option<String>,
}

impl TryFrom<AppStartReviewRequest> for upstream::ReviewStartParams {
    type Error = RpcClientError;

    fn try_from(value: AppStartReviewRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            thread_id: value.thread_id,
            target: review_target_into_upstream(value.target),
            delivery: review_delivery_into_upstream(value.delivery)?,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type")]
#[derive(uniffi::Enum)]
pub enum AppLoginAccountRequest {
    #[serde(rename = "apiKey")]
    #[serde(rename_all = "camelCase")]
    ApiKey {
        #[serde(rename = "apiKey")]
        api_key: String,
    },
    #[serde(rename = "chatgpt")]
    Chatgpt,
    #[serde(rename = "chatgptAuthTokens")]
    #[serde(rename_all = "camelCase")]
    ChatgptAuthTokens {
        access_token: String,
        chatgpt_account_id: String,
        chatgpt_plan_type: Option<String>,
    },
}

impl From<AppLoginAccountRequest> for upstream::LoginAccountParams {
    fn from(value: AppLoginAccountRequest) -> Self {
        match value {
            AppLoginAccountRequest::ApiKey { api_key } => Self::ApiKey { api_key },
            AppLoginAccountRequest::Chatgpt => Self::Chatgpt {
                codex_streamlined_login: false,
            },
            AppLoginAccountRequest::ChatgptAuthTokens {
                access_token,
                chatgpt_account_id,
                chatgpt_plan_type,
            } => Self::ChatgptAuthTokens {
                access_token,
                chatgpt_account_id,
                chatgpt_plan_type,
            },
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppRefreshModelsRequest {
    #[uniffi(default = None)]
    pub cursor: Option<String>,
    #[uniffi(default = None)]
    pub limit: Option<u32>,
    #[uniffi(default = None)]
    pub include_hidden: Option<bool>,
}

impl From<AppRefreshModelsRequest> for upstream::ModelListParams {
    fn from(value: AppRefreshModelsRequest) -> Self {
        Self {
            cursor: value.cursor,
            limit: value.limit,
            include_hidden: value.include_hidden,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppListExperimentalFeaturesRequest {
    #[uniffi(default = None)]
    pub cursor: Option<String>,
    #[uniffi(default = None)]
    pub limit: Option<u32>,
}

impl From<AppListExperimentalFeaturesRequest> for upstream::ExperimentalFeatureListParams {
    fn from(value: AppListExperimentalFeaturesRequest) -> Self {
        Self {
            cursor: value.cursor,
            limit: value.limit,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AppRefreshAccountRequest {
    #[serde(default)]
    pub refresh_token: bool,
}

impl From<AppRefreshAccountRequest> for upstream::GetAccountParams {
    fn from(value: AppRefreshAccountRequest) -> Self {
        Self {
            refresh_token: value.refresh_token,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AuthStatusRequest {
    #[uniffi(default = None)]
    pub include_token: Option<bool>,
    #[uniffi(default = None)]
    pub refresh_token: Option<bool>,
}

impl From<AuthStatusRequest> for upstream::GetAuthStatusParams {
    fn from(value: AuthStatusRequest) -> Self {
        Self {
            include_token: value.include_token,
            refresh_token: value.refresh_token,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppSearchFilesRequest {
    pub query: String,
    pub roots: Vec<String>,
    pub cancellation_token: Option<String>,
}

impl From<AppSearchFilesRequest> for upstream::FuzzyFileSearchParams {
    fn from(value: AppSearchFilesRequest) -> Self {
        Self {
            query: value.query,
            roots: value.roots,
            cancellation_token: value.cancellation_token,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppExecCommandRequest {
    pub command: Vec<String>,
    pub process_id: Option<String>,
    pub tty: bool,
    pub stream_stdin: bool,
    pub stream_stdout_stderr: bool,
    pub output_bytes_cap: Option<u64>,
    pub disable_output_cap: bool,
    pub disable_timeout: bool,
    pub timeout_ms: Option<i64>,
    pub cwd: Option<String>,
    pub sandbox_policy: Option<AppSandboxPolicy>,
}

impl TryFrom<AppExecCommandRequest> for upstream::CommandExecParams {
    type Error = RpcClientError;

    fn try_from(value: AppExecCommandRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            command: value.command,
            process_id: value.process_id,
            tty: value.tty,
            stream_stdin: value.stream_stdin,
            stream_stdout_stderr: value.stream_stdout_stderr,
            output_bytes_cap: value
                .output_bytes_cap
                .map(|cap| {
                    usize::try_from(cap).map_err(|error| {
                        RpcClientError::Serialization(format!(
                            "output_bytes_cap out of range: {error}"
                        ))
                    })
                })
                .transpose()?,
            disable_output_cap: value.disable_output_cap,
            disable_timeout: value.disable_timeout,
            timeout_ms: value.timeout_ms,
            cwd: value.cwd.map(PathBuf::from),
            env: None,
            size: None,
            sandbox_policy: value
                .sandbox_policy
                .map(sandbox_policy_into_upstream)
                .transpose()?,
            permission_profile: None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppWriteConfigValueRequest {
    pub key_path: String,
    /// JSON-encoded value string.
    pub value_json: String,
    pub merge_strategy: AppMergeStrategy,
    pub file_path: Option<String>,
    pub expected_version: Option<String>,
}

impl TryFrom<AppWriteConfigValueRequest> for upstream::ConfigValueWriteParams {
    type Error = RpcClientError;

    fn try_from(value: AppWriteConfigValueRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            key_path: value.key_path,
            value: serde_json::from_str(&value.value_json)
                .map_err(|e| RpcClientError::Serialization(format!("invalid JSON value: {e}")))?,
            merge_strategy: merge_strategy_into_upstream(value.merge_strategy),
            file_path: value.file_path,
            expected_version: value.expected_version,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::enums::ApprovalKind;

    #[test]
    fn pending_approval_roundtrip() {
        let approval = PendingApproval {
            id: "42".to_string(),
            server_id: "srv_1".to_string(),
            kind: ApprovalKind::Command,
            thread_id: Some("thr_123".to_string()),
            turn_id: Some("turn_456".to_string()),
            item_id: Some("item_789".to_string()),
            command: Some("rm -rf /tmp/test".to_string()),
            path: None,
            grant_root: None,
            cwd: Some("/home/user".to_string()),
            reason: Some("Command needs approval".to_string()),
        };
        let json = serde_json::to_string(&approval).unwrap();
        let deserialized: PendingApproval = serde_json::from_str(&json).unwrap();
        assert_eq!(approval, deserialized);
    }

    #[test]
    fn pending_approval_file_change() {
        let approval = PendingApproval {
            id: "req-abc".to_string(),
            server_id: "srv_1".to_string(),
            kind: ApprovalKind::FileChange,
            thread_id: Some("thr_123".to_string()),
            turn_id: Some("turn_456".to_string()),
            item_id: Some("item_789".to_string()),
            command: None,
            path: Some("/home/user/main.rs".to_string()),
            grant_root: Some("/home/user".to_string()),
            cwd: None,
            reason: Some("File modification requested".to_string()),
        };
        let json = serde_json::to_string(&approval).unwrap();
        let deserialized: PendingApproval = serde_json::from_str(&json).unwrap();
        assert_eq!(approval, deserialized);
    }

    #[test]
    fn pending_approval_minimal() {
        let approval = PendingApproval {
            id: "1".to_string(),
            server_id: "srv_1".to_string(),
            kind: ApprovalKind::Permissions,
            thread_id: None,
            turn_id: None,
            item_id: None,
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        };
        let json = serde_json::to_value(&approval).unwrap();
        assert_eq!(json["id"], "1");
        assert!(json["threadId"].is_null());
    }

    #[test]
    fn resume_request_forwards_exclude_turns() {
        let request = AppResumeThreadRequest {
            thread_id: "t1".to_string(),
            model: None,
            cwd: None,
            approval_policy: None,
            sandbox: None,
            developer_instructions: None,
            persist_extended_history: false,
            exclude_turns: true,
        };
        let upstream_params: upstream::ThreadResumeParams = request.try_into().unwrap();
        assert!(upstream_params.exclude_turns);
    }

    #[test]
    fn resume_request_exclude_turns_default_false() {
        let request = AppResumeThreadRequest {
            thread_id: "t1".to_string(),
            model: None,
            cwd: None,
            approval_policy: None,
            sandbox: None,
            developer_instructions: None,
            persist_extended_history: false,
            exclude_turns: false,
        };
        let upstream_params: upstream::ThreadResumeParams = request.try_into().unwrap();
        assert!(!upstream_params.exclude_turns);
    }

    #[test]
    fn fork_request_forwards_exclude_turns() {
        let request = AppForkThreadRequest {
            thread_id: "t1".to_string(),
            model: None,
            cwd: None,
            approval_policy: None,
            sandbox: None,
            developer_instructions: None,
            persist_extended_history: false,
            exclude_turns: true,
        };
        let upstream_params: upstream::ThreadForkParams = request.try_into().unwrap();
        assert!(upstream_params.exclude_turns);
    }
}
