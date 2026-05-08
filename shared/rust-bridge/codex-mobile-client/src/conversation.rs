//! Conversation restoration / thread hydration.
//!
//! Converts upstream `Vec<Turn>` (from `thread/resume`, `thread/fork`, etc.)
//! into `Vec<HydratedConversationItem>` — a flat, UI-ready model that both
//! iOS and Android render directly via UniFFI.

use std::path::Path;
use std::path::PathBuf;

use crate::conversation_uniffi::*;
use crate::parser::{
    CodeReviewCodeLocation, CodeReviewFinding, CodeReviewLineRange, CodeReviewPayload,
    parse_code_review_message,
};
use crate::types::{AppMessagePhase, AppOperationStatus, AppSubagentStatus};
use base64::Engine;
use codex_app_server_protocol::{
    CollabAgentStatus, CollabAgentTool, CollabAgentToolCallStatus, CommandAction,
    CommandExecutionStatus, DynamicToolCallOutputContentItem, DynamicToolCallStatus,
    FileUpdateChange, McpToolCallResult, McpToolCallStatus, PatchApplyStatus, PatchChangeKind,
    ThreadItem, Turn, UserInput,
};
use codex_shell_command::parse_command::extract_shell_command;
use serde::Serialize;

const MOBILE_COMMAND_TEXT_CAP_BYTES: usize = 4 * 1024;
const MOBILE_COMMAND_OUTPUT_CAP_BYTES: usize = 128 * 1024;
const MOBILE_COMMAND_ACTION_FIELD_CAP_BYTES: usize = 1024;
const MOBILE_COMMAND_ACTION_COUNT_CAP: usize = 32;
const MOBILE_COMMAND_TEXT_TRUNCATION_SUFFIX: &str = "... [truncated on mobile]";
const MOBILE_COMMAND_OUTPUT_TRUNCATION_SUFFIX: &str = "\n[output truncated on mobile]\n";

// ---------------------------------------------------------------------------
// Conversion options
// ---------------------------------------------------------------------------

/// Optional metadata passed by the caller to enrich agent attribution.
#[derive(Debug, Clone, Default)]
pub struct HydrationOptions {
    pub default_agent_nickname: Option<String>,
    pub default_agent_role: Option<String>,
}

// ---------------------------------------------------------------------------
// Core conversion: Vec<Turn> -> Vec<HydratedConversationItem>
// ---------------------------------------------------------------------------

/// Convert a list of upstream [`Turn`] values into a flat list of
/// [`HydratedConversationItem`] suitable for UI rendering.
pub fn hydrate_turns(turns: &[Turn], opts: &HydrationOptions) -> Vec<HydratedConversationItem> {
    let mut items = Vec::with_capacity(turns.len() * 3);
    for (turn_index, turn) in turns.iter().enumerate() {
        for thread_item in &turn.items {
            if let Some(conv) =
                hydrate_thread_item(thread_item, Some(&turn.id), Some(turn_index), opts)
            {
                items.push(conv);
            }
        }
    }
    items
}

/// Convert a single upstream [`ThreadItem`] into a [`HydratedConversationItem`].
pub fn hydrate_thread_item(
    item: &ThreadItem,
    source_turn_id: Option<&str>,
    source_turn_index: Option<usize>,
    opts: &HydrationOptions,
) -> Option<HydratedConversationItem> {
    convert_thread_item(item, item.id(), source_turn_id, source_turn_index, opts)
}

fn hydrate_message_phase(
    phase: Option<codex_protocol::models::MessagePhase>,
) -> Option<AppMessagePhase> {
    phase.map(|phase| match phase {
        codex_protocol::models::MessagePhase::Commentary => AppMessagePhase::Commentary,
        codex_protocol::models::MessagePhase::FinalAnswer => AppMessagePhase::FinalAnswer,
    })
}

fn hydrate_code_review_line_range(range: &CodeReviewLineRange) -> HydratedCodeReviewLineRangeData {
    HydratedCodeReviewLineRangeData {
        start: range.start,
        end: range.end,
    }
}

fn hydrate_code_review_location(
    location: &CodeReviewCodeLocation,
) -> HydratedCodeReviewCodeLocationData {
    HydratedCodeReviewCodeLocationData {
        absolute_file_path: location.absolute_file_path.clone(),
        line_range: location
            .line_range
            .as_ref()
            .map(hydrate_code_review_line_range),
    }
}

fn hydrate_code_review_finding(finding: &CodeReviewFinding) -> HydratedCodeReviewFindingData {
    HydratedCodeReviewFindingData {
        title: finding.title.clone(),
        body: finding.body.clone(),
        confidence_score: finding.confidence_score,
        priority: finding.priority,
        code_location: finding
            .code_location
            .as_ref()
            .map(hydrate_code_review_location),
    }
}

fn hydrate_code_review_payload(review: &CodeReviewPayload) -> HydratedCodeReviewData {
    HydratedCodeReviewData {
        findings: review
            .findings
            .iter()
            .map(hydrate_code_review_finding)
            .collect(),
        overall_correctness: review.overall_correctness.clone(),
        overall_explanation: review.overall_explanation.clone(),
        overall_confidence_score: review.overall_confidence_score,
    }
}

fn display_command(command: &str) -> String {
    let trimmed = command.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let Some(argv) = shlex::split(trimmed) else {
        return trimmed.to_string();
    };

    if let Some((_, script)) = extract_shell_command(&argv) {
        return script.trim().to_string();
    }

    if let Some(script) = extract_cmd_command(&argv) {
        return script.trim().to_string();
    }

    trimmed.to_string()
}

fn truncate_text_bytes(value: &str, cap: usize, suffix: &str) -> String {
    if value.len() <= cap {
        return value.to_string();
    }

    let suffix_bytes = suffix.len().min(cap);
    let mut suffix_end = suffix_bytes;
    while suffix_end > 0 && !suffix.is_char_boundary(suffix_end) {
        suffix_end -= 1;
    }
    let suffix = &suffix[..suffix_end];

    let prefix_cap = cap.saturating_sub(suffix.len());
    let mut end = prefix_cap.min(value.len());
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }

    let mut truncated = String::with_capacity(end + suffix.len());
    truncated.push_str(&value[..end]);
    truncated.push_str(suffix);
    truncated
}

pub(crate) fn truncate_command_display_text(value: &str) -> String {
    truncate_text_bytes(
        value,
        MOBILE_COMMAND_TEXT_CAP_BYTES,
        MOBILE_COMMAND_TEXT_TRUNCATION_SUFFIX,
    )
}

pub(crate) fn truncate_command_output_text(value: &str) -> String {
    truncate_text_bytes(
        value,
        MOBILE_COMMAND_OUTPUT_CAP_BYTES,
        MOBILE_COMMAND_OUTPUT_TRUNCATION_SUFFIX,
    )
}

pub(crate) fn command_output_is_truncated(value: &str) -> bool {
    value.ends_with(MOBILE_COMMAND_OUTPUT_TRUNCATION_SUFFIX)
}

fn truncate_command_action_field(value: &str) -> String {
    truncate_text_bytes(
        value,
        MOBILE_COMMAND_ACTION_FIELD_CAP_BYTES,
        MOBILE_COMMAND_TEXT_TRUNCATION_SUFFIX,
    )
}

fn extract_cmd_command(command: &[String]) -> Option<&str> {
    let [shell, flag, script] = command else {
        return None;
    };

    if !flag.eq_ignore_ascii_case("/c") || !is_cmd_shell(shell) {
        return None;
    }

    Some(script.as_str())
}

fn is_cmd_shell(shell: &str) -> bool {
    Path::new(shell)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .is_some_and(|stem| stem.eq_ignore_ascii_case("cmd"))
}

