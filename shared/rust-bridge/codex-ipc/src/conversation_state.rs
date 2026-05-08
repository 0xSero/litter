use std::path::{Path, PathBuf};

use codex_app_server_protocol as upstream;
use serde::{Deserialize, de::DeserializeOwned};
use serde_json::Value;
use thiserror::Error;

use crate::protocol::params::{
    ImmerOp, ImmerPatch, ImmerPathSegment, StreamChange, ThreadStreamStateChangedParams,
};

const MY_REQUEST_HEADER: &str = "## My request for Codex:";
const COMMAND_APPROVAL_METHOD: &str = "item/commandExecution/requestApproval";
const FILE_CHANGE_APPROVAL_METHOD: &str = "item/fileChange/requestApproval";
const PERMISSIONS_APPROVAL_METHOD: &str = "item/permissions/requestApproval";
const USER_INPUT_METHOD: &str = "item/tool/requestUserInput";

#[derive(Debug, Clone, PartialEq)]
pub struct ProjectedConversationState {
    pub thread: upstream::Thread,
    pub latest_model: Option<String>,
    pub latest_reasoning_effort: Option<String>,
    pub active_turn_id: Option<String>,
    pub pending_approvals: Vec<ProjectedApprovalRequest>,
    pub pending_user_inputs: Vec<ProjectedUserInputRequest>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedConversationRequestState {
    pub pending_approvals: Vec<ProjectedApprovalRequest>,
    pub pending_user_inputs: Vec<ProjectedUserInputRequest>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectedApprovalKind {
    Command,
    FileChange,
    Permissions,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedApprovalRequest {
    pub id: String,
    pub kind: ProjectedApprovalKind,
    pub method: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub item_id: Option<String>,
    pub command: Option<String>,
    pub path: Option<String>,
    pub grant_root: Option<String>,
    pub cwd: Option<String>,
    pub reason: Option<String>,
    pub raw_params: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedUserInputOption {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedUserInputQuestion {
    pub id: String,
    pub header: Option<String>,
    pub question: String,
    pub is_other_allowed: bool,
    pub is_secret: bool,
    pub options: Vec<ProjectedUserInputOption>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedUserInputRequest {
    pub id: String,
    pub thread_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub questions: Vec<ProjectedUserInputQuestion>,
    pub requester_agent_nickname: Option<String>,
    pub requester_agent_role: Option<String>,
}

#[derive(Debug, Error)]
pub enum ConversationProjectionError {
    #[error("deserialize desktop conversation state: {0}")]
    ConversationState(#[source] serde_json::Error),
    #[error("deserialize desktop turn item '{item_type}': {source}")]
    TurnItem {
        item_type: String,
        #[source]
        source: serde_json::Error,
    },
}

#[derive(Debug, Error)]
pub enum ConversationStreamPatchError {
    #[error("path segment {segment:?} not found")]
    PathNotFound { segment: String },
    #[error("array index {index} out of bounds (len={len})")]
    IndexOutOfBounds { index: usize, len: usize },
    #[error("expected object or array, got {kind}")]
    UnexpectedType { kind: &'static str },
    #[error("add/replace operation missing value")]
    MissingValue,
}

#[derive(Debug, Error)]
pub enum ConversationStreamApplyError {
    #[error("no cached state")]
    NoCachedState,
    #[error("patch apply failed: {0}")]
    PatchFailed(#[from] ConversationStreamPatchError),
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopConversationState {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    rollout_path: Option<String>,
    #[serde(default)]
    source: Option<upstream::SessionSource>,
    #[serde(default)]
    git_info: Option<upstream::GitInfo>,
    #[serde(default)]
    turns: Vec<DesktopTurn>,
    #[serde(default)]
    created_at: Option<Value>,
    #[serde(default)]
    updated_at: Option<Value>,
    #[serde(default)]
    thread_runtime_status: Option<upstream::ThreadStatus>,
    #[serde(default)]
    resume_state: Option<String>,
    #[serde(default)]
    ephemeral: Option<bool>,
    #[serde(default)]
    model_provider: Option<String>,
    #[serde(default)]
    latest_model: Option<String>,
    #[serde(default)]
    latest_reasoning_effort: Option<String>,
    #[serde(default)]
    cli_version: Option<String>,
    #[serde(default)]
    agent_nickname: Option<String>,
    #[serde(default)]
    agent_role: Option<String>,
    #[serde(default)]
    requests: Vec<DesktopPendingRequest>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopConversationRequestState {
    #[serde(default)]
    agent_nickname: Option<String>,
    #[serde(default)]
    agent_role: Option<String>,
    #[serde(default)]
    requests: Vec<DesktopPendingRequest>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopTurn {
    #[serde(default)]
    turn_id: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    error: Option<upstream::TurnError>,
    #[serde(default)]
    items: Vec<Value>,
    #[serde(default)]
    params: DesktopTurnParams,
    #[serde(default)]
    interrupted_command_execution_item_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopTurnParams {
    #[serde(default)]
    input: Vec<upstream::UserInput>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopPendingRequest {
    #[serde(default)]
    id: Value,
    #[serde(default)]
    method: String,
    #[serde(default)]
    params: Value,
    #[serde(default)]
    completed: Option<bool>,
}

impl ThreadStreamStateChangedParams {
    pub fn project_snapshot_state(
        &self,
    ) -> Result<Option<ProjectedConversationState>, ConversationProjectionError> {
        match &self.change {
            StreamChange::Snapshot { conversation_state } => Ok(Some(project_conversation_state(
                &self.conversation_id,
                conversation_state,
            )?)),
            StreamChange::Patches { .. } => Ok(None),
        }
    }

    pub fn project_snapshot_thread(
        &self,
    ) -> Result<Option<upstream::Thread>, ConversationProjectionError> {
        Ok(self
            .project_snapshot_state()?
            .map(|projection| projection.thread))
    }
}

pub fn project_conversation_state_to_thread(
    conversation_id: &str,
    conversation_state: &Value,
) -> Result<upstream::Thread, ConversationProjectionError> {
    Ok(project_conversation_state(conversation_id, conversation_state)?.thread)
}

pub fn project_conversation_state(
    conversation_id: &str,
    conversation_state: &Value,
) -> Result<ProjectedConversationState, ConversationProjectionError> {
    let conversation: DesktopConversationState = deserialize_json_value(conversation_state)
        .map_err(ConversationProjectionError::ConversationState)?;

    let turns = conversation
        .turns
        .iter()
        .enumerate()
        .map(|(turn_index, turn)| project_turn(turn, turn_index))
        .collect::<Result<Vec<_>, _>>()?;
    let pending_approvals = project_pending_approvals(&conversation.requests);
    let pending_user_inputs = project_pending_user_inputs(
        &conversation.requests,
        conversation.agent_nickname.clone(),
        conversation.agent_role.clone(),
    );
    let active_flags = derive_active_flags(&pending_approvals, &pending_user_inputs);
    let active_turn_id = active_turn_id(&conversation.turns);
    let status = resolve_thread_status(&conversation, active_flags);
    let path = conversation
        .rollout_path
        .as_deref()
        .and_then(non_empty)
        .map(PathBuf::from);
    let cwd_path = PathBuf::from(infer_cwd(&conversation));
    let cwd = codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path(&cwd_path)
        .or_else(|_| codex_utils_absolute_path::AbsolutePathBuf::relative_to_current_dir(&cwd_path))
        .unwrap_or_else(|_| {
            codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path(
                &std::path::PathBuf::from("/"),
            )
            .expect("root is absolute")
        });

    let thread = upstream::Thread {
        id: conversation_id.to_string(),
        session_id: conversation_id.to_string(),
        forked_from_id: None,
        preview: thread_preview(&turns).unwrap_or_default(),
        ephemeral: conversation.ephemeral.unwrap_or(false),
        model_provider: conversation.model_provider.unwrap_or_default(),
        created_at: conversation
            .created_at
            .as_ref()
            .and_then(parse_unix_seconds)
            .unwrap_or_default(),
        updated_at: conversation
            .updated_at
            .as_ref()
            .and_then(parse_unix_seconds)
            .unwrap_or_default(),
        status,
        path,
        cwd,
        cli_version: conversation.cli_version.unwrap_or_default(),
        source: conversation.source.unwrap_or_default(),
        thread_source: None,
        agent_nickname: conversation.agent_nickname.and_then(non_empty_option_owned),
        agent_role: conversation.agent_role.and_then(non_empty_option_owned),
        git_info: conversation.git_info,
        name: conversation.title.and_then(non_empty_option_owned),
        turns,
    };

    Ok(ProjectedConversationState {
        thread,
        latest_model: conversation.latest_model.and_then(non_empty_option_owned),
        latest_reasoning_effort: conversation
            .latest_reasoning_effort
            .and_then(non_empty_option_owned),
        active_turn_id,
        pending_approvals,
        pending_user_inputs,
    })
}

pub fn project_conversation_request_state(
    conversation_state: &Value,
) -> Result<ProjectedConversationRequestState, ConversationProjectionError> {
    let conversation: DesktopConversationRequestState = deserialize_json_value(conversation_state)
        .map_err(ConversationProjectionError::ConversationState)?;

    Ok(ProjectedConversationRequestState {
        pending_approvals: project_pending_approvals(&conversation.requests),
        pending_user_inputs: project_pending_user_inputs(
            &conversation.requests,
            conversation.agent_nickname,
            conversation.agent_role,
        ),
    })
}

pub fn project_conversation_turn(
    raw_turn: &Value,
    turn_index: usize,
) -> Result<upstream::Turn, ConversationProjectionError> {
    let turn: DesktopTurn =
        deserialize_json_value(raw_turn).map_err(ConversationProjectionError::ConversationState)?;
    project_turn(&turn, turn_index)
}

pub fn seed_conversation_state_from_thread(thread: &upstream::Thread) -> Value {
    serde_json::json!({
        "title": thread.name.clone(),
        "cwd": path_to_string(thread.cwd.to_path_buf()),
        "rolloutPath": thread.path.clone().map(path_to_string),
        "source": thread.source.clone(),
        "gitInfo": thread.git_info.clone(),
        "turns": thread
            .turns
            .iter()
            .map(seed_desktop_turn_from_thread)
            .collect::<Vec<_>>(),
        "createdAt": thread.created_at,
        "updatedAt": thread.updated_at,
        "threadRuntimeStatus": thread.status.clone(),
        "ephemeral": thread.ephemeral,
        "modelProvider": thread.model_provider.clone(),
        "cliVersion": thread.cli_version.clone(),
        "agentNickname": thread.agent_nickname.clone(),
        "agentRole": thread.agent_role.clone(),
        "requests": [],
    })
}

pub fn apply_stream_change_to_conversation_state(
    cached_state: &mut Option<Value>,
    params: &ThreadStreamStateChangedParams,
) -> Result<(), ConversationStreamApplyError> {
    // Desktop currently sends the IPC method/schema version here, not a
    // monotonic per-thread stream revision, so ordering recovery has to rely
    // on whether a snapshot exists and whether the patch still applies cleanly.
    match &params.change {
        StreamChange::Snapshot { conversation_state } => {
            *cached_state = Some(conversation_state.clone());
            Ok(())
        }
        StreamChange::Patches { patches } => {
            let Some(cached_json) = cached_state.as_mut() else {
                return Err(ConversationStreamApplyError::NoCachedState);
            };

            apply_immer_patches(cached_json, patches)?;
            Ok(())
        }
    }
}

fn project_turn(
    turn: &DesktopTurn,
    turn_index: usize,
) -> Result<upstream::Turn, ConversationProjectionError> {
    let turn_id = turn
        .turn_id
        .clone()
        .unwrap_or_else(|| format!("ipc-turn-{turn_index}"));
    let mut items = Vec::new();

    if !turn.params.input.is_empty() {
        items.push(upstream::ThreadItem::UserMessage {
            id: format!("{turn_id}:input"),
            content: turn.params.input.clone(),
        });
    }

    for raw_item in &turn.items {
        let Some(item_type) = raw_item.get("type").and_then(Value::as_str) else {
            continue;
        };

        if !is_supported_turn_item(item_type) {
            continue;
        }

        let item = if item_type == "commandExecution" {
            let mut normalized_item = raw_item.clone();
            normalize_command_execution_status(
                &mut normalized_item,
                turn.status.as_deref(),
                &turn.interrupted_command_execution_item_ids,
            );
            deserialize_json_value::<upstream::ThreadItem>(&normalized_item)
        } else {
            deserialize_json_value::<upstream::ThreadItem>(raw_item)
        }
        .map_err(|source| ConversationProjectionError::TurnItem {
            item_type: item_type.to_string(),
            source,
        })?;

        if let upstream::ThreadItem::UserMessage { content, .. } = &item {
            if *content == turn.params.input {
                continue;
            }
        }

        items.push(item);
    }

    Ok(upstream::Turn {
        id: turn_id,
        items,
        items_view: upstream::TurnItemsView::Full,
        status: parse_turn_status(turn.status.as_deref()),
        error: turn.error.clone(),
        started_at: None,
        completed_at: None,
        duration_ms: None,
    })
}

fn normalize_command_execution_status(
    raw_item: &mut Value,
    turn_status: Option<&str>,
    interrupted_item_ids: &[String],
) {
    let is_interrupted_turn = matches!(turn_status, Some("interrupted"));
    let item_id = raw_item.get("id").and_then(Value::as_str);
    let is_interrupted_item = item_id
        .map(|item_id| interrupted_item_ids.iter().any(|id| id == item_id))
        .unwrap_or(false);

    if !(is_interrupted_turn || is_interrupted_item) {
        return;
    }

    if raw_item.get("status").and_then(Value::as_str) == Some("inProgress") {
        raw_item["status"] = Value::String("failed".to_string());
    }
}

fn seed_desktop_turn_from_thread(turn: &upstream::Turn) -> Value {
    let (params_input, item_offset) = match turn.items.first() {
        Some(upstream::ThreadItem::UserMessage { content, .. }) => (content.clone(), 1),
        _ => (Vec::new(), 0),
    };

    let items = turn
        .items
        .iter()
        .skip(item_offset)
        .filter(|item| is_supported_thread_item(item))
        .filter_map(|item| serde_json::to_value(item).ok())
        .collect::<Vec<_>>();

    serde_json::json!({
        "turnId": turn.id.clone(),
        "status": serialize_turn_status(turn.status.clone()),
        "error": turn.error.clone(),
        "items": items,
        "params": { "input": params_input },
        "interruptedCommandExecutionItemIds": [],
    })
}

fn is_supported_turn_item(item_type: &str) -> bool {
    matches!(
        item_type,
        "userMessage"
            | "hookPrompt"
            | "agentMessage"
            | "plan"
            | "reasoning"
            | "commandExecution"
            | "fileChange"
            | "mcpToolCall"
            | "dynamicToolCall"
            | "collabAgentToolCall"
            | "webSearch"
            | "imageView"
            | "imageGeneration"
            | "enteredReviewMode"
            | "exitedReviewMode"
            | "contextCompaction"
    )
}

fn is_supported_thread_item(item: &upstream::ThreadItem) -> bool {
    matches!(
        item,
        upstream::ThreadItem::UserMessage { .. }
            | upstream::ThreadItem::HookPrompt { .. }
            | upstream::ThreadItem::AgentMessage { .. }
            | upstream::ThreadItem::Plan { .. }
            | upstream::ThreadItem::Reasoning { .. }
            | upstream::ThreadItem::CommandExecution { .. }
            | upstream::ThreadItem::FileChange { .. }
            | upstream::ThreadItem::McpToolCall { .. }
            | upstream::ThreadItem::DynamicToolCall { .. }
            | upstream::ThreadItem::CollabAgentToolCall { .. }
            | upstream::ThreadItem::WebSearch { .. }
            | upstream::ThreadItem::ImageView { .. }
            | upstream::ThreadItem::ImageGeneration { .. }
            | upstream::ThreadItem::EnteredReviewMode { .. }
            | upstream::ThreadItem::ExitedReviewMode { .. }
            | upstream::ThreadItem::ContextCompaction { .. }
    )
}

fn project_pending_approvals(requests: &[DesktopPendingRequest]) -> Vec<ProjectedApprovalRequest> {
    requests
        .iter()
        .filter(|request| !request.completed.unwrap_or(false))
        .filter_map(|request| match request.method.as_str() {
            COMMAND_APPROVAL_METHOD => {
                let request_id = request_id_string(&request.id)?;
                let params = deserialize_json_value::<
                    upstream::CommandExecutionRequestApprovalParams,
                >(&request.params)
                .ok()?;
                Some(ProjectedApprovalRequest {
                    id: request_id,
                    kind: ProjectedApprovalKind::Command,
                    method: request.method.clone(),
                    thread_id: Some(params.thread_id),
                    turn_id: Some(params.turn_id),
                    item_id: Some(params.item_id),
                    command: params.command,
                    path: None,
                    grant_root: None,
                    cwd: params.cwd.map(|c| path_to_string(c.to_path_buf())),
                    reason: params.reason,
                    raw_params: request.params.clone(),
                })
            }
            FILE_CHANGE_APPROVAL_METHOD => {
                let request_id = request_id_string(&request.id)?;
                let params = deserialize_json_value::<upstream::FileChangeRequestApprovalParams>(
                    &request.params,
                )
                .ok()?;
                Some(ProjectedApprovalRequest {
                    id: request_id,
                    kind: ProjectedApprovalKind::FileChange,
                    method: request.method.clone(),
                    thread_id: Some(params.thread_id),
                    turn_id: Some(params.turn_id),
                    item_id: Some(params.item_id),
                    command: None,
                    path: None,
                    grant_root: params.grant_root.map(path_to_string),
                    cwd: None,
                    reason: params.reason,
                    raw_params: request.params.clone(),
                })
            }
            PERMISSIONS_APPROVAL_METHOD => {
                let request_id = request_id_string(&request.id)?;
                let params = deserialize_json_value::<upstream::PermissionsRequestApprovalParams>(
                    &request.params,
                )
                .ok()?;
                Some(ProjectedApprovalRequest {
                    id: request_id,
                    kind: ProjectedApprovalKind::Permissions,
                    method: request.method.clone(),
                    thread_id: Some(params.thread_id),
                    turn_id: Some(params.turn_id),
                    item_id: Some(params.item_id),
                    command: None,
                    path: None,
                    grant_root: None,
                    cwd: None,
                    reason: params.reason,
                    raw_params: request.params.clone(),
                })
            }
            _ => None,
        })
        .collect()
}

fn project_pending_user_inputs(
    requests: &[DesktopPendingRequest],
    requester_agent_nickname: Option<String>,
    requester_agent_role: Option<String>,
) -> Vec<ProjectedUserInputRequest> {
    let requester_agent_nickname = requester_agent_nickname.and_then(non_empty_option_owned);
    let requester_agent_role = requester_agent_role.and_then(non_empty_option_owned);

    requests
        .iter()
        .filter(|request| !request.completed.unwrap_or(false))
        .filter(|request| request.method == USER_INPUT_METHOD)
        .filter_map(|request| {
            let request_id = request_id_string(&request.id)?;
            let params =
                deserialize_json_value::<upstream::ToolRequestUserInputParams>(&request.params)
                    .ok()?;
            let questions = params
                .questions
                .into_iter()
                .map(|question| ProjectedUserInputQuestion {
                    id: question.id,
                    header: non_empty(question.header.as_str()).map(ToOwned::to_owned),
                    question: question.question,
                    is_other_allowed: question.is_other,
                    is_secret: question.is_secret,
                    options: question
                        .options
                        .unwrap_or_default()
                        .into_iter()
                        .map(|option| ProjectedUserInputOption {
                            label: option.label,
                            description: non_empty(option.description.as_str())
                                .map(ToOwned::to_owned),
                        })
                        .collect(),
                })
                .collect::<Vec<_>>();
            if questions.is_empty() {
                return None;
            }
            Some(ProjectedUserInputRequest {
                id: request_id,
                thread_id: params.thread_id,
                turn_id: params.turn_id,
                item_id: params.item_id,
                questions,
                requester_agent_nickname: requester_agent_nickname.clone(),
                requester_agent_role: requester_agent_role.clone(),
            })
        })
        .collect()
}

fn deserialize_json_value<T>(value: &Value) -> Result<T, serde_json::Error>
where
    T: DeserializeOwned,
{
    T::deserialize(value)
}

fn resolve_thread_status(
    conversation: &DesktopConversationState,
    derived_active_flags: Vec<upstream::ThreadActiveFlag>,
) -> upstream::ThreadStatus {
    match conversation.thread_runtime_status.clone() {
        Some(upstream::ThreadStatus::Active { active_flags }) => upstream::ThreadStatus::Active {
            active_flags: merge_active_flags(active_flags, derived_active_flags),
        },
        Some(status) => status,
        None => derive_thread_status(conversation, derived_active_flags),
    }
}

fn derive_thread_status(
    conversation: &DesktopConversationState,
    active_flags: Vec<upstream::ThreadActiveFlag>,
) -> upstream::ThreadStatus {
    if conversation.resume_state.as_deref() == Some("needs_resume") && conversation.turns.is_empty()
    {
        return upstream::ThreadStatus::NotLoaded;
    }

    if active_turn_id(&conversation.turns).is_some() || !active_flags.is_empty() {
        return upstream::ThreadStatus::Active { active_flags };
    }

    if conversation
        .turns
        .iter()
        .rev()
        .any(|turn| matches!(turn.status.as_deref(), Some("failed")))
    {
        return upstream::ThreadStatus::SystemError;
    }

    upstream::ThreadStatus::Idle
}

fn derive_active_flags(
    pending_approvals: &[ProjectedApprovalRequest],
    pending_user_inputs: &[ProjectedUserInputRequest],
) -> Vec<upstream::ThreadActiveFlag> {
    let mut flags = Vec::new();
    if !pending_approvals.is_empty() {
        flags.push(upstream::ThreadActiveFlag::WaitingOnApproval);
    }
    if !pending_user_inputs.is_empty() {
        flags.push(upstream::ThreadActiveFlag::WaitingOnUserInput);
    }
    flags
}

fn merge_active_flags(
    existing: Vec<upstream::ThreadActiveFlag>,
    derived: Vec<upstream::ThreadActiveFlag>,
) -> Vec<upstream::ThreadActiveFlag> {
    let mut merged = existing;
    for flag in derived {
        if !merged.iter().any(|existing_flag| existing_flag == &flag) {
            merged.push(flag);
        }
    }
    merged
}

fn active_turn_id(turns: &[DesktopTurn]) -> Option<String> {
    turns
        .iter()
        .rev()
        .find(|turn| matches!(turn.status.as_deref(), Some("inProgress")))
        .and_then(|turn| turn.turn_id.clone())
}

fn thread_preview(turns: &[upstream::Turn]) -> Option<String> {
    turns.iter().find_map(|turn| {
        turn.items.iter().find_map(|item| match item {
            upstream::ThreadItem::UserMessage { content, .. } => render_preview_text(content),
            _ => None,
        })
    })
}

fn render_preview_text(content: &[upstream::UserInput]) -> Option<String> {
    let text = content
        .iter()
        .filter_map(|item| match item {
            upstream::UserInput::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
    let text = strip_request_wrapper(text.trim());
    if text.is_empty() { None } else { Some(text) }
}

fn strip_request_wrapper(text: &str) -> String {
    let mut parts = text.split(MY_REQUEST_HEADER);
    let had_wrapper = parts.next().is_some() && text.contains(MY_REQUEST_HEADER);
    let last = text.rsplit(MY_REQUEST_HEADER).next().unwrap_or(text);
    if !had_wrapper {
        text.trim().to_string()
    } else {
        last.trim().to_string()
    }
}

fn infer_cwd(conversation: &DesktopConversationState) -> String {
    if let Some(cwd) = conversation.cwd.as_deref().and_then(non_empty) {
        return cwd.to_string();
    }

    if let Some(path) = conversation.rollout_path.as_deref().and_then(non_empty) {
        if let Some(parent) = Path::new(path).parent() {
            return parent.to_string_lossy().to_string();
        }
    }

    String::new()
}

fn parse_turn_status(value: Option<&str>) -> upstream::TurnStatus {
    match value {
        Some("completed") => upstream::TurnStatus::Completed,
        Some("interrupted") => upstream::TurnStatus::Interrupted,
        Some("failed") => upstream::TurnStatus::Failed,
        Some("inProgress") => upstream::TurnStatus::InProgress,
        _ => upstream::TurnStatus::Completed,
    }
}

fn serialize_turn_status(status: upstream::TurnStatus) -> &'static str {
    match status {
        upstream::TurnStatus::Completed => "completed",
        upstream::TurnStatus::Interrupted => "interrupted",
        upstream::TurnStatus::Failed => "failed",
        upstream::TurnStatus::InProgress => "inProgress",
    }
}

fn parse_unix_seconds(value: &Value) -> Option<i64> {
    parse_timestamp(value).map(|timestamp| {
        if timestamp >= 1_000_000_000_000 {
            timestamp / 1000
        } else {
            timestamp
        }
    })
}

fn parse_timestamp(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|value| value as i64)),
        Value::String(text) => text
            .parse::<i64>()
            .ok()
            .or_else(|| text.parse::<f64>().ok().map(|value| value as i64)),
        _ => None,
    }
}

fn request_id_string(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn path_to_string(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

fn non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn non_empty_option_owned(value: String) -> Option<String> {
    non_empty(&value).map(ToOwned::to_owned)
}

fn apply_immer_patches(
    target: &mut Value,
    patches: &[ImmerPatch],
) -> Result<(), ConversationStreamPatchError> {
    for patch in patches {
        apply_one_immer_patch(target, patch)?;
    }
    Ok(())
}

fn apply_one_immer_patch(
    target: &mut Value,
    patch: &ImmerPatch,
) -> Result<(), ConversationStreamPatchError> {
    if patch.path.is_empty() {
        match patch.op {
            ImmerOp::Replace | ImmerOp::Add => {
                *target = patch
                    .value
                    .clone()
                    .ok_or(ConversationStreamPatchError::MissingValue)?;
            }
            ImmerOp::Remove => *target = Value::Null,
        }
        return Ok(());
    }

    let (parent_path, last_segment) = patch.path.split_at(patch.path.len() - 1);
    let parent = navigate_to_path(target, parent_path)?;
    let last = &last_segment[0];

    match patch.op {
        ImmerOp::Replace => {
            let value = patch
                .value
                .clone()
                .ok_or(ConversationStreamPatchError::MissingValue)?;
            set_path_value(parent, last, value)
        }
        ImmerOp::Add => {
            let value = patch
                .value
                .clone()
                .ok_or(ConversationStreamPatchError::MissingValue)?;
            add_path_value(parent, last, value)
        }
        ImmerOp::Remove => remove_path_value(parent, last),
    }
}

fn navigate_to_path<'a>(
    root: &'a mut Value,
    path: &[ImmerPathSegment],
) -> Result<&'a mut Value, ConversationStreamPatchError> {
    let mut current = root;
    for segment in path {
        let kind = value_kind(current);
        current = match segment {
            ImmerPathSegment::Key(key) => {
                let object = current
                    .as_object_mut()
                    .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
                object
                    .get_mut(key)
                    .ok_or_else(|| ConversationStreamPatchError::PathNotFound {
                        segment: key.clone(),
                    })?
            }
            ImmerPathSegment::Index(index) => {
                let array = current
                    .as_array_mut()
                    .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
                let len = array.len();
                array
                    .get_mut(*index)
                    .ok_or(ConversationStreamPatchError::IndexOutOfBounds { index: *index, len })?
            }
        };
    }
    Ok(current)
}

fn set_path_value(
    parent: &mut Value,
    segment: &ImmerPathSegment,
    value: Value,
) -> Result<(), ConversationStreamPatchError> {
    let kind = value_kind(parent);
    match segment {
        ImmerPathSegment::Key(key) => {
            let object = parent
                .as_object_mut()
                .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
            object.insert(key.clone(), value);
            Ok(())
        }
        ImmerPathSegment::Index(index) => {
            let array = parent
                .as_array_mut()
                .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
            let len = array.len();
            if *index >= len {
                return Err(ConversationStreamPatchError::IndexOutOfBounds { index: *index, len });
            }
            array[*index] = value;
            Ok(())
        }
    }
}

fn add_path_value(
    parent: &mut Value,
    segment: &ImmerPathSegment,
    value: Value,
) -> Result<(), ConversationStreamPatchError> {
    let kind = value_kind(parent);
    match segment {
        ImmerPathSegment::Key(key) => {
            let object = parent
                .as_object_mut()
                .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
            object.insert(key.clone(), value);
            Ok(())
        }
        ImmerPathSegment::Index(index) => {
            let array = parent
                .as_array_mut()
                .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
            let len = array.len();
            if *index > len {
                return Err(ConversationStreamPatchError::IndexOutOfBounds { index: *index, len });
            }
            array.insert(*index, value);
            Ok(())
        }
    }
}

fn remove_path_value(
    parent: &mut Value,
    segment: &ImmerPathSegment,
) -> Result<(), ConversationStreamPatchError> {
    let kind = value_kind(parent);
    match segment {
        ImmerPathSegment::Key(key) => {
            let object = parent
                .as_object_mut()
                .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
            object
                .remove(key)
                .ok_or_else(|| ConversationStreamPatchError::PathNotFound {
                    segment: key.clone(),
                })?;
            Ok(())
        }
        ImmerPathSegment::Index(index) => {
            let array = parent
                .as_array_mut()
                .ok_or(ConversationStreamPatchError::UnexpectedType { kind })?;
            let len = array.len();
            if *index >= len {
                return Err(ConversationStreamPatchError::IndexOutOfBounds { index: *index, len });
            }
            array.remove(*index);
            Ok(())
        }
    }
}

fn value_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use codex_app_server_protocol as upstream;
    use serde_json::json;

    use super::{
        ProjectedApprovalKind, apply_stream_change_to_conversation_state,
        project_conversation_request_state, project_conversation_state,
        project_conversation_state_to_thread, seed_conversation_state_from_thread,
    };
    use crate::protocol::params::{StreamChange, ThreadStreamStateChangedParams};

    #[test]
    fn projects_core_transcript_items_into_upstream_thread() {
        let conversation_state = json!({
            "title": "IPC Thread",
            "cwd": "/repo",
            "rolloutPath": "/repo/.codex/session.jsonl",
            "createdAt": 1710000000000i64,
            "updatedAt": 1710000005000i64,
            "threadRuntimeStatus": { "type": "active", "activeFlags": [] },
            "source": "vscode",
            "turns": [
                {
                    "turnId": "turn-1",
                    "status": "completed",
                    "params": {
                        "input": [
                            { "type": "text", "text": "## My request for Codex:\nshow me the logs", "textElements": [] }
                        ]
                    },
                    "items": [
                        {
                            "id": "user-1",
                            "type": "userMessage",
                            "content": [
                                { "type": "text", "text": "## My request for Codex:\nshow me the logs", "textElements": [] }
                            ]
                        },
                        { "id": "assistant-1", "type": "agentMessage", "text": "Here are the logs." },
                        { "id": "reason-1", "type": "reasoning", "summary": ["Thinking through it"], "content": ["Inspecting the stream state."] },
                        {
                            "id": "exec-1",
                            "type": "commandExecution",
                            "status": "completed",
                            "command": "ls",
                            "cwd": "/repo",
                            "source": "agent",
                            "commandActions": [
                                { "type": "unknown", "command": "ls" }
                            ],
                            "aggregatedOutput": "file.txt\n",
                            "exitCode": 0,
                            "durationMs": 42
                        },
                        {
                            "id": "mcp-1",
                            "type": "mcpToolCall",
                            "status": "completed",
                            "server": "search",
                            "tool": "query",
                            "arguments": { "q": "logs" },
                            "result": {
                                "content": [
                                    { "type": "text", "text": "found it" }
                                ],
                                "structuredContent": { "count": 1 }
                            }
                        },
                        { "id": "todo-1", "type": "todo-list", "plan": [] }
                    ]
                }
            ]
        });

        let thread =
            project_conversation_state_to_thread("conversation-1", &conversation_state).unwrap();

        assert_eq!(thread.id, "conversation-1");
        assert_eq!(thread.preview, "show me the logs");
        assert_eq!(thread.created_at, 1710000000);
        assert_eq!(thread.updated_at, 1710000005);
        assert_eq!(thread.cwd, PathBuf::from("/repo"));
        assert_eq!(
            thread.path,
            Some(PathBuf::from("/repo/.codex/session.jsonl"))
        );
        assert!(matches!(
            thread.status,
            upstream::ThreadStatus::Active { .. }
        ));
        assert_eq!(thread.turns.len(), 1);
        assert_eq!(thread.turns[0].items.len(), 5);
        assert!(matches!(
            &thread.turns[0].items[0],
            upstream::ThreadItem::UserMessage { .. }
        ));
        assert!(matches!(
            &thread.turns[0].items[1],
            upstream::ThreadItem::AgentMessage { .. }
        ));
        assert!(matches!(
            &thread.turns[0].items[2],
            upstream::ThreadItem::Reasoning { .. }
        ));
        assert!(matches!(
            &thread.turns[0].items[3],
            upstream::ThreadItem::CommandExecution { .. }
        ));
        assert!(matches!(
            &thread.turns[0].items[4],
            upstream::ThreadItem::McpToolCall { .. }
        ));
    }

    #[test]
    fn projects_request_state_and_active_turn_metadata() {
        let conversation_state = json!({
            "latestModel": "gpt-5.4",
            "latestReasoningEffort": "medium",
            "agentNickname": "Scout",
            "agentRole": "reviewer",
            "turns": [
                {
                    "turnId": "turn-1",
                    "status": "inProgress",
                    "params": {
                        "input": [
                            { "type": "text", "text": "hello", "textElements": [] }
                        ]
                    },
                    "items": [
                        { "id": "assistant-1", "type": "agentMessage", "text": "streaming..." }
                    ]
                }
            ],
            "requests": [
                {
                    "id": "approval-1",
                    "method": "item/commandExecution/requestApproval",
                    "params": {
                        "threadId": "conversation-1",
                        "turnId": "turn-1",
                        "itemId": "exec-1",
                        "command": "ls",
                        "cwd": "/repo",
                        "reason": "Need approval"
                    }
                },
                {
                    "id": "input-1",
                    "method": "item/tool/requestUserInput",
                    "params": {
                        "threadId": "conversation-1",
                        "turnId": "turn-1",
                        "itemId": "tool-1",
                        "questions": [
                            {
                                "id": "q1",
                                "header": "Env",
                                "question": "Pick one",
                                "isOther": false,
                                "options": [
                                    { "label": "Prod", "description": "Production" }
                                ]
                            }
                        ]
                    }
                }
            ]
        });

        let projected = project_conversation_state("conversation-1", &conversation_state).unwrap();

        assert_eq!(projected.latest_model.as_deref(), Some("gpt-5.4"));
        assert_eq!(projected.latest_reasoning_effort.as_deref(), Some("medium"));
        assert_eq!(projected.active_turn_id.as_deref(), Some("turn-1"));
        assert_eq!(projected.pending_approvals.len(), 1);
        assert_eq!(
            projected.pending_approvals[0].kind,
            ProjectedApprovalKind::Command
        );
        assert_eq!(projected.pending_user_inputs.len(), 1);
        assert_eq!(
            projected.pending_user_inputs[0]
                .requester_agent_nickname
                .as_deref(),
            Some("Scout")
        );
        assert_eq!(
            projected.pending_user_inputs[0]
                .requester_agent_role
                .as_deref(),
            Some("reviewer")
        );

        match projected.thread.status {
            upstream::ThreadStatus::Active { active_flags } => {
                assert!(active_flags.contains(&upstream::ThreadActiveFlag::WaitingOnApproval));
                assert!(active_flags.contains(&upstream::ThreadActiveFlag::WaitingOnUserInput));
            }
            other => panic!("expected active thread status, got {other:?}"),
        }
    }

    #[test]
    fn projects_snapshot_helper_and_derives_active_status_without_runtime_state() {
        let params = ThreadStreamStateChangedParams {
            conversation_id: "conversation-1".to_string(),
            change: StreamChange::Snapshot {
                conversation_state: json!({
                    "turns": [
                        {
                            "turnId": "turn-1",
                            "status": "inProgress",
                            "params": {
                                "input": [
                                    { "type": "text", "text": "hello", "textElements": [] }
                                ]
                            },
                            "items": [
                                {
                                    "id": "assistant-1",
                                    "type": "agentMessage",
                                    "text": "streaming..."
                                }
                            ]
                        }
                    ]
                }),
            },
            version: 5,
        };

        let projection = params.project_snapshot_state().unwrap().unwrap();
        assert!(matches!(
            projection.thread.status,
            upstream::ThreadStatus::Active { .. }
        ));
        assert_eq!(projection.thread.turns[0].id, "turn-1");
        assert_eq!(projection.thread.preview, "hello");
        assert_eq!(projection.active_turn_id.as_deref(), Some("turn-1"));
    }

    #[test]
    fn maps_interrupted_command_execution_to_failed_status() {
        let conversation_state = json!({
            "turns": [
                {
                    "turnId": "turn-1",
                    "status": "interrupted",
                    "interruptedCommandExecutionItemIds": ["exec-1"],
                    "items": [
                        {
                            "id": "exec-1",
                            "type": "commandExecution",
                            "status": "inProgress",
                            "command": "sleep 10",
                            "cwd": "/repo",
                            "source": "agent",
                            "commandActions": [
                                { "type": "unknown", "command": "sleep 10" }
                            ]
                        }
                    ]
                }
            ]
        });

        let thread =
            project_conversation_state_to_thread("conversation-1", &conversation_state).unwrap();

        match &thread.turns[0].items[0] {
            upstream::ThreadItem::CommandExecution { status, .. } => {
                assert_eq!(*status, upstream::CommandExecutionStatus::Failed);
            }
            other => panic!("expected command execution item, got {other:?}"),
        }
    }

    #[test]
    fn projects_request_state_pending_requests() {
        let conversation_state = json!({
            "agentNickname": "Scout",
            "agentRole": "reviewer",
            "requests": [
                {
                    "id": "req-1",
                    "method": "item/commandExecution/requestApproval",
                    "params": {
                        "threadId": "thread-1",
                        "turnId": "turn-1",
                        "itemId": "cmd-1",
                        "command": "git status",
                        "cwd": "/repo",
                        "reason": "Need approval"
                    }
                },
                {
                    "id": "req-2",
                    "method": "item/tool/requestUserInput",
                    "params": {
                        "threadId": "thread-1",
                        "turnId": "turn-2",
                        "itemId": "tool-1",
                        "questions": [
                            {
                                "id": "q-1",
                                "header": "Target",
                                "question": "Pick one",
                                "isOther": false,
                                "isSecret": false,
                                "options": [
                                    { "label": "Prod", "description": "Production" }
                                ]
                            }
                        ]
                    }
                }
            ]
        });

        let projected = project_conversation_request_state(&conversation_state).unwrap();

        assert_eq!(projected.pending_approvals.len(), 1);
        assert_eq!(projected.pending_approvals[0].id, "req-1");
        assert_eq!(
            projected.pending_approvals[0].raw_params,
            json!({
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "cmd-1",
                "command": "git status",
                "cwd": "/repo",
                "reason": "Need approval"
            })
        );

        assert_eq!(projected.pending_user_inputs.len(), 1);
        assert_eq!(projected.pending_user_inputs[0].id, "req-2");
        assert_eq!(
            projected.pending_user_inputs[0]
                .requester_agent_nickname
                .as_deref(),
            Some("Scout")
        );
        assert_eq!(
            projected.pending_user_inputs[0]
                .requester_agent_role
                .as_deref(),
            Some("reviewer")
        );
    }

    #[test]
    fn seeds_upstream_thread_into_patchable_conversation_state() {
        let thread = upstream::Thread {
            id: "conversation-1".to_string(),
            preview: "hello".to_string(),
            ephemeral: false,
            model_provider: "openai".to_string(),
            created_at: 1,
            updated_at: 2,
            status: upstream::ThreadStatus::Active {
                active_flags: Vec::new(),
            },
            path: Some(PathBuf::from("/repo/.codex/session.jsonl")),
            cwd: PathBuf::from("/repo"),
            cli_version: "1.0.0".to_string(),
            source: upstream::SessionSource::default(),
            agent_nickname: None,
            agent_role: None,
            git_info: None,
            name: Some("IPC Thread".to_string()),
            turns: vec![upstream::Turn {
                id: "turn-1".to_string(),
                status: upstream::TurnStatus::InProgress,
                error: None,
                items: vec![
                    upstream::ThreadItem::UserMessage {
                        id: "user-1".to_string(),
                        content: vec![upstream::UserInput::Text {
                            text: "hello".to_string(),
                            text_elements: Vec::new(),
                        }],
                    },
                    upstream::ThreadItem::AgentMessage {
                        id: "assistant-1".to_string(),
                        text: "hel".to_string(),
                        phase: None,
                        memory_citation: None,
                    },
                ],
            }],
        };

        let mut cached_state = Some(seed_conversation_state_from_thread(&thread));
        let seeded_state = cached_state.as_ref().unwrap();
        assert_eq!(
            seeded_state["turns"][0]["params"]["input"][0]["text"],
            "hello"
        );
        assert_eq!(seeded_state["turns"][0]["items"][0]["type"], "agentMessage");

        let text_patch = ThreadStreamStateChangedParams {
            conversation_id: "conversation-1".to_string(),
            version: 2,
            change: StreamChange::Patches {
                patches: vec![crate::protocol::params::ImmerPatch {
                    op: crate::protocol::params::ImmerOp::Replace,
                    path: vec![
                        crate::protocol::params::ImmerPathSegment::Key("turns".to_string()),
                        crate::protocol::params::ImmerPathSegment::Index(0),
                        crate::protocol::params::ImmerPathSegment::Key("items".to_string()),
                        crate::protocol::params::ImmerPathSegment::Index(0),
                        crate::protocol::params::ImmerPathSegment::Key("text".to_string()),
                    ],
                    value: Some(json!("hello")),
                }],
            },
        };
        apply_stream_change_to_conversation_state(&mut cached_state, &text_patch).unwrap();

        let projected =
            project_conversation_state("conversation-1", cached_state.as_ref().unwrap()).unwrap();
        assert_eq!(projected.active_turn_id.as_deref(), Some("turn-1"));
        match &projected.thread.turns[0].items[1] {
            upstream::ThreadItem::AgentMessage { text, .. } => assert_eq!(text, "hello"),
            other => panic!("expected agent message, got {other:?}"),
        }
    }

    #[test]
    fn applies_same_protocol_version_patch_bursts() {
        let thread = upstream::Thread {
            id: "thread-1".to_string(),
            preview: "hello".to_string(),
            ephemeral: false,
            model_provider: "openai".to_string(),
            created_at: 1,
            updated_at: 2,
            status: upstream::ThreadStatus::Active {
                active_flags: Vec::new(),
            },
            path: Some(PathBuf::from("/tmp/thread.jsonl")),
            cwd: PathBuf::from("/tmp"),
            cli_version: "1.0.0".to_string(),
            source: upstream::SessionSource::default(),
            agent_nickname: None,
            agent_role: None,
            git_info: None,
            name: Some("Thread".to_string()),
            turns: vec![upstream::Turn {
                id: "turn-1".to_string(),
                status: upstream::TurnStatus::InProgress,
                error: None,
                items: vec![
                    upstream::ThreadItem::UserMessage {
                        id: "user-1".to_string(),
                        content: vec![upstream::UserInput::Text {
                            text: "hello".to_string(),
                            text_elements: Vec::new(),
                        }],
                    },
                    upstream::ThreadItem::AgentMessage {
                        id: "assistant-1".to_string(),
                        text: "hel".to_string(),
                        phase: None,
                        memory_citation: None,
                    },
                ],
            }],
        };

        let mut cached_state = Some(seed_conversation_state_from_thread(&thread));
        let first_text_patch = ThreadStreamStateChangedParams {
            conversation_id: "conversation-1".to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![crate::protocol::params::ImmerPatch {
                    op: crate::protocol::params::ImmerOp::Replace,
                    path: vec![
                        crate::protocol::params::ImmerPathSegment::Key("turns".to_string()),
                        crate::protocol::params::ImmerPathSegment::Index(0),
                        crate::protocol::params::ImmerPathSegment::Key("items".to_string()),
                        crate::protocol::params::ImmerPathSegment::Index(0),
                        crate::protocol::params::ImmerPathSegment::Key("text".to_string()),
                    ],
                    value: Some(json!("hell")),
                }],
            },
        };
        let second_text_patch = ThreadStreamStateChangedParams {
            conversation_id: "conversation-1".to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![crate::protocol::params::ImmerPatch {
                    op: crate::protocol::params::ImmerOp::Replace,
                    path: vec![
                        crate::protocol::params::ImmerPathSegment::Key("turns".to_string()),
                        crate::protocol::params::ImmerPathSegment::Index(0),
                        crate::protocol::params::ImmerPathSegment::Key("items".to_string()),
                        crate::protocol::params::ImmerPathSegment::Index(0),
                        crate::protocol::params::ImmerPathSegment::Key("text".to_string()),
                    ],
                    value: Some(json!("hello")),
                }],
            },
        };

        apply_stream_change_to_conversation_state(&mut cached_state, &first_text_patch).unwrap();
        apply_stream_change_to_conversation_state(&mut cached_state, &second_text_patch).unwrap();

        let state = cached_state.expect("state after same-version patches");
        let projected = project_conversation_state("conversation-1", &state).unwrap();
        match &projected.thread.turns[0].items[1] {
            upstream::ThreadItem::AgentMessage { text, .. } => assert_eq!(text, "hello"),
            other => panic!("expected agent message, got {other:?}"),
        }
    }
}