fn convert_thread_item(
    item: &ThreadItem,
    item_id: &str,
    source_turn_id: Option<&str>,
    source_turn_index: Option<usize>,
    opts: &HydrationOptions,
) -> Option<HydratedConversationItem> {
    let (content, is_boundary) = match item {
        ThreadItem::UserMessage { content, .. } => {
            let (text, images) = render_user_input(content);
            if text.is_empty() && images.is_empty() {
                return None;
            }
            (
                HydratedConversationItemContent::User(HydratedUserMessageData {
                    text,
                    image_data_uris: images,
                }),
                true,
            )
        }
        ThreadItem::AgentMessage { text, phase, .. } => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            let content = if let Some(review) = parse_code_review_message(trimmed) {
                HydratedConversationItemContent::CodeReview(hydrate_code_review_payload(&review))
            } else {
                HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                    text: trimmed.to_string(),
                    agent_nickname: opts.default_agent_nickname.clone(),
                    agent_role: opts.default_agent_role.clone(),
                    phase: hydrate_message_phase(phase.clone()),
                })
            };
            (content, false)
        }
        ThreadItem::Plan { text, .. } => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            (
                HydratedConversationItemContent::ProposedPlan(HydratedProposedPlanData {
                    content: trimmed.to_string(),
                }),
                false,
            )
        }
        ThreadItem::Reasoning {
            summary, content, ..
        } => (
            HydratedConversationItemContent::Reasoning(HydratedReasoningData {
                summary: summary.clone(),
                content: content.clone(),
            }),
            false,
        ),
        ThreadItem::CommandExecution {
            command,
            cwd,
            status,
            command_actions,
            aggregated_output,
            exit_code,
            duration_ms,
            process_id,
            ..
        } => {
            let actions = command_actions
                .iter()
                .take(MOBILE_COMMAND_ACTION_COUNT_CAP)
                .map(convert_command_action)
                .collect();
            (
                HydratedConversationItemContent::CommandExecution(HydratedCommandExecutionData {
                    command: truncate_command_display_text(&display_command(command)),
                    cwd: truncate_command_action_field(&cwd.display().to_string()),
                    status: convert_command_status(status),
                    output: aggregated_output
                        .as_deref()
                        .map(truncate_command_output_text),
                    exit_code: *exit_code,
                    duration_ms: *duration_ms,
                    process_id: process_id.clone(),
                    actions,
                }),
                false,
            )
        }
        ThreadItem::FileChange {
            changes, status, ..
        } => (
            HydratedConversationItemContent::FileChange(HydratedFileChangeData {
                status: convert_patch_status(status),
                changes: changes.iter().map(convert_file_change).collect(),
            }),
            false,
        ),
        ThreadItem::McpToolCall {
            server,
            tool,
            status,
            arguments,
            result,
            error,
            duration_ms,
            ..
        } => {
            let raw_output_json = result.as_ref().and_then(|r| {
                let obj = serde_json::json!({
                    "content": r.content,
                    "structuredContent": r.structured_content,
                });
                pretty_json(&obj).map(|json| truncate_command_output_text(&json))
            });
            let content_summary = result.as_ref().map(|r| {
                let summary = r
                    .content
                    .iter()
                    .map(stringify_json_value)
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n");
                truncate_command_output_text(&summary)
            });
            let structured_json = result
                .as_ref()
                .and_then(|r| r.structured_content.as_ref())
                .and_then(pretty_json)
                .map(|json| truncate_command_output_text(&json));
            let computer_use = if server == "computer-use" {
                Some(build_computer_use_view(
                    tool,
                    arguments,
                    result.as_ref().map(|r| r.as_ref()),
                ))
            } else {
                None
            };
            (
                HydratedConversationItemContent::McpToolCall(HydratedMcpToolCallData {
                    server: server.clone(),
                    tool: tool.clone(),
                    status: convert_mcp_status(status),
                    duration_ms: *duration_ms,
                    arguments_json: pretty_json(arguments)
                        .map(|json| truncate_command_display_text(&json)),
                    content_summary,
                    structured_content_json: structured_json,
                    raw_output_json,
                    error_message: error.as_ref().map(|e| e.message.clone()),
                    progress_messages: Vec::new(),
                    computer_use,
                }),
                false,
            )
        }
        ThreadItem::DynamicToolCall {
            namespace,
            tool,
            arguments,
            status,
            content_items,
            success,
            duration_ms,
            ..
        } => {
            if let Some(widget) = widget_data_from_dynamic_tool_call(
                tool,
                arguments,
                status,
                content_items.as_deref(),
            ) {
                return Some(HydratedConversationItem {
                    id: item_id.to_string(),
                    content: HydratedConversationItemContent::Widget(widget),
                    source_turn_id: source_turn_id.map(String::from),
                    source_turn_index: source_turn_index.map(|i| i as u32),
                    timestamp: None,
                    is_from_user_turn_boundary: false,
                });
            }
            let content_summary = content_items.as_ref().map(|items| {
                let summary = items
                    .iter()
                    .map(|item| match item {
                        DynamicToolCallOutputContentItem::InputText { text } => text.clone(),
                        DynamicToolCallOutputContentItem::InputImage { image_url } => {
                            format!("[image: {}]", image_url)
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                truncate_command_output_text(&summary)
            });
            (
                HydratedConversationItemContent::DynamicToolCall(HydratedDynamicToolCallData {
                    tool: tool.clone(),
                    status: convert_dynamic_status(status),
                    duration_ms: *duration_ms,
                    success: *success,
                    namespace: namespace.clone(),
                    arguments_json: pretty_json(arguments)
                        .map(|json| truncate_command_display_text(&json)),
                    display: build_dynamic_tool_display(
                        namespace.as_deref(),
                        tool,
                        arguments,
                        content_summary.as_deref(),
                    ),
                    content_summary,
                }),
                false,
            )
        }
        ThreadItem::CollabAgentToolCall {
            tool,
            status,
            receiver_thread_ids,
            prompt,
            agents_states,
            ..
        } => {
            let targets: Vec<String> = receiver_thread_ids.clone();
            let mut states: Vec<HydratedMultiAgentStateData> = agents_states
                .iter()
                .map(|(key, value)| HydratedMultiAgentStateData {
                    target_id: key.clone(),
                    status: convert_collab_agent_status(&value.status),
                    message: value.message.clone(),
                })
                .collect();
            states.sort_by(|a, b| a.target_id.cmp(&b.target_id));
            (
                HydratedConversationItemContent::MultiAgentAction(HydratedMultiAgentActionData {
                    tool: convert_collab_tool(tool),
                    status: convert_collab_status(status),
                    prompt: prompt.clone(),
                    targets,
                    receiver_thread_ids: receiver_thread_ids.clone(),
                    agent_states: states,
                }),
                false,
            )
        }
        ThreadItem::WebSearch { query, action, .. } => {
            let action_json = action
                .as_ref()
                .and_then(|a| serde_json::to_value(a).ok().and_then(|v| pretty_json(&v)));
            (
                HydratedConversationItemContent::WebSearch(HydratedWebSearchData {
                    query: query.clone(),
                    action_json,
                    is_in_progress: false,
                }),
                false,
            )
        }
        ThreadItem::ImageView { path, .. } => (
            HydratedConversationItemContent::ImageView(HydratedImageViewData {
                path: path.to_string_lossy().into_owned(),
            }),
            false,
        ),
        ThreadItem::ImageGeneration {
            status,
            revised_prompt,
            result,
            saved_path,
            ..
        } => {
            let image_png = decode_image_generation_result(result);
            let saved_path_string = saved_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned());
            let normalized_status = convert_image_generation_status(
                status,
                image_png.is_some(),
                saved_path_string.as_deref(),
            );
            (
                HydratedConversationItemContent::ImageGeneration(HydratedImageGenerationData {
                    status: normalized_status,
                    revised_prompt: revised_prompt.clone(),
                    image_png,
                    saved_path: saved_path_string,
                }),
                false,
            )
        }
        ThreadItem::EnteredReviewMode { review, .. } => (
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewEntered {
                review: review.clone(),
            }),
            false,
        ),
        ThreadItem::ExitedReviewMode { review, .. } => (
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewExited {
                review: review.clone(),
            }),
            false,
        ),
        ThreadItem::ContextCompaction { .. } => (
            HydratedConversationItemContent::Divider(HydratedDividerData::ContextCompaction {
                is_complete: true,
            }),
            false,
        ),
        ThreadItem::HookPrompt { .. } => return None,
    };

    Some(HydratedConversationItem {
        id: item_id.to_string(),
        content,
        source_turn_id: source_turn_id.map(String::from),
        source_turn_index: source_turn_index.map(|i| i as u32),
        timestamp: None,
        is_from_user_turn_boundary: is_boundary,
    })
}

// ---------------------------------------------------------------------------
// Public helpers for live item construction
// ---------------------------------------------------------------------------

pub fn make_turn_diff_item(
    turn_id: &str,
    diff: String,
    source_turn_id: Option<&str>,
) -> HydratedConversationItem {
    HydratedConversationItem {
        id: format!("turn-diff-{turn_id}"),
        content: HydratedConversationItemContent::TurnDiff(HydratedTurnDiffData { diff }),
        source_turn_id: source_turn_id
            .map(String::from)
            .or_else(|| Some(turn_id.to_string())),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

pub fn make_model_rerouted_item(
    turn_id: &str,
    from_model: Option<String>,
    to_model: String,
    reason: Option<String>,
    source_turn_id: Option<&str>,
) -> HydratedConversationItem {
    HydratedConversationItem {
        id: format!("model-rerouted-{turn_id}"),
        content: HydratedConversationItemContent::Divider(HydratedDividerData::ModelRerouted {
            from_model,
            to_model,
            reason,
        }),
        source_turn_id: source_turn_id
            .map(String::from)
            .or_else(|| Some(turn_id.to_string())),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

pub fn make_error_item(id: String, message: String, code: Option<i64>) -> HydratedConversationItem {
    HydratedConversationItem {
        id,
        content: HydratedConversationItemContent::Error(HydratedErrorData {
            title: "Error".to_string(),
            message,
            details: code.map(|value| format!("Code: {value}")),
        }),
        source_turn_id: None,
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

// ---------------------------------------------------------------------------
// Upstream enum → typed enum conversions (no string round-trip)
// ---------------------------------------------------------------------------

fn convert_command_status(status: &CommandExecutionStatus) -> AppOperationStatus {
    match status {
        CommandExecutionStatus::InProgress => AppOperationStatus::InProgress,
        CommandExecutionStatus::Completed => AppOperationStatus::Completed,
        CommandExecutionStatus::Failed => AppOperationStatus::Failed,
        CommandExecutionStatus::Declined => AppOperationStatus::Declined,
    }
}

fn convert_patch_status(status: &PatchApplyStatus) -> AppOperationStatus {
    match status {
        PatchApplyStatus::InProgress => AppOperationStatus::InProgress,
        PatchApplyStatus::Completed => AppOperationStatus::Completed,
        PatchApplyStatus::Failed => AppOperationStatus::Failed,
        PatchApplyStatus::Declined => AppOperationStatus::Declined,
    }
}

fn convert_mcp_status(status: &McpToolCallStatus) -> AppOperationStatus {
    match status {
        McpToolCallStatus::InProgress => AppOperationStatus::InProgress,
        McpToolCallStatus::Completed => AppOperationStatus::Completed,
        McpToolCallStatus::Failed => AppOperationStatus::Failed,
    }
}

fn convert_dynamic_status(status: &DynamicToolCallStatus) -> AppOperationStatus {
    match status {
        DynamicToolCallStatus::InProgress => AppOperationStatus::InProgress,
        DynamicToolCallStatus::Completed => AppOperationStatus::Completed,
        DynamicToolCallStatus::Failed => AppOperationStatus::Failed,
    }
}

/// Normalize the free-form image-generation status string (set by the upstream
/// Responses API) into our typed operation status.
///
/// The upstream `status` on the end event is unreliable — Codex Desktop has
/// been observed to persist `"generating"` even after the final image has
/// been saved to disk. The presence of decoded image bytes or a non-empty
/// `saved_path` is a stronger completion signal, so we treat those as the
/// authoritative "done" indicator and only fall back to the status string
/// for distinguishing failure from still-in-flight items.
fn convert_image_generation_status(
    status: &str,
    has_image_bytes: bool,
    saved_path: Option<&str>,
) -> AppOperationStatus {
    let normalized = status.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "failed" | "error" | "errored" | "cancelled" | "canceled" => {
            return AppOperationStatus::Failed;
        }
        "completed" | "complete" | "success" | "succeeded" | "done" => {
            return AppOperationStatus::Completed;
        }
        _ => {}
    }
    if has_image_bytes || saved_path.is_some_and(|p| !p.trim().is_empty()) {
        AppOperationStatus::Completed
    } else {
        AppOperationStatus::InProgress
    }
}

/// Decode the upstream base64 `result` blob into raw image bytes. Returns
/// `None` for empty / invalid payloads so platforms can render a placeholder
/// instead of attempting to display garbage.
fn decode_image_generation_result(result: &str) -> Option<Vec<u8>> {
    let trimmed = result.trim();
    if trimmed.is_empty() {
        return None;
    }
    let engine = base64::engine::general_purpose::STANDARD;
    engine
        .decode(trimmed)
        .ok()
        .filter(|bytes| !bytes.is_empty())
}

fn convert_collab_tool(tool: &CollabAgentTool) -> String {
    match tool {
        CollabAgentTool::SpawnAgent => "spawnAgent".to_string(),
        CollabAgentTool::SendInput => "sendInput".to_string(),
        CollabAgentTool::ResumeAgent => "resumeAgent".to_string(),
        CollabAgentTool::Wait => "wait".to_string(),
        CollabAgentTool::CloseAgent => "closeAgent".to_string(),
    }
}

fn convert_collab_status(status: &CollabAgentToolCallStatus) -> AppOperationStatus {
    match status {
        CollabAgentToolCallStatus::InProgress => AppOperationStatus::InProgress,
        CollabAgentToolCallStatus::Completed => AppOperationStatus::Completed,
        CollabAgentToolCallStatus::Failed => AppOperationStatus::Failed,
    }
}

fn convert_collab_agent_status(status: &CollabAgentStatus) -> AppSubagentStatus {
    match status {
        CollabAgentStatus::PendingInit => AppSubagentStatus::PendingInit,
        CollabAgentStatus::Running => AppSubagentStatus::Running,
        CollabAgentStatus::Interrupted => AppSubagentStatus::Interrupted,
        CollabAgentStatus::Completed => AppSubagentStatus::Completed,
        CollabAgentStatus::Errored => AppSubagentStatus::Errored,
        CollabAgentStatus::Shutdown => AppSubagentStatus::Shutdown,
        CollabAgentStatus::NotFound => AppSubagentStatus::Unknown,
    }
}

fn convert_command_action(action: &CommandAction) -> HydratedCommandActionData {
    match action {
        CommandAction::Read {
            command,
            name,
            path,
        } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::Read,
            command: truncate_command_action_field(command),
            name: Some(truncate_command_action_field(name)),
            path: Some(truncate_command_action_field(&path.display().to_string())),
            query: None,
        },
        CommandAction::Search {
            command,
            query,
            path,
        } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::Search,
            command: truncate_command_action_field(command),
            name: None,
            path: path.as_deref().map(truncate_command_action_field),
            query: query.as_deref().map(truncate_command_action_field),
        },
        CommandAction::ListFiles { command, path } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::ListFiles,
            command: truncate_command_action_field(command),
            name: None,
            path: path.as_deref().map(truncate_command_action_field),
            query: None,
        },
        CommandAction::Unknown { command } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::Unknown,
            command: truncate_command_action_field(command),
            name: None,
            path: None,
            query: None,
        },
    }
}

fn build_dynamic_tool_display(
    namespace: Option<&str>,
    tool: &str,
    arguments: &serde_json::Value,
    content_summary: Option<&str>,
) -> Option<HydratedDynamicToolDisplayData> {
    if namespace != Some("claude") {
        return None;
    }
    let object = arguments.as_object();
    let mut metadata = Vec::new();

    let display = match tool {
        "ToolSearch" => {
            let query = object.and_then(|o| json_string_field(o, &["query"]));
            push_metadata(&mut metadata, "Query", query.clone());
            push_metadata(
                &mut metadata,
                "Max results",
                object
                    .and_then(|o| json_i64_field(o, &["max_results", "maxResults", "limit"]))
                    .map(|v| v.to_string()),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Tool Search".to_string(),
                summary: query
                    .map(|q| format!("Search: {}", truncate_command_action_field(&q)))
                    .unwrap_or_else(|| "Search available tools".to_string()),
                metadata,
            }
        }
        "TaskGet" => {
            let task_id = object.and_then(|o| json_string_field(o, &["taskId", "task_id", "id"]));
            push_metadata(&mut metadata, "Task ID", task_id.clone());
            HydratedDynamicToolDisplayData {
                title: "Claude Task".to_string(),
                summary: task_id
                    .map(|id| format!("Task {id}"))
                    .unwrap_or_else(|| "Get task".to_string()),
                metadata,
            }
        }
        "TaskList" => HydratedDynamicToolDisplayData {
            title: "Claude Task List".to_string(),
            summary: "List tasks".to_string(),
            metadata,
        },
        "SendMessage" => {
            let to = object.and_then(|o| json_string_field(o, &["to"]));
            let recipient = object.and_then(|o| json_string_field(o, &["recipient"]));
            let summary = object.and_then(|o| json_string_field(o, &["summary"]));
            let message_type = object.and_then(|o| json_string_field(o, &["type"]));
            let request_id =
                object.and_then(|o| json_string_field(o, &["request_id", "requestId"]));
            let approve = object.and_then(|o| json_bool_field(o, &["approve"]));
            let message = object.and_then(|o| json_string_field(o, &["message"]));
            let content = object.and_then(|o| json_string_field(o, &["content"]));
            push_metadata(&mut metadata, "To", to.clone());
            if recipient.as_ref() != to.as_ref() {
                push_metadata(&mut metadata, "Recipient", recipient.clone());
            }
            push_metadata(&mut metadata, "Type", message_type);
            push_metadata(&mut metadata, "Summary", summary.clone());
            push_metadata(&mut metadata, "Request ID", request_id);
            push_metadata(
                &mut metadata,
                "Approve",
                approve.map(|value| value.to_string()),
            );
            push_metadata(&mut metadata, "Message", message.clone());
            if content.as_ref() != message.as_ref() {
                push_metadata(&mut metadata, "Content", content);
            }
            HydratedDynamicToolDisplayData {
                title: "Claude Team Message".to_string(),
                summary: summary
                    .or_else(|| recipient.clone())
                    .or(to)
                    .map(|value| truncate_command_action_field(&value))
                    .unwrap_or_else(|| "Send team message".to_string()),
                metadata,
            }
        }
        "Monitor" => {
            let command = object.and_then(|o| json_string_field(o, &["command"]));
            let description = object.and_then(|o| json_string_field(o, &["description"]));
            push_metadata(&mut metadata, "Description", description.clone());
            push_metadata(&mut metadata, "Command", command.clone());
            push_metadata(
                &mut metadata,
                "Timeout",
                object
                    .and_then(|o| json_i64_field(o, &["timeout_ms", "timeoutMs"]))
                    .map(|v| format!("{v} ms")),
            );
            push_metadata(
                &mut metadata,
                "Persistent",
                object
                    .and_then(|o| json_bool_field(o, &["persistent"]))
                    .map(|v| v.to_string()),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Monitor".to_string(),
                summary: description
                    .or(command)
                    .map(|value| truncate_command_action_field(&value))
                    .unwrap_or_else(|| "Monitor command".to_string()),
                metadata,
            }
        }
        "WebFetch" => {
            let url = object.and_then(|o| json_string_field(o, &["url"]));
            push_metadata(&mut metadata, "URL", url.clone());
            push_metadata(
                &mut metadata,
                "Prompt",
                object.and_then(|o| json_string_field(o, &["prompt"])),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Web Fetch".to_string(),
                summary: url
                    .map(|value| truncate_command_action_field(&value))
                    .unwrap_or_else(|| "Fetch web page".to_string()),
                metadata,
            }
        }
        "TodoWrite" => {
            let todo_count = object
                .and_then(|o| o.get("todos"))
                .and_then(serde_json::Value::as_array)
                .map(|todos| {
                    for (index, todo) in todos.iter().take(12).enumerate() {
                        push_metadata(
                            &mut metadata,
                            &format!("Todo {}", index + 1),
                            Some(format_todo_value(todo)),
                        );
                    }
                    if todos.len() > 12 {
                        push_metadata(
                            &mut metadata,
                            "More",
                            Some(format!("{} additional todos", todos.len() - 12)),
                        );
                    }
                    todos.len()
                })
                .unwrap_or(0);
            HydratedDynamicToolDisplayData {
                title: "Claude Todo Write".to_string(),
                summary: match todo_count {
                    0 => "Update todos".to_string(),
                    1 => "Update 1 todo".to_string(),
                    count => format!("Update {count} todos"),
                },
                metadata,
            }
        }
        "TeamCreate" => {
            let team_name = object.and_then(|o| json_string_field(o, &["team_name", "teamName"]));
            push_metadata(&mut metadata, "Team", team_name.clone());
            push_metadata(
                &mut metadata,
                "Agent type",
                object.and_then(|o| json_string_field(o, &["agent_type", "agentType"])),
            );
            push_metadata(
                &mut metadata,
                "Description",
                object.and_then(|o| json_string_field(o, &["description"])),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Team Create".to_string(),
                summary: team_name
                    .map(|value| truncate_command_action_field(&value))
                    .unwrap_or_else(|| "Create team".to_string()),
                metadata,
            }
        }
        "TeamDelete" => HydratedDynamicToolDisplayData {
            title: "Claude Team Delete".to_string(),
            summary: "Delete team".to_string(),
            metadata,
        },
        "TaskCreate" => {
            let subject = object.and_then(|o| {
                json_string_field(o, &["subject", "description", "activeForm", "active_form"])
            });
            push_metadata(&mut metadata, "Subject", subject.clone());
            push_metadata(
                &mut metadata,
                "Active form",
                object.and_then(|o| json_string_field(o, &["activeForm", "active_form"])),
            );
            push_metadata(
                &mut metadata,
                "Status",
                object.and_then(|o| json_string_field(o, &["status"])),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Task Create".to_string(),
                summary: subject
                    .map(|value| truncate_command_action_field(&value))
                    .unwrap_or_else(|| "Create task".to_string()),
                metadata,
            }
        }
        "TaskUpdate" => {
            let task_id = object.and_then(|o| json_string_field(o, &["taskId", "task_id", "id"]));
            push_metadata(&mut metadata, "Task ID", task_id.clone());
            push_metadata(
                &mut metadata,
                "Status",
                object.and_then(|o| json_string_field(o, &["status"])),
            );
            push_metadata(
                &mut metadata,
                "Active form",
                object.and_then(|o| json_string_field(o, &["activeForm", "active_form"])),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Task Update".to_string(),
                summary: task_id
                    .map(|id| format!("Update task {id}"))
                    .unwrap_or_else(|| "Update task".to_string()),
                metadata,
            }
        }
        "Read" => {
            let path = object.and_then(|o| json_string_field(o, &["file_path", "path"]));
            push_metadata(&mut metadata, "Path", path.clone());
            push_metadata(
                &mut metadata,
                "Offset",
                object
                    .and_then(|o| json_i64_field(o, &["offset"]))
                    .map(|v| v.to_string()),
            );
            push_metadata(
                &mut metadata,
                "Limit",
                object
                    .and_then(|o| json_i64_field(o, &["limit"]))
                    .map(|v| v.to_string()),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Read".to_string(),
                summary: path
                    .map(|value| truncate_command_action_field(&value))
                    .unwrap_or_else(|| "Read file".to_string()),
                metadata,
            }
        }
        "Grep" => {
            let pattern = object.and_then(|o| json_string_field(o, &["pattern"]));
            push_metadata(&mut metadata, "Pattern", pattern.clone());
            push_metadata(
                &mut metadata,
                "Path",
                object.and_then(|o| json_string_field(o, &["path"])),
            );
            push_metadata(
                &mut metadata,
                "Output mode",
                object.and_then(|o| json_string_field(o, &["output_mode", "outputMode"])),
            );
            push_metadata(
                &mut metadata,
                "Head limit",
                object
                    .and_then(|o| json_i64_field(o, &["head_limit", "headLimit"]))
                    .map(|v| v.to_string()),
            );
            HydratedDynamicToolDisplayData {
                title: "Claude Grep".to_string(),
                summary: pattern
                    .map(|value| format!("Search: {}", truncate_command_action_field(&value)))
                    .unwrap_or_else(|| "Search files".to_string()),
                metadata,
            }
        }
        "Glob" | "LS" => {
            let pattern = object.and_then(|o| json_string_field(o, &["pattern"]));
            push_metadata(&mut metadata, "Pattern", pattern.clone());
            push_metadata(
                &mut metadata,
                "Path",
                object.and_then(|o| json_string_field(o, &["path"])),
            );
            HydratedDynamicToolDisplayData {
                title: format!("Claude {tool}"),
                summary: pattern
                    .map(|value| truncate_command_action_field(&value))
                    .or_else(|| object.and_then(|o| json_string_field(o, &["path"])))
                    .unwrap_or_else(|| "List files".to_string()),
                metadata,
            }
        }
        _ => return None,
    };

    if display.metadata.is_empty() && content_summary.is_none() {
        return None;
    }
    Some(display)
}

fn push_metadata(metadata: &mut Vec<HydratedToolMetadataData>, key: &str, value: Option<String>) {
    if let Some(value) = value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
    {
        metadata.push(HydratedToolMetadataData {
            key: key.to_string(),
            value: truncate_command_output_text(&value),
        });
    }
}

fn json_string_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(json_value_to_display_string)
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    })
}

fn json_i64_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<i64> {
    keys.iter().find_map(|key| {
        object.get(*key).and_then(|value| match value {
            serde_json::Value::Number(number) => number
                .as_i64()
                .or_else(|| number.as_u64().and_then(|value| i64::try_from(value).ok())),
            serde_json::Value::String(text) => text.parse::<i64>().ok(),
            _ => None,
        })
    })
}

fn json_bool_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<bool> {
    keys.iter().find_map(|key| {
        object.get(*key).and_then(|value| match value {
            serde_json::Value::Bool(value) => Some(*value),
            serde_json::Value::String(text) => match text.as_str() {
                "true" => Some(true),
                "false" => Some(false),
                _ => None,
            },
            _ => None,
        })
    })
}

fn json_value_to_display_string(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(text) => Some(text.clone()),
        serde_json::Value::Number(number) => Some(number.to_string()),
        serde_json::Value::Bool(value) => Some(value.to_string()),
        serde_json::Value::Null => None,
        other => pretty_json(other),
    }
}

fn format_todo_value(value: &serde_json::Value) -> String {
    let Some(object) = value.as_object() else {
        return json_value_to_display_string(value).unwrap_or_default();
    };
    let status = json_string_field(object, &["status"]);
    let content = json_string_field(object, &["content", "activeForm", "active_form"])
        .unwrap_or_else(|| json_value_to_display_string(value).unwrap_or_default());
    match status {
        Some(status) if !status.is_empty() => format!("[{status}] {content}"),
        _ => content,
    }
}

fn convert_file_change(change: &FileUpdateChange) -> HydratedFileChangeEntryData {
    let (additions, deletions) = diff_stats(&change.diff);
    let kind = match &change.kind {
        PatchChangeKind::Add => "add",
        PatchChangeKind::Delete => "delete",
        PatchChangeKind::Update { .. } => "update",
    };
    HydratedFileChangeEntryData {
        path: change.path.clone(),
        kind: kind.to_string(),
        diff: change.diff.clone(),
        additions,
        deletions,
    }
}

fn diff_stats(diff: &str) -> (u32, u32) {
    let mut additions = 0;
    let mut deletions = 0;
    for line in diff.lines() {
        if line.starts_with('+') && !line.starts_with("+++") {
            additions += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            deletions += 1;
        }
    }
    (additions, deletions)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn render_user_input(inputs: &[UserInput]) -> (String, Vec<String>) {
    let mut text_parts = Vec::new();
    let mut images = Vec::new();
    for input in inputs {
        match input {
            UserInput::Text { text, .. } => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    text_parts.push(trimmed.to_string());
                }
            }
            UserInput::Image { url } => {
                images.push(url.clone());
            }
            UserInput::LocalImage { path } => {
                images.push(format!("file://{}", path.display()));
            }
            UserInput::Skill { name, path } => {
                if !name.is_empty() && path != &PathBuf::new() {
                    text_parts.push(format!("[Skill] {} ({})", name, path.display()));
                } else if !name.is_empty() {
                    text_parts.push(format!("[Skill] {name}"));
                } else if path != &PathBuf::new() {
                    text_parts.push(format!("[Skill] {}", path.display()));
                }
            }
            UserInput::Mention { name, path } => {
                if !name.is_empty() && !path.is_empty() {
                    text_parts.push(format!("[Mention] {name} ({path})"));
                } else if !name.is_empty() {
                    text_parts.push(format!("[Mention] {name}"));
                } else if !path.is_empty() {
                    text_parts.push(format!("[Mention] {path}"));
                }
            }
        }
    }
    (text_parts.join("\n"), images)
}

fn widget_data_from_dynamic_tool_call(
    tool: &str,
    arguments: &serde_json::Value,
    status: &DynamicToolCallStatus,
    content_items: Option<&[DynamicToolCallOutputContentItem]>,
) -> Option<HydratedWidgetData> {
    if !tool.eq_ignore_ascii_case("show_widget") {
        return None;
    }

    let status_label = match status {
        DynamicToolCallStatus::InProgress => "inProgress",
        DynamicToolCallStatus::Completed => "completed",
        DynamicToolCallStatus::Failed => "failed",
    };
    let is_finalized = !matches!(status, DynamicToolCallStatus::InProgress);
    let object = arguments.as_object()?;
    let widget_html = object
        .get("widget_code")
        .or_else(|| object.get("widgetCode"))
        .and_then(|value| value.as_str())
        .map(ToString::to_string)
        .or_else(|| {
            content_items.and_then(|items| {
                items.iter().find_map(|item| match item {
                    DynamicToolCallOutputContentItem::InputText { text } => Some(text.clone()),
                    DynamicToolCallOutputContentItem::InputImage { .. } => None,
                })
            })
        })?;
    let title = object
        .get("title")
        .and_then(|value| value.as_str())
        .unwrap_or("Widget")
        .to_string();
    let width = json_number_field(object, &["width"]).unwrap_or(800.0);
    let height = json_number_field(object, &["height"]).unwrap_or(600.0);
    let app_id = object
        .get("app_id")
        .or_else(|| object.get("appId"))
        .and_then(|value| value.as_str())
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(ToString::to_string);

    Some(HydratedWidgetData {
        title,
        widget_html,
        width,
        height,
        status: status_label.to_string(),
        is_finalized,
        app_id,
    })
}

fn json_number_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<f64> {
    keys.iter().find_map(|key| {
        object.get(*key).and_then(|value| match value {
            serde_json::Value::Number(number) => number.as_f64(),
            serde_json::Value::String(text) => text.parse::<f64>().ok(),
            _ => None,
        })
    })
}

/// Tolerant "best-effort" parse of a partially-streamed `show_widget`
/// tool-call argument blob. The model streams JSON one chunk at a time;
/// we want to surface as much of `widget_code` as we have so far so the
/// platform can render a partial widget. Falls through gracefully when
/// the buffer isn't a complete object yet.
///
/// Policy:
/// - If the buffer parses as a complete JSON object, delegate to
///   `widget_data_from_dynamic_tool_call` for full extraction.
/// - Otherwise, run a streaming extractor that finds the
///   `widget_code`/`widgetCode` key and returns the longest safe string
///   prefix we can see (handling `\\` escapes, stopping at an unescaped
///   closing quote or end-of-buffer). `title`/`app_id` default to
///   placeholders. `width`/`height` default to the standard 800x600.
///
/// Returns `None` when we can't find enough to render anything yet
/// (e.g. we haven't seen `widget_code` opened yet).
pub(crate) fn streaming_widget_data_from_partial_arguments(
    partial: &str,
) -> Option<HydratedWidgetData> {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(partial) {
        return widget_data_from_dynamic_tool_call(
            "show_widget",
            &value,
            &DynamicToolCallStatus::InProgress,
            None,
        );
    }

    let widget_html = extract_streaming_string_field(partial, &["widget_code", "widgetCode"])?;
    if widget_html.is_empty() {
        return None;
    }
    let title =
        extract_streaming_string_field(partial, &["title"]).unwrap_or_else(|| "Widget".to_string());
    let app_id = extract_streaming_string_field(partial, &["app_id", "appId"])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let width = extract_streaming_number_field(partial, &["width"]).unwrap_or(800.0);
    let height = extract_streaming_number_field(partial, &["height"]).unwrap_or(600.0);

    Some(HydratedWidgetData {
        title,
        widget_html,
        width,
        height,
        status: "inProgress".to_string(),
        is_finalized: false,
        app_id,
    })
}

/// Synthesize a valid `show_widget` arguments JSON object from a
/// partially-streamed buffer. Unlike
/// `streaming_widget_data_from_partial_arguments` (which produces the
/// hydrated boundary type directly), this returns a `serde_json::Value`
/// suitable for round-tripping through the upstream
/// `ThreadItem::DynamicToolCall { arguments, .. }` → hydration path.
///
/// Policy: if the raw buffer parses as JSON, pass it through unchanged.
/// Otherwise, run the streaming extractor and build a fresh object from
/// whatever fields were pulled. Returns `None` when we don't yet have
/// enough to render — specifically, when `widget_code` hasn't been
/// opened yet.
pub(crate) fn synthesize_streaming_show_widget_arguments(
    partial: &str,
) -> Option<serde_json::Value> {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(partial) {
        return Some(value);
    }

    let widget_html = extract_streaming_string_field(partial, &["widget_code", "widgetCode"])?;
    if widget_html.is_empty() {
        return None;
    }
    let title =
        extract_streaming_string_field(partial, &["title"]).unwrap_or_else(|| "Widget".to_string());
    let app_id = extract_streaming_string_field(partial, &["app_id", "appId"])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let width = extract_streaming_number_field(partial, &["width"]).unwrap_or(800.0);
    let height = extract_streaming_number_field(partial, &["height"]).unwrap_or(600.0);

    let mut obj = serde_json::Map::new();
    obj.insert("title".to_string(), serde_json::Value::String(title));
    obj.insert(
        "widget_code".to_string(),
        serde_json::Value::String(widget_html),
    );
    obj.insert(
        "width".to_string(),
        serde_json::Number::from_f64(width)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
    );
    obj.insert(
        "height".to_string(),
        serde_json::Number::from_f64(height)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
    );
    if let Some(slug) = app_id {
        obj.insert("app_id".to_string(), serde_json::Value::String(slug));
    }
    Some(serde_json::Value::Object(obj))
}

/// Scan `buffer` for `"<key>"\s*:\s*"<value-prefix>` and return the
/// longest safe UTF-8 prefix of the value. Returns whatever's been
/// streamed so far — an unclosed string gives a prefix, a closed
/// string gives the final value. Handles `\\`, `\"`, `\n` and standard
/// JSON escape sequences. Incomplete trailing escape sequences are
/// dropped from the prefix.
pub(crate) fn extract_streaming_string_field(buffer: &str, keys: &[&str]) -> Option<String> {
    let bytes = buffer.as_bytes();
    for key in keys {
        if let Some(value) = scan_string_field(bytes, key) {
            return Some(value);
        }
    }
    None
}

fn scan_string_field(bytes: &[u8], key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let mut pos = 0usize;
    // Find the key, then a `:`, then the opening `"`.
    while let Some(idx) = find_at(bytes, needle.as_bytes(), pos) {
        // Verify this is actually a key (followed eventually by `:`),
        // not a substring inside some other string value.
        let mut cursor = idx + needle.len();
        while cursor < bytes.len() && matches!(bytes[cursor], b' ' | b'\t' | b'\n' | b'\r') {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b':' {
            pos = idx + 1;
            continue;
        }
        cursor += 1;
        while cursor < bytes.len() && matches!(bytes[cursor], b' ' | b'\t' | b'\n' | b'\r') {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b'"' {
            return None;
        }
        cursor += 1;
        return Some(decode_partial_json_string(&bytes[cursor..]));
    }
    None
}

/// Decode a JSON string starting just after the opening `"`. Stops at
/// an unescaped `"` or end of input (streaming case). Returns the
/// decoded value; if an escape sequence is incomplete at the end of
/// input, drops the trailing backslash.
fn decode_partial_json_string(src: &[u8]) -> String {
    let mut out = String::with_capacity(src.len());
    let mut i = 0usize;
    while i < src.len() {
        let b = src[i];
        if b == b'"' {
            break;
        }
        if b == b'\\' {
            if i + 1 >= src.len() {
                // Dangling escape — drop it until the next delta fills
                // in the escaped character.
                break;
            }
            let esc = src[i + 1];
            match esc {
                b'"' => out.push('"'),
                b'\\' => out.push('\\'),
                b'/' => out.push('/'),
                b'n' => out.push('\n'),
                b'r' => out.push('\r'),
                b't' => out.push('\t'),
                b'b' => out.push('\u{0008}'),
                b'f' => out.push('\u{000C}'),
                b'u' => {
                    if i + 6 > src.len() {
                        // Incomplete \uXXXX — wait for next delta.
                        break;
                    }
                    let hex = &src[i + 2..i + 6];
                    let hex_str = match std::str::from_utf8(hex) {
                        Ok(s) => s,
                        Err(_) => break,
                    };
                    let code = match u32::from_str_radix(hex_str, 16) {
                        Ok(c) => c,
                        Err(_) => break,
                    };
                    if let Some(c) = char::from_u32(code) {
                        out.push(c);
                    }
                    i += 6;
                    continue;
                }
                // Unknown escape — copy literally rather than drop.
                other => {
                    out.push('\\');
                    out.push(other as char);
                }
            }
            i += 2;
            continue;
        }
        // Walk a full UTF-8 sequence so we don't split a multi-byte
        // char across deltas. If the buffer cuts in the middle of a
        // multi-byte code point, stop before it.
        let width = utf8_char_width(b);
        if width == 0 {
            // Invalid leading byte — skip it.
            i += 1;
            continue;
        }
        if i + width > src.len() {
            break;
        }
        match std::str::from_utf8(&src[i..i + width]) {
            Ok(s) => out.push_str(s),
            Err(_) => break,
        }
        i += width;
    }
    out
}

fn utf8_char_width(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b < 0xC0 {
        0
    } else if b < 0xE0 {
        2
    } else if b < 0xF0 {
        3
    } else if b < 0xF8 {
        4
    } else {
        0
    }
}

/// Extract a numeric-valued field from a partial/complete JSON buffer.
/// Only returns when the number is fully terminated (by whitespace,
/// `,`, or `}`). Streaming midway through a number yields `None` so
/// callers fall back to the default.
pub(crate) fn extract_streaming_number_field(buffer: &str, keys: &[&str]) -> Option<f64> {
    let bytes = buffer.as_bytes();
    for key in keys {
        if let Some(value) = scan_number_field(bytes, key) {
            return Some(value);
        }
    }
    None
}

fn scan_number_field(bytes: &[u8], key: &str) -> Option<f64> {
    let needle = format!("\"{key}\"");
    let mut pos = 0usize;
    while let Some(idx) = find_at(bytes, needle.as_bytes(), pos) {
        let mut cursor = idx + needle.len();
        while cursor < bytes.len() && matches!(bytes[cursor], b' ' | b'\t' | b'\n' | b'\r') {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b':' {
            pos = idx + 1;
            continue;
        }
        cursor += 1;
        while cursor < bytes.len() && matches!(bytes[cursor], b' ' | b'\t' | b'\n' | b'\r') {
            cursor += 1;
        }
        let start = cursor;
        while cursor < bytes.len()
            && matches!(
                bytes[cursor],
                b'-' | b'+' | b'0'..=b'9' | b'.' | b'e' | b'E'
            )
        {
            cursor += 1;
        }
        if cursor == start || cursor == bytes.len() {
            // No digits, or reached end of buffer without a terminator —
            // treat as not-yet-parseable.
            return None;
        }
        let slice = std::str::from_utf8(&bytes[start..cursor]).ok()?;
        return slice.parse::<f64>().ok();
    }
    None
}

fn find_at(haystack: &[u8], needle: &[u8], start: usize) -> Option<usize> {
    if needle.is_empty() || start > haystack.len() {
        return None;
    }
    haystack[start..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|i| i + start)
}

fn build_computer_use_view(
    tool: &str,
    arguments: &serde_json::Value,
    result: Option<&McpToolCallResult>,
) -> ComputerUseView {
    let arg_str = |key: &str| -> Option<String> {
        arguments
            .get(key)
            .and_then(|v| match v {
                serde_json::Value::String(s) => Some(s.clone()),
                serde_json::Value::Number(n) => Some(n.to_string()),
                _ => None,
            })
            .filter(|s| !s.is_empty())
    };
    let arg_num = |key: &str| -> Option<f64> {
        arguments.get(key).and_then(|v| match v {
            serde_json::Value::Number(n) => n.as_f64(),
            serde_json::Value::String(s) => s.parse().ok(),
            _ => None,
        })
    };

    let typed = match tool {
        "list_apps" => ComputerUseTool::ListApps,
        "get_app_state" => ComputerUseTool::GetAppState {
            app: arg_str("app").unwrap_or_default(),
        },
        "click" => ComputerUseTool::Click {
            app: arg_str("app").unwrap_or_default(),
            element_index: arg_str("element_index"),
            x: arg_num("x"),
            y: arg_num("y"),
            button: arg_str("button"),
        },
        "perform_secondary_action" => ComputerUseTool::PerformSecondaryAction {
            app: arg_str("app").unwrap_or_default(),
            element_index: arg_str("element_index"),
            action: arg_str("action"),
        },
        "scroll" => ComputerUseTool::Scroll {
            app: arg_str("app").unwrap_or_default(),
            element_index: arg_str("element_index"),
            direction: arg_str("direction"),
            pages: arg_num("pages"),
        },
        "drag" => ComputerUseTool::Drag {
            app: arg_str("app").unwrap_or_default(),
            from_x: arg_num("from_x"),
            from_y: arg_num("from_y"),
            to_x: arg_num("to_x"),
            to_y: arg_num("to_y"),
        },
        "type_text" => ComputerUseTool::TypeText {
            app: arg_str("app").unwrap_or_default(),
            text: arg_str("text").unwrap_or_default(),
        },
        "press_key" => ComputerUseTool::PressKey {
            app: arg_str("app").unwrap_or_default(),
            key: arg_str("key").unwrap_or_default(),
        },
        "set_value" => ComputerUseTool::SetValue {
            app: arg_str("app").unwrap_or_default(),
            element_index: arg_str("element_index"),
            value: arg_str("value"),
        },
        other => ComputerUseTool::Unknown {
            name: other.to_string(),
        },
    };

    let summary = computer_use_summary(&typed);

    let mut screenshot_png: Option<Vec<u8>> = None;
    let mut accessibility_text: Option<String> = None;
    if let Some(r) = result {
        let engine = base64::engine::general_purpose::STANDARD;
        for part in &r.content {
            let Some(obj) = part.as_object() else {
                continue;
            };
            match obj.get("type").and_then(|v| v.as_str()) {
                Some("image") => {
                    let mime = obj
                        .get("mimeType")
                        .or_else(|| obj.get("mime_type"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    if !mime.starts_with("image/") && !mime.is_empty() {
                        continue;
                    }
                    if screenshot_png.is_some() {
                        continue;
                    }
                    if let Some(data) = obj.get("data").and_then(|v| v.as_str()) {
                        if let Ok(bytes) = engine.decode(data) {
                            if !bytes.is_empty() {
                                screenshot_png = Some(bytes);
                            }
                        }
                    }
                }
                Some("text") => {
                    if accessibility_text.is_some() {
                        continue;
                    }
                    if let Some(text) = obj.get("text").and_then(|v| v.as_str()) {
                        let trimmed = text.trim();
                        if !trimmed.is_empty() {
                            accessibility_text = Some(trimmed.to_string());
                        }
                    }
                }
                _ => {}
            }
        }
    }

    ComputerUseView {
        tool: typed,
        summary,
        screenshot_png,
        accessibility_text,
    }
}

fn computer_use_summary(tool: &ComputerUseTool) -> String {
    let short_app = |app: &str| -> String { app.rsplit('.').next().unwrap_or(app).to_string() };
    match tool {
        ComputerUseTool::ListApps => "List running apps".to_string(),
        ComputerUseTool::GetAppState { app } => format!("Inspect {}", short_app(app)),
        ComputerUseTool::Click {
            app,
            element_index,
            x,
            y,
            ..
        } => {
            let target = match (element_index.as_deref(), x, y) {
                (Some(idx), _, _) if !idx.is_empty() => format!("element {}", idx),
                (_, Some(x), Some(y)) => format!("({:.0}, {:.0})", x, y),
                _ => "—".to_string(),
            };
            format!("Click {} in {}", target, short_app(app))
        }
        ComputerUseTool::PerformSecondaryAction {
            app,
            element_index,
            action,
        } => {
            let target = element_index.as_deref().unwrap_or("—");
            match action.as_deref() {
                Some(act) if !act.is_empty() => {
                    format!("{} on element {} in {}", act, target, short_app(app))
                }
                _ => format!(
                    "Secondary action on element {} in {}",
                    target,
                    short_app(app)
                ),
            }
        }
        ComputerUseTool::Scroll {
            app,
            direction,
            element_index,
            pages,
        } => {
            let dir = direction.as_deref().unwrap_or("scroll");
            let pages_suffix = pages
                .filter(|p| (*p - 1.0).abs() > f64::EPSILON)
                .map(|p| format!(" ×{}", p as i64))
                .unwrap_or_default();
            match element_index {
                Some(idx) if !idx.is_empty() => {
                    format!(
                        "Scroll {} on element {}{} in {}",
                        dir,
                        idx,
                        pages_suffix,
                        short_app(app)
                    )
                }
                _ => format!("Scroll {}{} in {}", dir, pages_suffix, short_app(app)),
            }
        }
        ComputerUseTool::Drag {
            app,
            from_x,
            from_y,
            to_x,
            to_y,
        } => match (from_x, from_y, to_x, to_y) {
            (Some(fx), Some(fy), Some(tx), Some(ty)) => format!(
                "Drag ({:.0}, {:.0}) → ({:.0}, {:.0}) in {}",
                fx,
                fy,
                tx,
                ty,
                short_app(app)
            ),
            _ => format!("Drag in {}", short_app(app)),
        },
        ComputerUseTool::TypeText { app, text } => {
            let snippet = if text.chars().count() > 48 {
                let head: String = text.chars().take(48).collect();
                format!("{head}…")
            } else {
                text.clone()
            };
            format!("Type \"{}\" in {}", snippet, short_app(app))
        }
        ComputerUseTool::PressKey { app, key } => {
            format!("Press {} in {}", key, short_app(app))
        }
        ComputerUseTool::SetValue {
            app,
            element_index,
            value,
        } => {
            let target = element_index.as_deref().unwrap_or("—");
            let v_snippet = value.as_deref().map(|v| {
                if v.chars().count() > 32 {
                    format!("{}…", v.chars().take(32).collect::<String>())
                } else {
                    v.to_string()
                }
            });
            match v_snippet {
                Some(v) => format!("Set element {} = \"{}\" in {}", target, v, short_app(app)),
                None => format!("Set element {} in {}", target, short_app(app)),
            }
        }
        ComputerUseTool::Unknown { name } => format!("computer-use: {}", name),
    }
}

fn pretty_json(value: &impl Serialize) -> Option<String> {
    let s = serde_json::to_string_pretty(value).ok()?;
    if s == "null" {
        return None;
    }
    Some(s.trim_end_matches('\n').to_string())
}

fn stringify_json_value(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.trim().to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        serde_json::Value::Null => String::new(),
        other => serde_json::to_string_pretty(other)
            .unwrap_or_default()
            .trim()
            .to_string(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_protocol::TurnStatus;
    use std::collections::HashMap;

    fn test_abs_path(path: &str) -> codex_utils_absolute_path::AbsolutePathBuf {
        codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path_checked(path)
            .expect("test path must be absolute")
    }

    fn make_turn(id: &str, items: Vec<ThreadItem>) -> Turn {
        Turn {
            id: id.to_string(),
            items,
            status: TurnStatus::Completed,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        }
    }

    #[test]
    fn test_user_message_text() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::UserMessage {
                id: "u1".into(),
                content: vec![UserInput::Text {
                    text: "  Hello world  ".into(),
                    text_elements: vec![],
                }],
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "u1");
        assert!(items[0].is_from_user_turn_boundary);
        match &items[0].content {
            HydratedConversationItemContent::User(data) => {
                assert_eq!(data.text, "Hello world");
                assert!(data.image_data_uris.is_empty());
            }
            _ => panic!("expected User content"),
        }
    }

    #[test]
    fn test_empty_user_message_skipped() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::UserMessage {
                id: "u1".into(),
                content: vec![UserInput::Text {
                    text: "   ".into(),
                    text_elements: vec![],
                }],
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert!(items.is_empty());
    }

    #[test]
    fn test_agent_message() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::AgentMessage {
                id: "a1".into(),
                text: " Response text ".into(),
                phase: None,
                memory_citation: None,
            }],
        )];
        let opts = HydrationOptions {
            default_agent_nickname: Some("bob".into()),
            default_agent_role: Some("coder".into()),
        };
        let items = hydrate_turns(&turns, &opts);
        assert_eq!(items.len(), 1);
        assert!(!items[0].is_from_user_turn_boundary);
        match &items[0].content {
            HydratedConversationItemContent::Assistant(data) => {
                assert_eq!(data.text, "Response text");
                assert_eq!(data.agent_nickname.as_deref(), Some("bob"));
                assert_eq!(data.agent_role.as_deref(), Some("coder"));
                assert_eq!(data.phase, None);
            }
            _ => panic!("expected Assistant content"),
        }
    }

    #[test]
    fn test_agent_message_code_review_hydrates_as_code_review() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::AgentMessage {
                id: "a1".into(),
                text: serde_json::json!({
                    "findings": [
                        {
                            "title": "[P1] Fall back to turn/start when IPC queue sync fails",
                            "body": "A queued follow-up can get stuck indefinitely.",
                            "confidence_score": 0.97,
                            "priority": 1,
                            "code_location": {
                                "absolute_file_path": "/Users/sigkitten/dev/litter/shared/rust-bridge/codex-mobile-client/src/mobile_client_impl.rs",
                                "line_range": { "start": 799, "end": 815 }
                            }
                        }
                    ],
                    "overall_correctness": "incorrect",
                    "overall_explanation": "There are blocking issues.",
                    "overall_confidence_score": 0.92
                })
                .to_string(),
                phase: Some(codex_protocol::models::MessagePhase::FinalAnswer),
                memory_citation: None,
            }],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            HydratedConversationItemContent::CodeReview(data) => {
                assert_eq!(data.findings.len(), 1);
                assert_eq!(
                    data.findings[0].title,
                    "Fall back to turn/start when IPC queue sync fails"
                );
                assert_eq!(data.findings[0].priority, Some(1));
                assert_eq!(data.overall_correctness.as_deref(), Some("incorrect"));
            }
            _ => panic!("expected CodeReview content"),
        }
    }

    #[test]
    fn test_diff_stats_ignores_headers() {
        let diff = "\
diff --git a/parser.rs b/parser.rs\n\
--- a/parser.rs\n\
+++ b/parser.rs\n\
@@ -1,3 +1,4 @@\n\
 line one\n\
-line two\n\
+line two updated\n\
+line three\n";

        assert_eq!(diff_stats(diff), (2, 1));
    }

    #[test]
    fn test_agent_message_markdown_stays_assistant() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::AgentMessage {
                id: "a1".into(),
                text: "Here is a regular markdown answer.".into(),
                phase: Some(codex_protocol::models::MessagePhase::FinalAnswer),
                memory_citation: None,
            }],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        assert!(matches!(
            &items[0].content,
            HydratedConversationItemContent::Assistant(data)
            if data.text == "Here is a regular markdown answer."
        ));
    }

    #[test]
    fn test_command_execution() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::CommandExecution {
                id: "c1".into(),
                command: "ls -la".into(),
                cwd: test_abs_path("/tmp"),
                process_id: Some("p1".into()),
                source: Default::default(),
                status: CommandExecutionStatus::Completed,
                command_actions: vec![CommandAction::Read {
                    command: "cat foo.rs".into(),
                    name: "foo.rs".into(),
                    path: test_abs_path("/src/foo.rs"),
                }],
                aggregated_output: Some("file contents".into()),
                exit_code: Some(0),
                duration_ms: Some(123),
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            HydratedConversationItemContent::CommandExecution(data) => {
                assert_eq!(data.command, "ls -la");
                assert_eq!(data.cwd, "/tmp");
                assert_eq!(data.status, AppOperationStatus::Completed);
                assert_eq!(data.exit_code, Some(0));
                assert_eq!(data.actions.len(), 1);
                assert!(matches!(
                    data.actions[0].kind,
                    HydratedCommandActionKind::Read
                ));
            }
            _ => panic!("expected CommandExecution content"),
        }
    }

    #[test]
    fn test_display_command_strips_known_shell_wrappers() {
        assert_eq!(display_command("/bin/zsh -lc 'ls -la'"), "ls -la");
        assert_eq!(display_command("/bin/bash -c 'echo hi'"), "echo hi");
        assert_eq!(display_command("/bin/sh -lc 'pwd'"), "pwd");
        assert_eq!(
            display_command("pwsh -NoProfile -Command 'Get-ChildItem'"),
            "Get-ChildItem"
        );
        assert_eq!(
            display_command("powershell.exe -Command 'Write-Host hi'"),
            "Write-Host hi"
        );
        assert_eq!(display_command("cmd.exe /c dir"), "dir");
        assert_eq!(display_command("plain command"), "plain command");
    }

    #[test]
    fn test_command_execution_strips_shell_wrapper_for_display() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::CommandExecution {
                id: "c1".into(),
                command: "/bin/zsh -lc 'npm test'".into(),
                cwd: test_abs_path("/tmp"),
                process_id: None,
                source: Default::default(),
                status: CommandExecutionStatus::InProgress,
                command_actions: vec![],
                aggregated_output: None,
                exit_code: None,
                duration_ms: None,
            }],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            HydratedConversationItemContent::CommandExecution(data) => {
                assert_eq!(data.command, "npm test");
            }
            _ => panic!("expected CommandExecution content"),
        }
    }

    #[test]
    fn test_context_compaction() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::ContextCompaction { id: "cc1".into() }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            HydratedConversationItemContent::Divider(HydratedDividerData::ContextCompaction {
                is_complete,
            }) => {
                assert!(*is_complete);
            }
            _ => panic!("expected ContextCompaction divider"),
        }
    }

    #[test]
    fn test_review_mode() {
        let turns = vec![make_turn(
            "t1",
            vec![
                ThreadItem::EnteredReviewMode {
                    id: "er1".into(),
                    review: "safety".into(),
                },
                ThreadItem::ExitedReviewMode {
                    id: "xr1".into(),
                    review: "safety".into(),
                },
            ],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 2);
        assert!(matches!(
            &items[0].content,
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewEntered { review })
            if review == "safety"
        ));
        assert!(matches!(
            &items[1].content,
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewExited { review })
            if review == "safety"
        ));
    }

    #[test]
    fn test_multi_turn_indexing() {
        let turns = vec![
            make_turn(
                "t1",
                vec![ThreadItem::UserMessage {
                    id: "u1".into(),
                    content: vec![UserInput::Text {
                        text: "Hello".into(),
                        text_elements: vec![],
                    }],
                }],
            ),
            make_turn(
                "t2",
                vec![ThreadItem::AgentMessage {
                    id: "a1".into(),
                    text: "World".into(),
                    phase: None,
                    memory_citation: None,
                }],
            ),
        ];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].source_turn_id.as_deref(), Some("t1"));
        assert_eq!(items[0].source_turn_index, Some(0));
        assert_eq!(items[1].source_turn_id.as_deref(), Some("t2"));
        assert_eq!(items[1].source_turn_index, Some(1));
    }

    #[test]
    fn test_tool_and_subagent_items_hydrate() {
        let mut agent_states = HashMap::new();
        agent_states.insert(
            "sub-thread-1".to_string(),
            codex_app_server_protocol::CollabAgentState {
                status: CollabAgentStatus::Running,
                message: Some("Working".into()),
            },
        );

        let turns = vec![make_turn(
            "t-tools",
            vec![
                ThreadItem::McpToolCall {
                    id: "mcp-1".into(),
                    server: "filesystem".into(),
                    tool: "read_file".into(),
                    status: McpToolCallStatus::Completed,
                    arguments: serde_json::json!({ "path": "/tmp/file.txt" }),
                    mcp_app_resource_uri: None,
                    result: Some(Box::new(codex_app_server_protocol::McpToolCallResult {
                        content: vec![serde_json::json!("contents")],
                        structured_content: None,
                        meta: None,
                    })),
                    error: None,
                    duration_ms: Some(250),
                },
                ThreadItem::DynamicToolCall {
                    id: "dyn-1".into(),
                    tool: "show_widget".into(),
                    namespace: None,
                    arguments: serde_json::json!({
                        "title": "Widget",
                        "widget_code": "<svg></svg>",
                        "width": 640,
                        "height": 360
                    }),
                    status: DynamicToolCallStatus::Completed,
                    content_items: Some(vec![DynamicToolCallOutputContentItem::InputText {
                        text: "rendered".into(),
                    }]),
                    success: Some(true),
                    duration_ms: Some(120),
                },
                ThreadItem::CollabAgentToolCall {
                    id: "collab-1".into(),
                    tool: CollabAgentTool::SpawnAgent,
                    status: CollabAgentToolCallStatus::Completed,
                    sender_thread_id: "parent-thread".into(),
                    receiver_thread_ids: vec!["sub-thread-1".into()],
                    prompt: Some("Review the changes".into()),
                    model: None,
                    reasoning_effort: None,
                    agents_states: agent_states,
                },
                ThreadItem::WebSearch {
                    id: "web-1".into(),
                    query: "swiftui subagent cards".into(),
                    action: None,
                },
                ThreadItem::ImageView {
                    id: "img-1".into(),
                    path: test_abs_path("/tmp/screenshot.png"),
                },
            ],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 5);

        assert!(matches!(
            items[0].content,
            HydratedConversationItemContent::McpToolCall(_)
        ));
        assert!(matches!(
            items[1].content,
            HydratedConversationItemContent::Widget(_)
        ));
        assert!(matches!(
            items[2].content,
            HydratedConversationItemContent::MultiAgentAction(_)
        ));
        assert!(matches!(
            items[3].content,
            HydratedConversationItemContent::WebSearch(_)
        ));
        assert!(matches!(
            items[4].content,
            HydratedConversationItemContent::ImageView(_)
        ));
    }

    #[test]
    fn test_claude_dynamic_tool_hydrates_namespace_and_display() {
        let turns = vec![make_turn(
            "t-claude-dynamic",
            vec![
                ThreadItem::DynamicToolCall {
                    id: "tool-search".into(),
                    namespace: Some("claude".into()),
                    tool: "ToolSearch".into(),
                    arguments: serde_json::json!({
                        "query": "select:AskUserQuestion,ExitPlanMode",
                        "max_results": 2
                    }),
                    status: DynamicToolCallStatus::Completed,
                    content_items: Some(vec![DynamicToolCallOutputContentItem::InputText {
                        text: "AskUserQuestion\nExitPlanMode".into(),
                    }]),
                    success: Some(true),
                    duration_ms: Some(42),
                },
                ThreadItem::DynamicToolCall {
                    id: "send-message".into(),
                    namespace: Some("claude".into()),
                    tool: "SendMessage".into(),
                    arguments: serde_json::json!({
                        "to": "ios-bridge-engineer",
                        "recipient": "ios-bridge-engineer",
                        "type": "notify",
                        "summary": "Check bridge mapping",
                        "message": "Please verify the shared Rust hydration path."
                    }),
                    status: DynamicToolCallStatus::Completed,
                    content_items: Some(vec![DynamicToolCallOutputContentItem::InputText {
                        text: "sent".into(),
                    }]),
                    success: Some(true),
                    duration_ms: None,
                },
            ],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 2);
        let HydratedConversationItemContent::DynamicToolCall(search) = &items[0].content else {
            panic!("expected DynamicToolCall");
        };
        assert_eq!(search.namespace.as_deref(), Some("claude"));
        assert_eq!(
            search.content_summary.as_deref(),
            Some("AskUserQuestion\nExitPlanMode")
        );
        let display = search.display.as_ref().expect("claude display");
        assert_eq!(display.title, "Claude Tool Search");
        assert_eq!(
            display.summary,
            "Search: select:AskUserQuestion,ExitPlanMode"
        );
        assert!(
            display
                .metadata
                .iter()
                .any(|entry| entry.key == "Max results" && entry.value == "2")
        );

        let HydratedConversationItemContent::DynamicToolCall(message) = &items[1].content else {
            panic!("expected DynamicToolCall");
        };
        let display = message.display.as_ref().expect("claude display");
        assert_eq!(display.title, "Claude Team Message");
        assert_eq!(display.summary, "Check bridge mapping");
        assert!(display.metadata.iter().any(|entry| entry.key == "Message"
            && entry.value == "Please verify the shared Rust hydration path."));
    }

    #[test]
    fn test_computer_use_mcp_hydrates_typed_view() {
        let turns = vec![make_turn(
            "t-computer-use",
            vec![
                ThreadItem::McpToolCall {
                    id: "cu-1".into(),
                    server: "computer-use".into(),
                    tool: "click".into(),
                    status: McpToolCallStatus::Completed,
                    arguments: serde_json::json!({
                        "app": "com.google.Chrome",
                        "element_index": "634"
                    }),
                    mcp_app_resource_uri: None,
                    result: Some(Box::new(codex_app_server_protocol::McpToolCallResult {
                        content: vec![
                            serde_json::json!({
                                "type": "image",
                                "mimeType": "image/png",
                                "data": "iVBORw0KGgoAAAANSUhEUg=="
                            }),
                            serde_json::json!({
                                "type": "text",
                                "text": "App=com.google.Chrome (pid 37357)\n..."
                            }),
                        ],
                        structured_content: None,
                        meta: None,
                    })),
                    error: None,
                    duration_ms: Some(1700),
                },
                // Non-computer-use MCP should not populate the typed view.
                ThreadItem::McpToolCall {
                    id: "other-1".into(),
                    server: "filesystem".into(),
                    tool: "read_file".into(),
                    status: McpToolCallStatus::Completed,
                    arguments: serde_json::json!({ "path": "/tmp/file.txt" }),
                    mcp_app_resource_uri: None,
                    result: None,
                    error: None,
                    duration_ms: None,
                },
            ],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 2);

        let HydratedConversationItemContent::McpToolCall(data) = &items[0].content else {
            panic!("expected McpToolCall");
        };
        let view = data.computer_use.as_ref().expect("computer_use view");
        let ComputerUseTool::Click {
            app, element_index, ..
        } = &view.tool
        else {
            panic!("expected Click, got {:?}", view.tool);
        };
        assert_eq!(app, "com.google.Chrome");
        assert_eq!(element_index.as_deref(), Some("634"));
        let png = view.screenshot_png.as_ref().expect("png bytes");
        // PNG magic header: 89 50 4E 47 0D 0A 1A 0A
        assert_eq!(&png[..8], &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        assert!(
            view.accessibility_text
                .as_deref()
                .unwrap()
                .starts_with("App=com.google.Chrome")
        );
        assert!(view.summary.contains("634"));
        assert!(view.summary.contains("Chrome"));

        let HydratedConversationItemContent::McpToolCall(other) = &items[1].content else {
            panic!("expected McpToolCall");
        };
        assert!(other.computer_use.is_none());
    }

    #[test]
    fn test_image_generation_hydrates_typed_variant() {
        // A 1x1 transparent PNG (89 50 4E 47 ...) as base64, used here to
        // exercise the decode path end-to-end.
        let png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
        let turns = vec![make_turn(
            "t-imagegen",
            vec![
                ThreadItem::ImageGeneration {
                    id: "ig-1".into(),
                    status: "completed".into(),
                    revised_prompt: Some("a grumpy pirate kitty".into()),
                    result: png_base64.into(),
                    saved_path: Some(test_abs_path("/tmp/ig-1.png")),
                },
                // A still-streaming item should stay InProgress with no bytes.
                ThreadItem::ImageGeneration {
                    id: "ig-2".into(),
                    status: String::new(),
                    revised_prompt: None,
                    result: String::new(),
                    saved_path: None,
                },
                // Codex Desktop has been observed to emit status="generating"
                // even on the final end event. Presence of bytes or a saved
                // path should mark the item as Completed regardless.
                ThreadItem::ImageGeneration {
                    id: "ig-3".into(),
                    status: "generating".into(),
                    revised_prompt: None,
                    result: png_base64.into(),
                    saved_path: Some(test_abs_path("/tmp/ig-3.png")),
                },
            ],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 3);

        let HydratedConversationItemContent::ImageGeneration(done) = &items[0].content else {
            panic!("expected ImageGeneration");
        };
        assert_eq!(done.status, AppOperationStatus::Completed);
        assert_eq!(
            done.revised_prompt.as_deref(),
            Some("a grumpy pirate kitty")
        );
        assert_eq!(done.saved_path.as_deref(), Some("/tmp/ig-1.png"));
        let png = done.image_png.as_ref().expect("decoded png bytes");
        assert_eq!(&png[..8], &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

        let HydratedConversationItemContent::ImageGeneration(pending) = &items[1].content else {
            panic!("expected ImageGeneration");
        };
        assert_eq!(pending.status, AppOperationStatus::InProgress);
        assert!(pending.image_png.is_none());
        assert!(pending.saved_path.is_none());

        let HydratedConversationItemContent::ImageGeneration(lying) = &items[2].content else {
            panic!("expected ImageGeneration");
        };
        assert_eq!(lying.status, AppOperationStatus::Completed);
        assert!(lying.image_png.is_some());
    }

    #[test]
    fn test_command_hydration_truncates_large_mobile_fields() {
        let long_command = format!("/bin/sh -lc '{}'", "x".repeat(6000));
        let long_output = "y".repeat(140 * 1024);
        let long_query = "needle".repeat(300);
        let turns = vec![make_turn(
            "t-command-truncate",
            vec![ThreadItem::CommandExecution {
                id: "cmd-1".into(),
                command: long_command,
                cwd: test_abs_path("/tmp"),
                source: Default::default(),
                status: CommandExecutionStatus::Completed,
                command_actions: vec![CommandAction::Search {
                    command: "find . -name '*.swift'".into(),
                    query: Some(long_query),
                    path: Some(".".into()),
                }],
                aggregated_output: Some(long_output),
                exit_code: Some(0),
                duration_ms: Some(10),
                process_id: Some("123".into()),
            }],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        let HydratedConversationItemContent::CommandExecution(data) = &items[0].content else {
            panic!("expected CommandExecution");
        };
        assert!(data.command.len() <= MOBILE_COMMAND_TEXT_CAP_BYTES);
        assert!(data.command.contains("[truncated on mobile]"));
        assert!(data.output.as_ref().is_some_and(|value| {
            value.len() <= MOBILE_COMMAND_OUTPUT_CAP_BYTES
                && value.contains("[output truncated on mobile]")
        }));
        assert!(
            data.actions[0]
                .query
                .as_ref()
                .is_some_and(|value| value.contains("[truncated on mobile]"))
        );
    }

    // ── Streaming partial-JSON extractor (SW-R3) ──────────────────────

    #[test]
    fn streaming_extractor_yields_growing_widget_html_prefix() {
        // Simulate the model streaming a show_widget argument JSON one
        // chunk at a time. Each intermediate buffer should surface the
        // longest safe `widget_code` prefix we can see.
        let chunks = [
            r#"{"app_id":"fit-tracker","title":"Fit","widget_code":"<div"#,
            r#" class=\"app\">"#,
            r#"<h2>Workouts</h2>"#,
            r#"</div>"}"#,
        ];
        let mut buffer = String::new();
        let mut seen_htmls: Vec<String> = Vec::new();
        for chunk in chunks {
            buffer.push_str(chunk);
            let widget = streaming_widget_data_from_partial_arguments(&buffer)
                .expect("partial parse should yield a widget once widget_code is open");
            seen_htmls.push(widget.widget_html);
        }

        // Each subsequent HTML prefix is a superset of the previous one.
        for pair in seen_htmls.windows(2) {
            assert!(
                pair[1].starts_with(&pair[0]),
                "expected growing prefix, got {pair:?}"
            );
        }
        // And the final (complete JSON) pass gives us the fully closed HTML.
        assert_eq!(
            seen_htmls.last().unwrap(),
            "<div class=\"app\"><h2>Workouts</h2></div>"
        );
    }

    #[test]
    fn streaming_extractor_returns_none_before_widget_code_opens() {
        let buffer = r#"{"app_id":"fit","title":"Fit","widget_"#;
        assert!(streaming_widget_data_from_partial_arguments(buffer).is_none());
    }

    #[test]
    fn streaming_extractor_handles_escape_sequences() {
        // Incomplete escape at the cut → trailing backslash dropped
        // until the next delta arrives.
        let buffer = r#"{"widget_code":"<a href=\"#;
        let widget = streaming_widget_data_from_partial_arguments(buffer).unwrap();
        assert_eq!(widget.widget_html, "<a href=");

        // Complete escape → properly decoded.
        let buffer = r#"{"widget_code":"<a href=\"https\""#;
        let widget = streaming_widget_data_from_partial_arguments(buffer).unwrap();
        assert_eq!(widget.widget_html, "<a href=\"https\"");
    }

    #[test]
    fn streaming_extractor_defaults_missing_fields() {
        let buffer = r#"{"widget_code":"<svg/>"#;
        let widget = streaming_widget_data_from_partial_arguments(buffer).unwrap();
        assert_eq!(widget.widget_html, "<svg/>");
        assert_eq!(widget.title, "Widget");
        assert_eq!(widget.width, 800.0);
        assert_eq!(widget.height, 600.0);
        assert_eq!(widget.app_id, None);
        assert!(!widget.is_finalized);
    }

    #[test]
    fn streaming_extractor_reads_dimensions_when_complete() {
        let buffer = r#"{"width":400,"height":240,"widget_code":"<svg/>"#;
        let widget = streaming_widget_data_from_partial_arguments(buffer).unwrap();
        assert_eq!(widget.width, 400.0);
        assert_eq!(widget.height, 240.0);
    }

    #[test]
    fn streaming_extractor_handles_camel_case_alias() {
        let buffer = r#"{"widgetCode":"<svg/>"#;
        let widget = streaming_widget_data_from_partial_arguments(buffer).unwrap();
        assert_eq!(widget.widget_html, "<svg/>");
    }
}
