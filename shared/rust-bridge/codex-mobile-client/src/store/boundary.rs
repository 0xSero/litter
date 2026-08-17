use std::borrow::Cow;
use std::collections::VecDeque;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

use crate::conversation_uniffi::{
    HydratedCommandActionKind, HydratedCommandExecutionData, HydratedConversationItem,
    HydratedConversationItemContent,
};
use crate::types::AppSubagentStatus;
use crate::types::{
    AppModeKind, AppPlanImplementationPromptSnapshot, AppPlanProgressSnapshot, AppThreadGoal,
    PendingApproval, PendingUserInputRequest, ThreadInfo, ThreadKey, ThreadSummaryStatus,
};

use super::snapshot::{
    AppConnectionProgressSnapshot, AppQueuedFollowUpPreview, AppSnapshot, AppVoiceSessionSnapshot,
    ServerHealthSnapshot, ServerSnapshot, ThreadItems, ThreadSnapshot,
};

const LOCAL_USER_MESSAGE_ITEM_PREFIX: &str = "local-user-message:";

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppServerSnapshot {
    pub server_id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub wake_mac: Option<String>,
    pub is_local: bool,
    pub health: AppServerHealth,
    pub transport_state: AppServerTransportState,
    pub capabilities: AppServerCapabilities,
    pub account: Option<crate::types::Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<crate::types::RateLimitSnapshot>,
    pub rate_limits_by_runtime: Vec<AppRateLimitsForRuntime>,
    pub available_models: Option<Vec<crate::types::ModelInfo>>,
    pub agent_runtimes: Vec<crate::types::AgentRuntimeInfo>,
    pub connection_progress: Option<AppConnectionProgressSnapshot>,
    pub usage_stats: Option<AppServerUsageStats>,
    /// Whether the session list on this server has more pages to load via
    /// `AppStore::load_threads_page`. `false` once a full `thread/list`
    /// drain (pull-to-refresh / Sessions screen) has completed.
    pub session_list_has_more: bool,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppServerHealth {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppServerTransportState {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppServerCapabilities {
    pub can_use_transport_actions: bool,
    pub can_browse_directories: bool,
    pub can_start_threads: bool,
    pub can_resume_threads: bool,
    /// Whether the remote server supports paginated turn fetching via
    /// `thread/turns/list` and the `exclude_turns` resume/fork parameter.
    /// Defaults to enabled and flips off when runtime response inspection
    /// detects a legacy remote.
    pub supports_turn_pagination: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppRateLimitsForRuntime {
    pub runtime_kind: crate::types::AgentRuntimeKind,
    pub rate_limits: crate::types::RateLimitSnapshot,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppThreadSnapshot {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub agent_runtime_kind: crate::types::AgentRuntimeKind,
    pub collaboration_mode: AppModeKind,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub effective_approval_policy: Option<crate::types::AppAskForApproval>,
    pub effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    pub hydrated_conversation_items: Vec<HydratedConversationItem>,
    pub queued_follow_ups: Vec<AppQueuedFollowUpPreview>,
    pub active_turn_id: Option<String>,
    pub active_plan_progress: Option<AppPlanProgressSnapshot>,
    pub pending_plan_implementation_prompt: Option<AppPlanImplementationPromptSnapshot>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<crate::types::RateLimits>,
    pub realtime_session_id: Option<String>,
    pub goal: Option<AppThreadGoal>,
    pub stats: Option<AppConversationStats>,
    pub token_usage: Option<AppTokenUsage>,
    /// Cursor for fetching the next older page of turns, or `None` when no
    /// more older turns exist OR pagination is unsupported.
    pub older_turns_cursor: Option<String>,
    /// Whether the first page of turns has been loaded. UI uses this to
    /// gate an initial-load spinner when `exclude_turns` was requested.
    pub initial_turns_loaded: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppThreadStateRecord {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub agent_runtime_kind: crate::types::AgentRuntimeKind,
    pub collaboration_mode: AppModeKind,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub effective_approval_policy: Option<crate::types::AppAskForApproval>,
    pub effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    pub queued_follow_ups: Vec<AppQueuedFollowUpPreview>,
    pub active_turn_id: Option<String>,
    pub active_plan_progress: Option<AppPlanProgressSnapshot>,
    pub pending_plan_implementation_prompt: Option<AppPlanImplementationPromptSnapshot>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<crate::types::RateLimits>,
    pub realtime_session_id: Option<String>,
    pub goal: Option<AppThreadGoal>,
    /// Mirrors `AppThreadSnapshot.older_turns_cursor`. Included so
    /// `ThreadMetadataChanged` events carry pagination state through to
    /// the platform mappers; without this the Kotlin/Swift projection
    /// coerces it back to `None` on every metadata update and
    /// `load_thread_turns_page` appears to lose its cursor.
    pub older_turns_cursor: Option<String>,
    /// Mirrors `AppThreadSnapshot.initial_turns_loaded` for the same
    /// reason.
    pub initial_turns_loaded: bool,
}

/// Merge the canonical items with the local overlay items, producing the
/// display order as *borrows* into both input lists.
///
/// This used to clone every item into the merged vector and then clone each
/// one again during projection. Callers now clone at most once, when they
/// actually need an owned `AppThreadSnapshot`.
fn merged_hydrated_item_refs<'a>(
    items: &'a [HydratedConversationItem],
    local_overlay_items: &'a [HydratedConversationItem],
) -> Vec<&'a HydratedConversationItem> {
    let mut merged: Vec<&'a HydratedConversationItem> =
        Vec::with_capacity(items.len() + local_overlay_items.len());
    merged.extend(items.iter());

    if local_overlay_items.is_empty() {
        return merged;
    }

    let mut selected_overlays: Vec<&'a HydratedConversationItem> = Vec::new();
    for overlay in local_overlay_items {
        if items
            .iter()
            .all(|existing| !same_overlay_semantics(overlay, existing))
            && selected_overlays
                .iter()
                .all(|existing| !same_overlay_semantics(overlay, existing))
        {
            selected_overlays.push(overlay);
        }
    }
    for overlay in selected_overlays {
        insert_overlay_item(&mut merged, overlay);
    }
    merged
}

fn insert_overlay_item<'a>(
    merged: &mut Vec<&'a HydratedConversationItem>,
    overlay: &'a HydratedConversationItem,
) {
    // Bound local user overlays semantically start their turn even when the
    // server has not echoed a UserMessage item yet.
    let insert_at = if is_local_user_turn_boundary_overlay(overlay) {
        overlay.source_turn_id.as_deref().and_then(|turn_id| {
            merged.iter().position(|item| {
                item.source_turn_id.as_deref() == Some(turn_id)
                    && !is_local_user_turn_boundary_overlay(item)
            })
        })
    } else {
        None
    }
    .unwrap_or(merged.len());

    merged.insert(insert_at, overlay);
}

fn is_local_user_turn_boundary_overlay(item: &HydratedConversationItem) -> bool {
    item.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX)
        && item.is_from_user_turn_boundary
        && matches!(&item.content, HydratedConversationItemContent::User(_))
}

/// Rewrite multi-agent target ids into display labels.
///
/// The overwhelmingly common case is "nothing to rewrite"; returning a
/// `Cow::Borrowed` there keeps the caller from paying for a full item clone
/// on every projection.
pub(crate) fn project_hydrated_item<'a>(
    snapshot: &AppSnapshot,
    server_id: &str,
    item: &'a HydratedConversationItem,
) -> Cow<'a, HydratedConversationItem> {
    let HydratedConversationItemContent::MultiAgentAction(data) = &item.content else {
        return Cow::Borrowed(item);
    };

    let projected_targets: Vec<String> = data
        .targets
        .iter()
        .enumerate()
        .map(|(index, target)| {
            data.receiver_thread_ids
                .get(index)
                .and_then(|thread_id| resolve_agent_target_label(snapshot, server_id, thread_id))
                .or_else(|| resolve_agent_target_label(snapshot, server_id, target))
                .unwrap_or_else(|| target.clone())
        })
        .collect();

    if projected_targets == data.targets {
        return Cow::Borrowed(item);
    }

    let mut projected = item.clone();
    projected.content = HydratedConversationItemContent::MultiAgentAction(
        crate::conversation_uniffi::HydratedMultiAgentActionData {
            tool: data.tool.clone(),
            status: data.status,
            prompt: data.prompt.clone(),
            targets: projected_targets,
            receiver_thread_ids: data.receiver_thread_ids.clone(),
            agent_states: data.agent_states.clone(),
        },
    );
    Cow::Owned(projected)
}

fn resolve_agent_target_label(
    snapshot: &AppSnapshot,
    server_id: &str,
    raw: &str,
) -> Option<String> {
    let normalized = sanitized_label_field(Some(raw))?;
    if looks_like_agent_display_label(normalized) {
        return Some(normalized.to_string());
    }

    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: normalized.to_string(),
    };
    let thread = snapshot.threads.get(&key)?;
    agent_display_label(
        thread.info.agent_nickname.as_deref(),
        thread.info.agent_role.as_deref(),
        Some(normalized),
    )
}

fn looks_like_agent_display_label(value: &str) -> bool {
    if !value.ends_with(']') {
        return false;
    }
    let Some(open_bracket) = value.rfind('[') else {
        return false;
    };
    let nickname = value[..open_bracket].trim();
    let role = value[open_bracket + 1..value.len() - 1].trim();
    !nickname.is_empty() && !role.is_empty()
}

fn same_overlay_semantics(
    lhs: &crate::conversation_uniffi::HydratedConversationItem,
    rhs: &crate::conversation_uniffi::HydratedConversationItem,
) -> bool {
    if lhs.id == rhs.id {
        return true;
    }

    match (&lhs.content, &rhs.content) {
        (
            crate::conversation_uniffi::HydratedConversationItemContent::UserInputResponse(
                lhs_data,
            ),
            crate::conversation_uniffi::HydratedConversationItemContent::UserInputResponse(
                rhs_data,
            ),
        ) => lhs.source_turn_id == rhs.source_turn_id && lhs_data == rhs_data,
        (
            crate::conversation_uniffi::HydratedConversationItemContent::User(lhs_data),
            crate::conversation_uniffi::HydratedConversationItemContent::User(rhs_data),
        ) => {
            lhs.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX)
                && lhs_data == rhs_data
                && (
                    // Both bound to the same turn.
                    (lhs.source_turn_id.is_some() && lhs.source_turn_id == rhs.source_turn_id)
                    // Real item arrived via ItemStarted/ItemCompleted without a
                    // turn_id; the overlay is bound so content match is enough.
                    || (lhs.source_turn_id.is_some() && rhs.source_turn_id.is_none())
                )
        }
        _ => false,
    }
}

// ── Conversation statistics (per-thread, computed from hydrated items) ────

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppConversationStats {
    // Messages
    pub total_messages: u32,
    pub user_message_count: u32,
    pub assistant_message_count: u32,
    pub turn_count: u32,
    // Commands
    pub commands_executed: u32,
    pub commands_succeeded: u32,
    pub commands_failed: u32,
    pub total_command_duration_ms: i64,
    // Files
    pub files_changed: u32,
    pub files_added: u32,
    pub files_modified: u32,
    pub files_deleted: u32,
    pub diff_additions: u32,
    pub diff_deletions: u32,
    // Tools
    pub tool_call_count: u32,
    pub mcp_tool_call_count: u32,
    pub dynamic_tool_call_count: u32,
    pub web_search_count: u32,
    // Media
    pub image_count: u32,
    pub code_review_count: u32,
    pub widget_count: u32,
    // Timing
    pub session_duration_ms: Option<i64>,
}

// ── Token usage (per-thread, from server notifications) ──────────────────

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppTokenUsage {
    pub total_tokens: i64,
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_output_tokens: i64,
    pub context_window: Option<i64>,
}

// ── Server usage statistics (per-server, computed from thread snapshots) ─

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppServerUsageStats {
    pub total_threads: u32,
    pub active_threads: u32,
    pub total_tokens: u64,
    pub tokens_by_thread: Vec<AppTokensByThreadEntry>,
    pub activity_by_day: Vec<AppActivityByDayEntry>,
    pub model_usage: Vec<AppModelUsageEntry>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppTokensByThreadEntry {
    pub thread_title: String,
    pub thread_id: String,
    pub tokens: u64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppActivityByDayEntry {
    pub date_epoch: i64,
    pub turn_count: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppModelUsageEntry {
    pub model: String,
    pub thread_count: u32,
}

// ── Session summary ──────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppSessionSummary {
    pub key: ThreadKey,
    pub agent_runtime_kind: crate::types::AgentRuntimeKind,
    pub server_display_name: String,
    pub server_host: String,
    pub title: String,
    pub preview: String,
    pub cwd: String,
    pub model: String,
    pub model_provider: String,
    /// Sub-agent parent thread id. `None` for fork lineage; see
    /// `forked_from_id` for that.
    pub parent_thread_id: Option<String>,
    /// Source thread id when this thread was created by `forkThread` /
    /// `forkThreadFromMessage`. Independent from `parent_thread_id`, which
    /// is sub-agent-only.
    pub forked_from_id: Option<String>,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub agent_display_label: Option<String>,
    pub agent_status: AppSubagentStatus,
    pub updated_at: Option<i64>,
    pub has_active_turn: bool,
    pub is_resumed: bool,
    pub is_subagent: bool,
    pub is_fork: bool,
    // Display-specific fields
    pub last_response_preview: Option<String>,
    // `source_turn_id` of the assistant item that produced
    // `last_response_preview`. Home-dashboard preview uses this as its
    // crossfade key so the text only re-transitions when a NEW assistant
    // message arrives — not when the user sends a new prompt (which flips
    // `stats.turn_count` even though the preview text hasn't changed yet).
    pub last_response_turn_id: Option<String>,
    pub last_user_message: Option<String>,
    pub last_tool_label: Option<String>,
    pub recent_tool_log: Vec<AppToolLogEntry>,
    // Bounds of the most recent turn, in milliseconds since epoch. The home
    // dashboard's zoom-4 stopwatch chip uses `start` + either `end` or "now"
    // (picked by the iOS side based on `has_active_turn`) to show the running
    // or completed turn duration. `None` when the thread has no turn-id'd
    // items yet.
    pub last_turn_start_ms: Option<i64>,
    pub last_turn_end_ms: Option<i64>,
    // Stats (None when thread has no hydrated items)
    pub stats: Option<AppConversationStats>,
    pub token_usage: Option<AppTokenUsage>,
    pub goal: Option<AppThreadGoal>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppToolLogEntry {
    pub tool: String,
    pub detail: String,
    pub status: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppSnapshotRecord {
    pub servers: Vec<AppServerSnapshot>,
    pub threads: Vec<AppThreadSnapshot>,
    pub session_summaries: Vec<AppSessionSummary>,
    pub agent_directory_version: u64,
    pub active_thread: Option<ThreadKey>,
    pub pending_approvals: Vec<PendingApproval>,
    pub pending_user_inputs: Vec<PendingUserInputRequest>,
    pub voice_session: AppVoiceSessionSnapshot,
    pub terminal_sessions: Vec<crate::store::snapshot::TerminalSessionSnapshot>,
    pub active_terminal_id: Option<String>,
}

impl TryFrom<AppSnapshot> for AppSnapshotRecord {
    type Error = String;

    fn try_from(snapshot: AppSnapshot) -> Result<Self, Self::Error> {
        let session_summaries = session_summaries_from_snapshot(&snapshot);
        let agent_directory_version = agent_directory_version(&session_summaries);

        let mut servers = snapshot
            .servers
            .values()
            .cloned()
            .map(|server| {
                let transport_state = AppServerTransportState::from(server.health.clone());
                let can_use_transport_actions =
                    transport_state == AppServerTransportState::Connected;

                let usage_stats = compute_server_usage_stats(&snapshot, &server.server_id);
                let session_list_has_more =
                    snapshot
                        .session_pages
                        .iter()
                        .any(|((page_server_id, _), page)| {
                            page_server_id == &server.server_id && page.has_more
                        });

                AppServerSnapshot {
                    server_id: server.server_id,
                    display_name: server.display_name,
                    host: server.host,
                    port: server.port,
                    wake_mac: server.wake_mac,
                    is_local: server.is_local,
                    health: server.health.into(),
                    transport_state,
                    capabilities: AppServerCapabilities {
                        can_use_transport_actions,
                        can_browse_directories: can_use_transport_actions,
                        can_start_threads: can_use_transport_actions,
                        can_resume_threads: can_use_transport_actions,
                        supports_turn_pagination: server.supports_turn_pagination,
                    },
                    account: server.account,
                    requires_openai_auth: server.requires_openai_auth,
                    rate_limits: server.rate_limits,
                    rate_limits_by_runtime: {
                        let mut entries = server
                            .rate_limits_by_runtime
                            .into_iter()
                            .map(|(runtime_kind, rate_limits)| AppRateLimitsForRuntime {
                                runtime_kind,
                                rate_limits,
                            })
                            .collect::<Vec<_>>();
                        entries.sort_by_key(|entry| entry.runtime_kind.clone());
                        entries
                    },
                    available_models: server.available_models,
                    agent_runtimes: server.agent_runtimes,
                    connection_progress: server.connection_progress,
                    usage_stats,
                    session_list_has_more,
                }
            })
            .collect::<Vec<_>>();
        servers.sort_by(|lhs, rhs| lhs.server_id.cmp(&rhs.server_id));

        let mut threads = snapshot
            .threads
            .values()
            .map(|thread| app_thread_snapshot_from_state(&snapshot, thread))
            .collect::<Result<Vec<_>, String>>()?;
        threads.sort_by(|lhs, rhs| lhs.key.thread_id.cmp(&rhs.key.thread_id));

        Ok(Self {
            servers,
            threads,
            session_summaries,
            agent_directory_version,
            active_thread: snapshot.active_thread,
            pending_approvals: snapshot.pending_approvals,
            pending_user_inputs: snapshot.pending_user_inputs,
            voice_session: snapshot.voice_session,
            terminal_sessions: snapshot.terminal_sessions,
            active_terminal_id: snapshot.active_terminal_id,
        })
    }
}

pub(crate) fn app_thread_snapshot_from_state(
    snapshot: &AppSnapshot,
    thread: &ThreadSnapshot,
) -> Result<AppThreadSnapshot, String> {
    let merged = merged_hydrated_item_refs(&thread.items, &thread.local_overlay_items);
    let stats = if merged.is_empty() {
        None
    } else {
        // Target-label projection only rewrites `MultiAgentAction.targets`,
        // which no statistic reads, so the stats are identical whether they
        // are derived pre- or post-projection.
        Some(
            thread
                .activity_cache
                .merged(&thread.items, &thread.local_overlay_items, &merged)
                .stats
                .clone(),
        )
    };
    let hydrated_conversation_items = merged
        .into_iter()
        .map(|item| project_hydrated_item(snapshot, &thread.key.server_id, item).into_owned())
        .collect::<Vec<_>>();
    Ok(AppThreadSnapshot {
        key: thread.key.clone(),
        info: thread.info.clone(),
        agent_runtime_kind: thread.agent_runtime_kind.clone(),
        collaboration_mode: thread.collaboration_mode,
        model: thread.model.clone(),
        reasoning_effort: thread.reasoning_effort.clone(),
        effective_approval_policy: thread.effective_approval_policy.clone(),
        effective_sandbox_policy: thread.effective_sandbox_policy.clone(),
        hydrated_conversation_items,
        queued_follow_ups: thread
            .queued_follow_ups
            .iter()
            .map(|preview| AppQueuedFollowUpPreview {
                id: preview.id.clone(),
                kind: preview.kind,
                text: preview.text.clone(),
            })
            .collect(),
        active_turn_id: thread.active_turn_id.clone(),
        active_plan_progress: thread.active_plan_progress.clone(),
        pending_plan_implementation_prompt: plan_implementation_prompt_for_thread(snapshot, thread),
        context_tokens_used: thread.context_tokens_used,
        model_context_window: thread.model_context_window,
        rate_limits: thread.rate_limits.clone(),
        realtime_session_id: thread.realtime_session_id.clone(),
        goal: thread.goal.clone(),
        stats,
        token_usage: thread_token_usage(thread),
        older_turns_cursor: thread.older_turns_cursor.clone(),
        initial_turns_loaded: thread.initial_turns_loaded,
    })
}

fn app_thread_state_record_from_state(
    snapshot: &AppSnapshot,
    thread: &ThreadSnapshot,
) -> Result<AppThreadStateRecord, String> {
    Ok(AppThreadStateRecord {
        key: thread.key.clone(),
        info: thread.info.clone(),
        agent_runtime_kind: thread.agent_runtime_kind.clone(),
        collaboration_mode: thread.collaboration_mode,
        model: thread.model.clone(),
        reasoning_effort: thread.reasoning_effort.clone(),
        effective_approval_policy: thread.effective_approval_policy.clone(),
        effective_sandbox_policy: thread.effective_sandbox_policy.clone(),
        queued_follow_ups: thread
            .queued_follow_ups
            .iter()
            .map(|preview| AppQueuedFollowUpPreview {
                id: preview.id.clone(),
                kind: preview.kind,
                text: preview.text.clone(),
            })
            .collect(),
        active_turn_id: thread.active_turn_id.clone(),
        active_plan_progress: thread.active_plan_progress.clone(),
        pending_plan_implementation_prompt: plan_implementation_prompt_for_thread(snapshot, thread),
        context_tokens_used: thread.context_tokens_used,
        model_context_window: thread.model_context_window,
        rate_limits: thread.rate_limits.clone(),
        realtime_session_id: thread.realtime_session_id.clone(),
        goal: thread.goal.clone(),
        older_turns_cursor: thread.older_turns_cursor.clone(),
        initial_turns_loaded: thread.initial_turns_loaded,
    })
}

fn plan_implementation_prompt_for_thread(
    snapshot: &AppSnapshot,
    thread: &ThreadSnapshot,
) -> Option<AppPlanImplementationPromptSnapshot> {
    let source_turn_id = thread.pending_plan_implementation_turn_id.clone()?;
    if thread.active_turn_id.is_some()
        || !thread.queued_follow_ups.is_empty()
        || snapshot.pending_approvals.iter().any(|approval| {
            approval.server_id == thread.key.server_id
                && approval.thread_id.as_deref() == Some(thread.key.thread_id.as_str())
        })
        || snapshot.pending_user_inputs.iter().any(|request| {
            request.server_id == thread.key.server_id && request.thread_id == thread.key.thread_id
        })
    {
        return None;
    }
    Some(AppPlanImplementationPromptSnapshot { source_turn_id })
}

pub(crate) fn session_summaries_from_snapshot(snapshot: &AppSnapshot) -> Vec<AppSessionSummary> {
    let mut session_summaries = snapshot
        .threads
        .values()
        .map(|thread| app_session_summary(thread, snapshot.servers.get(&thread.key.server_id)))
        .collect::<Vec<_>>();
    sort_session_summaries(&mut session_summaries);
    session_summaries
}

/// Minimal placeholder summary used only when a per-item event fires for a
/// thread that has been removed between the mutation and the emit read.
/// The ensuing `ThreadRemoved` event will make platform listeners drop
/// this row anyway, so every other field is trivially defaulted.
pub(crate) fn empty_session_summary(key: ThreadKey) -> AppSessionSummary {
    AppSessionSummary {
        agent_runtime_kind: "codex".to_string(),
        server_display_name: key.server_id.clone(),
        server_host: key.server_id.clone(),
        key,
        title: String::new(),
        preview: String::new(),
        cwd: String::new(),
        model: String::new(),
        model_provider: String::new(),
        parent_thread_id: None,
        forked_from_id: None,
        agent_nickname: None,
        agent_role: None,
        agent_display_label: None,
        agent_status: AppSubagentStatus::Unknown,
        updated_at: None,
        has_active_turn: false,
        is_resumed: false,
        is_subagent: false,
        is_fork: false,
        last_response_preview: None,
        last_response_turn_id: None,
        last_user_message: None,
        last_tool_label: None,
        recent_tool_log: Vec::new(),
        last_turn_start_ms: None,
        last_turn_end_ms: None,
        stats: None,
        token_usage: None,
        goal: None,
    }
}

pub(crate) fn app_session_summary(
    thread: &ThreadSnapshot,
    server: Option<&ServerSnapshot>,
) -> AppSessionSummary {
    let preview = thread.info.preview.as_deref().unwrap_or_default();
    let title = {
        thread
            .info
            .title
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .or_else(|| {
                let trimmed_preview = preview.trim();
                (!trimmed_preview.is_empty()).then(|| trimmed_preview.to_string())
            })
            .unwrap_or_else(|| "Untitled session".to_string())
    };
    let sanitize_id = |value: &Option<String>| -> Option<String> {
        value
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    };
    let parent_thread_id = sanitize_id(&thread.info.parent_thread_id);
    let forked_from_id = sanitize_id(&thread.info.forked_from_id);
    let has_agent_label = thread
        .info
        .agent_nickname
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty())
        || thread
            .info
            .agent_role
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty());
    // Sub-agent: spawned by another thread (parent_thread_id) and tagged
    // with an agent label. Fork: created via forkThread / forkThreadFromMessage
    // (forked_from_id). The two are mutually exclusive in practice.
    let is_subagent = parent_thread_id.is_some() && has_agent_label;
    let is_fork = forked_from_id.is_some();

    // Derive conversation activity from hydrated items (if any). Memoized on
    // `thread.items`' revision — this runs on every metadata/item emit.
    let activity = thread.activity_cache.items_only(&thread.items);

    AppSessionSummary {
        key: thread.key.clone(),
        agent_runtime_kind: thread.agent_runtime_kind.clone(),
        server_display_name: server
            .map(|server| server.display_name.clone())
            .unwrap_or_else(|| thread.key.server_id.clone()),
        server_host: server
            .map(|server| server.host.clone())
            .unwrap_or_else(|| thread.key.server_id.clone()),
        title,
        preview: preview.to_string(),
        cwd: thread.info.cwd.clone().unwrap_or_default(),
        model: thread
            .info
            .model
            .clone()
            .or_else(|| thread.model.clone())
            .unwrap_or_default(),
        model_provider: thread.info.model_provider.clone().unwrap_or_default(),
        parent_thread_id,
        forked_from_id,
        agent_nickname: thread.info.agent_nickname.clone(),
        agent_role: thread.info.agent_role.clone(),
        agent_display_label: agent_display_label(
            thread.info.agent_nickname.as_deref(),
            thread.info.agent_role.as_deref(),
            None,
        ),
        agent_status: thread
            .info
            .agent_status
            .as_deref()
            .map(AppSubagentStatus::from_raw)
            .unwrap_or(AppSubagentStatus::Unknown),
        updated_at: thread.info.updated_at,
        has_active_turn: thread_has_active_turn(thread),
        is_resumed: thread.is_resumed,
        is_subagent,
        is_fork,
        last_response_preview: activity.last_response.clone(),
        last_response_turn_id: activity.last_response_turn_id.clone(),
        last_user_message: activity.last_user_message.clone(),
        last_tool_label: activity.last_tool.clone(),
        recent_tool_log: activity.log.clone(),
        last_turn_start_ms: activity.last_turn_start_ms,
        last_turn_end_ms: activity.last_turn_end_ms,
        stats: if thread.items.is_empty() {
            None
        } else {
            Some(activity.stats.clone())
        },
        token_usage: thread_token_usage(thread),
        goal: thread.goal.clone(),
    }
}

fn thread_token_usage(thread: &ThreadSnapshot) -> Option<AppTokenUsage> {
    let used = thread.context_tokens_used?;
    Some(AppTokenUsage {
        total_tokens: used as i64,
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_output_tokens: 0,
        context_window: thread.model_context_window.map(|w| w as i64),
    })
}

fn compute_server_usage_stats(
    snapshot: &AppSnapshot,
    server_id: &str,
) -> Option<AppServerUsageStats> {
    let server_threads: Vec<&ThreadSnapshot> = snapshot
        .threads
        .values()
        .filter(|t| t.key.server_id == server_id)
        .collect();

    if server_threads.is_empty() {
        return None;
    }

    let total_threads = server_threads.len() as u32;
    let active_threads = server_threads
        .iter()
        .filter(|t| thread_has_active_turn(t))
        .count() as u32;

    let mut total_tokens: u64 = 0;
    let mut tokens_by_thread = Vec::new();
    let mut day_buckets: std::collections::HashMap<i64, u32> = std::collections::HashMap::new();
    let mut model_counts: std::collections::HashMap<String, u32> = std::collections::HashMap::new();

    for thread in &server_threads {
        // Token usage per thread
        if let Some(tokens) = thread.context_tokens_used {
            total_tokens += tokens;
            let title = thread
                .info
                .title
                .as_deref()
                .or(thread.info.preview.as_deref())
                .unwrap_or("Untitled")
                .to_string();
            tokens_by_thread.push(AppTokensByThreadEntry {
                thread_title: title,
                thread_id: thread.key.thread_id.clone(),
                tokens,
            });
        }

        // Activity by day (bucket by updated_at date, midnight UTC)
        if let Some(ts) = thread.info.updated_at {
            let day_epoch = (ts / 86400) * 86400; // floor to midnight
            *day_buckets.entry(day_epoch).or_insert(0) += 1;
        }

        // Model usage
        let model = thread
            .info
            .model
            .clone()
            .or_else(|| thread.model.clone())
            .unwrap_or_else(|| "unknown".to_string());
        *model_counts.entry(model).or_insert(0) += 1;
    }

    tokens_by_thread.sort_by(|a, b| b.tokens.cmp(&a.tokens));

    let mut activity_by_day: Vec<AppActivityByDayEntry> = day_buckets
        .into_iter()
        .map(|(date_epoch, turn_count)| AppActivityByDayEntry {
            date_epoch,
            turn_count,
        })
        .collect();
    activity_by_day.sort_by_key(|e| e.date_epoch);

    let mut model_usage: Vec<AppModelUsageEntry> = model_counts
        .into_iter()
        .map(|(model, thread_count)| AppModelUsageEntry {
            model,
            thread_count,
        })
        .collect();
    model_usage.sort_by(|a, b| b.thread_count.cmp(&a.thread_count));

    Some(AppServerUsageStats {
        total_threads,
        active_threads,
        total_tokens,
        tokens_by_thread,
        activity_by_day,
        model_usage,
    })
}

pub(crate) struct ConversationActivity {
    last_response: Option<String>,
    last_response_turn_id: Option<String>,
    last_user_message: Option<String>,
    last_tool: Option<String>,
    stats: AppConversationStats,
    log: Vec<AppToolLogEntry>,
    last_turn_start_ms: Option<i64>,
    last_turn_end_ms: Option<i64>,
}

/// Memoized [`extract_conversation_activity`] results for one thread.
///
/// The walk is O(items) and used to run from scratch on *every* metadata and
/// item event, for both the raw item list (`app_session_summary`) and the
/// overlay-merged list (`app_thread_snapshot_from_state`). Both are keyed on
/// the globally-unique [`ThreadItems::revision`] values they were derived
/// from, so any mutation of either list invalidates the matching entry and
/// nothing else can go stale.
#[derive(Default)]
pub(crate) struct ThreadActivityCache {
    inner: std::sync::Mutex<ThreadActivityCacheInner>,
}

#[derive(Default)]
struct ThreadActivityCacheInner {
    items_only: Option<(u64, Arc<ConversationActivity>)>,
    merged: Option<((u64, u64), Arc<ConversationActivity>)>,
}

impl ThreadActivityCache {
    pub(crate) fn items_only(&self, items: &ThreadItems) -> Arc<ConversationActivity> {
        let key = items.revision();
        if let Some((cached_key, cached)) = self
            .inner
            .lock()
            .expect("thread activity cache poisoned")
            .items_only
            .as_ref()
            && *cached_key == key
        {
            return Arc::clone(cached);
        }
        let value = Arc::new(extract_conversation_activity(items.as_slice()));
        self.inner
            .lock()
            .expect("thread activity cache poisoned")
            .items_only = Some((key, Arc::clone(&value)));
        value
    }

    pub(crate) fn merged(
        &self,
        items: &ThreadItems,
        local_overlay_items: &ThreadItems,
        merged: &[&HydratedConversationItem],
    ) -> Arc<ConversationActivity> {
        let key = (items.revision(), local_overlay_items.revision());
        if let Some((cached_key, cached)) = self
            .inner
            .lock()
            .expect("thread activity cache poisoned")
            .merged
            .as_ref()
            && *cached_key == key
        {
            return Arc::clone(cached);
        }
        let value = Arc::new(extract_conversation_activity(merged.iter().copied()));
        self.inner
            .lock()
            .expect("thread activity cache poisoned")
            .merged = Some((key, Arc::clone(&value)));
        value
    }
}

impl Clone for ThreadActivityCache {
    fn clone(&self) -> Self {
        let inner = self.inner.lock().expect("thread activity cache poisoned");
        Self {
            inner: std::sync::Mutex::new(ThreadActivityCacheInner {
                items_only: inner.items_only.clone(),
                merged: inner.merged.clone(),
            }),
        }
    }
}

impl std::fmt::Debug for ThreadActivityCache {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ThreadActivityCache")
    }
}

/// Tool-log entry in its unformatted form.
///
/// `extract_conversation_activity` used to `format!` an `AppToolLogEntry`
/// for every tool item in the thread and then throw all but the last 8 away.
/// These borrow from the items instead and only the surviving few get
/// materialized.
enum ToolLogSeed<'a> {
    Bash {
        command: &'a str,
        status: crate::types::AppOperationStatus,
    },
    Edit {
        path: &'a str,
        status: crate::types::AppOperationStatus,
    },
    Mcp {
        tool: &'a str,
        status: crate::types::AppOperationStatus,
    },
    Tool {
        tool: &'a str,
        status: crate::types::AppOperationStatus,
    },
    WebSearch {
        query: &'a str,
        in_progress: bool,
    },
    Explore {
        reads: u32,
        searches: u32,
        listings: u32,
        fallback: u32,
        count: u32,
        in_progress: bool,
    },
}

/// Number of tool-log entries the session summary keeps.
const RECENT_TOOL_LOG_LIMIT: usize = 8;

impl ToolLogSeed<'_> {
    fn materialize(self) -> AppToolLogEntry {
        match self {
            Self::Bash { command, status } => AppToolLogEntry {
                tool: "Bash".to_string(),
                detail: command.to_string(),
                status: format!("{status:?}").to_lowercase(),
            },
            Self::Edit { path, status } => AppToolLogEntry {
                tool: "Edit".to_string(),
                detail: path.to_string(),
                status: format!("{status:?}").to_lowercase(),
            },
            Self::Mcp { tool, status } => AppToolLogEntry {
                tool: "MCP".to_string(),
                detail: tool.to_string(),
                status: format!("{status:?}").to_lowercase(),
            },
            Self::Tool { tool, status } => AppToolLogEntry {
                tool: "Tool".to_string(),
                detail: tool.to_string(),
                status: format!("{status:?}").to_lowercase(),
            },
            Self::WebSearch { query, in_progress } => AppToolLogEntry {
                tool: "WebSearch".to_string(),
                detail: query.to_string(),
                status: if in_progress {
                    "inprogress".to_string()
                } else {
                    "completed".to_string()
                },
            },
            Self::Explore {
                reads,
                searches,
                listings,
                fallback,
                count,
                in_progress,
            } => {
                let prefix = if in_progress { "Exploring" } else { "Explored" };
                let mut parts: Vec<String> = Vec::new();
                if reads > 0 {
                    parts.push(format!(
                        "{} {}",
                        reads,
                        if reads == 1 { "file" } else { "files" }
                    ));
                }
                if searches > 0 {
                    parts.push(format!(
                        "{} {}",
                        searches,
                        if searches == 1 { "search" } else { "searches" }
                    ));
                }
                if listings > 0 {
                    parts.push(format!(
                        "{} {}",
                        listings,
                        if listings == 1 { "listing" } else { "listings" }
                    ));
                }
                if fallback > 0 {
                    parts.push(format!(
                        "{} {}",
                        fallback,
                        if fallback == 1 { "step" } else { "steps" }
                    ));
                }
                let detail = if parts.is_empty() {
                    format!("{} {} step{}", prefix, count, if count == 1 { "" } else { "s" })
                } else {
                    format!("{} {}", prefix, parts.join(", "))
                };
                AppToolLogEntry {
                    tool: "Explore".to_string(),
                    detail,
                    status: if in_progress {
                        "inprogress".to_string()
                    } else {
                        "completed".to_string()
                    },
                }
            }
        }
    }
}

/// Walk conversation items to extract full stats, last activity, and tool log.
fn extract_conversation_activity<'a, I>(items: I) -> ConversationActivity
where
    I: IntoIterator<Item = &'a HydratedConversationItem>,
    I::IntoIter: DoubleEndedIterator + Clone,
{
    let items = items.into_iter();
    let mut last_response: Option<String> = None;
    let mut last_response_turn_id: Option<String> = None;
    let mut last_user_message: Option<String> = None;
    let mut last_tool: Option<String> = None;

    // Stats accumulators
    let mut total_messages: u32 = 0;
    let mut user_message_count: u32 = 0;
    let mut assistant_message_count: u32 = 0;
    let mut commands_executed: u32 = 0;
    let mut commands_succeeded: u32 = 0;
    let mut commands_failed: u32 = 0;
    let mut total_command_duration_ms: i64 = 0;
    let mut files_changed: u32 = 0;
    let mut files_added: u32 = 0;
    let mut files_modified: u32 = 0;
    let mut files_deleted: u32 = 0;
    let mut diff_additions: u32 = 0;
    let mut diff_deletions: u32 = 0;
    let mut tool_call_count: u32 = 0;
    let mut mcp_tool_call_count: u32 = 0;
    let mut dynamic_tool_call_count: u32 = 0;
    let mut web_search_count: u32 = 0;
    let mut image_count: u32 = 0;
    let mut code_review_count: u32 = 0;
    let mut widget_count: u32 = 0;
    let mut seen_turn_ids: std::collections::HashSet<&str> = std::collections::HashSet::new();
    let mut first_ts: Option<f64> = None;
    let mut last_ts: Option<f64> = None;
    // Bounded to the last `RECENT_TOOL_LOG_LIMIT` seeds: everything older is
    // discarded before it is ever formatted.
    let mut log_entries: VecDeque<ToolLogSeed<'a>> = VecDeque::with_capacity(RECENT_TOOL_LOG_LIMIT);

    // Turn bounds: track the currently-accumulating turn so we end up with
    // the min/max timestamps of items in the *last* turn seen.
    let mut current_turn_id: Option<&str> = None;
    let mut current_turn_min: Option<f64> = None;
    let mut current_turn_max: Option<f64> = None;

    // Exploration grouping: accumulate consecutive pure-exploration command
    // items (reads, searches, listings) and emit a single rolled-up
    // `"Explore"` log entry when a non-exploration item breaks the run (or
    // at the end of the walk). Matches the conversation view's grouping.
    let mut exploration_reads: u32 = 0;
    let mut exploration_searches: u32 = 0;
    let mut exploration_listings: u32 = 0;
    let mut exploration_fallback: u32 = 0;
    let mut exploration_count: u32 = 0;
    let mut exploration_in_progress = false;

    fn push_log_seed<'s>(log_entries: &mut VecDeque<ToolLogSeed<'s>>, seed: ToolLogSeed<'s>) {
        if log_entries.len() == RECENT_TOOL_LOG_LIMIT {
            log_entries.pop_front();
        }
        log_entries.push_back(seed);
    }

    fn flush_exploration<'s>(
        log_entries: &mut VecDeque<ToolLogSeed<'s>>,
        reads: &mut u32,
        searches: &mut u32,
        listings: &mut u32,
        fallback: &mut u32,
        count: &mut u32,
        in_progress: &mut bool,
    ) {
        if *count == 0 {
            return;
        }
        push_log_seed(
            log_entries,
            ToolLogSeed::Explore {
                reads: *reads,
                searches: *searches,
                listings: *listings,
                fallback: *fallback,
                count: *count,
                in_progress: *in_progress,
            },
        );
        *reads = 0;
        *searches = 0;
        *listings = 0;
        *fallback = 0;
        *count = 0;
        *in_progress = false;
    }

    fn is_pure_exploration(data: &HydratedCommandExecutionData) -> bool {
        if data.actions.is_empty() {
            return false;
        }
        data.actions.iter().all(|action| {
            matches!(
                action.kind,
                HydratedCommandActionKind::Read
                    | HydratedCommandActionKind::Search
                    | HydratedCommandActionKind::ListFiles
            )
        })
    }

    // Forward pass — collect everything
    for item in items.clone() {
        // Track timestamps for session duration
        if let Some(ts) = item.timestamp {
            if first_ts.is_none() {
                first_ts = Some(ts);
            }
            last_ts = Some(ts);
        }

        // Turn counting via distinct source_turn_id + per-turn timestamp
        // bounds. `current_turn_*` collapses to the last turn encountered.
        if let Some(turn_id) = item.source_turn_id.as_deref() {
            if matches!(&item.content, HydratedConversationItemContent::User(_)) {
                seen_turn_ids.insert(turn_id);
            }
            if current_turn_id != Some(turn_id) {
                current_turn_id = Some(turn_id);
                current_turn_min = item.timestamp;
                current_turn_max = item.timestamp;
            } else if let Some(ts) = item.timestamp {
                current_turn_min = Some(current_turn_min.map_or(ts, |m| m.min(ts)));
                current_turn_max = Some(current_turn_max.map_or(ts, |m| m.max(ts)));
            }
        }

        // Non-CommandExecution (or non-pure-exploration command) breaks the
        // exploration run — flush the buffer before handling the item.
        let is_exploration_command = matches!(
            &item.content,
            HydratedConversationItemContent::CommandExecution(data) if is_pure_exploration(data)
        );
        if !is_exploration_command {
            flush_exploration(
                &mut log_entries,
                &mut exploration_reads,
                &mut exploration_searches,
                &mut exploration_listings,
                &mut exploration_fallback,
                &mut exploration_count,
                &mut exploration_in_progress,
            );
        }

        match &item.content {
            HydratedConversationItemContent::User(data) => {
                user_message_count += 1;
                total_messages += 1;
                image_count += data.image_data_uris.len() as u32;
            }
            HydratedConversationItemContent::Assistant(_) => {
                assistant_message_count += 1;
                total_messages += 1;
            }
            HydratedConversationItemContent::CodeReview(_) => {
                code_review_count += 1;
                assistant_message_count += 1;
                total_messages += 1;
            }
            HydratedConversationItemContent::CommandExecution(data) => {
                commands_executed += 1;
                tool_call_count += 1;
                match data.status {
                    crate::types::AppOperationStatus::Completed => commands_succeeded += 1,
                    crate::types::AppOperationStatus::Failed => commands_failed += 1,
                    _ => {}
                }
                if let Some(ms) = data.duration_ms {
                    total_command_duration_ms += ms;
                }
                if is_pure_exploration(data) {
                    // Group consecutive exploration commands. Action kinds
                    // get summed; the buffer flushes into a single `Explore`
                    // entry once the run ends.
                    exploration_count += 1;
                    let in_progress = matches!(
                        data.status,
                        crate::types::AppOperationStatus::Pending
                            | crate::types::AppOperationStatus::InProgress
                    );
                    if in_progress {
                        exploration_in_progress = true;
                    }
                    for action in &data.actions {
                        match action.kind {
                            HydratedCommandActionKind::Read => exploration_reads += 1,
                            HydratedCommandActionKind::Search => exploration_searches += 1,
                            HydratedCommandActionKind::ListFiles => exploration_listings += 1,
                            HydratedCommandActionKind::Unknown => exploration_fallback += 1,
                        }
                    }
                } else {
                    push_log_seed(
                        &mut log_entries,
                        ToolLogSeed::Bash {
                            command: data.command.trim(),
                            status: data.status,
                        },
                    );
                }
            }
            HydratedConversationItemContent::FileChange(data) => {
                for entry in &data.changes {
                    files_changed += 1;
                    tool_call_count += 1;
                    diff_additions += entry.additions;
                    diff_deletions += entry.deletions;
                    let kind_lower = entry.kind.to_lowercase();
                    if kind_lower.contains("add") {
                        files_added += 1;
                    } else if kind_lower.contains("delete") || kind_lower.contains("remove") {
                        files_deleted += 1;
                    } else {
                        files_modified += 1;
                    }
                    push_log_seed(
                        &mut log_entries,
                        ToolLogSeed::Edit {
                            path: entry.path.as_str(),
                            status: data.status,
                        },
                    );
                }
            }
            HydratedConversationItemContent::McpToolCall(data) => {
                mcp_tool_call_count += 1;
                tool_call_count += 1;
                push_log_seed(
                    &mut log_entries,
                    ToolLogSeed::Mcp {
                        tool: data.tool.as_str(),
                        status: data.status,
                    },
                );
            }
            HydratedConversationItemContent::DynamicToolCall(data) => {
                dynamic_tool_call_count += 1;
                tool_call_count += 1;
                push_log_seed(
                    &mut log_entries,
                    ToolLogSeed::Tool {
                        tool: data.tool.as_str(),
                        status: data.status,
                    },
                );
            }
            HydratedConversationItemContent::WebSearch(data) => {
                web_search_count += 1;
                tool_call_count += 1;
                push_log_seed(
                    &mut log_entries,
                    ToolLogSeed::WebSearch {
                        query: data.query.as_str(),
                        in_progress: data.is_in_progress,
                    },
                );
            }
            HydratedConversationItemContent::ImageView(_) => {
                image_count += 1;
            }
            HydratedConversationItemContent::Widget(_) => {
                widget_count += 1;
            }
            _ => {}
        }
    }

    // Trailing run of exploration commands at the end of the thread.
    flush_exploration(
        &mut log_entries,
        &mut exploration_reads,
        &mut exploration_searches,
        &mut exploration_listings,
        &mut exploration_fallback,
        &mut exploration_count,
        &mut exploration_in_progress,
    );

    // Reverse pass for last assistant message, last user message, and last tool label
    for item in items.rev() {
        if last_response.is_some() && last_user_message.is_some() && last_tool.is_some() {
            break;
        }
        match &item.content {
            HydratedConversationItemContent::Assistant(data) if last_response.is_none() => {
                let text = data.text.trim();
                if !text.is_empty() {
                    last_response = Some(text.to_string());
                    last_response_turn_id = item.source_turn_id.clone();
                }
            }
            HydratedConversationItemContent::User(data) if last_user_message.is_none() => {
                let text = data.text.trim();
                if !text.is_empty() {
                    last_user_message = Some(text.to_string());
                }
            }
            HydratedConversationItemContent::CommandExecution(data) if last_tool.is_none() => {
                let cmd = data.command.trim();
                last_tool = Some(format!("Bash {}", cmd));
            }
            HydratedConversationItemContent::FileChange(data) if last_tool.is_none() => {
                if let Some(entry) = data.changes.first() {
                    last_tool = Some(format!("Edit {}", entry.path));
                }
            }
            HydratedConversationItemContent::McpToolCall(data) if last_tool.is_none() => {
                last_tool = Some(format!("MCP {}", data.tool));
            }
            HydratedConversationItemContent::DynamicToolCall(data) if last_tool.is_none() => {
                last_tool = Some(format!("Tool {}", data.tool));
            }
            _ => {}
        }
    }

    let session_duration_ms = match (first_ts, last_ts) {
        (Some(first), Some(last)) if last > first => Some(((last - first) * 1000.0) as i64),
        _ => None,
    };

    // `log_entries` is already bounded to the last `RECENT_TOOL_LOG_LIMIT`
    // seeds; only these get formatted.
    let log = log_entries
        .into_iter()
        .map(ToolLogSeed::materialize)
        .collect::<Vec<_>>();

    let last_turn_start_ms = current_turn_min.map(|ts| (ts * 1000.0) as i64);
    let last_turn_end_ms = current_turn_max.map(|ts| (ts * 1000.0) as i64);

    ConversationActivity {
        last_response,
        last_response_turn_id,
        last_user_message,
        last_tool,
        stats: AppConversationStats {
            total_messages,
            user_message_count,
            assistant_message_count,
            turn_count: seen_turn_ids.len() as u32,
            commands_executed,
            commands_succeeded,
            commands_failed,
            total_command_duration_ms,
            files_changed,
            files_added,
            files_modified,
            files_deleted,
            diff_additions,
            diff_deletions,
            tool_call_count,
            mcp_tool_call_count,
            dynamic_tool_call_count,
            web_search_count,
            image_count,
            code_review_count,
            widget_count,
            session_duration_ms,
        },
        log,
        last_turn_start_ms,
        last_turn_end_ms,
    }
}

pub(crate) fn sort_session_summaries(session_summaries: &mut [AppSessionSummary]) {
    session_summaries.sort_by(|lhs, rhs| {
        rhs.updated_at
            .cmp(&lhs.updated_at)
            .then_with(|| lhs.key.server_id.cmp(&rhs.key.server_id))
            .then_with(|| lhs.key.thread_id.cmp(&rhs.key.thread_id))
    });
}

pub(crate) fn project_thread_snapshot(
    snapshot: &AppSnapshot,
    key: &ThreadKey,
) -> Result<Option<AppThreadSnapshot>, String> {
    let Some(thread) = snapshot.threads.get(key) else {
        return Ok(None);
    };
    app_thread_snapshot_from_state(snapshot, thread).map(Some)
}

pub(crate) fn project_thread_update(
    snapshot: &AppSnapshot,
    key: &ThreadKey,
    agent_directory_version: u64,
) -> Result<Option<(AppThreadSnapshot, AppSessionSummary, u64)>, String> {
    let Some(thread) = snapshot.threads.get(key) else {
        return Ok(None);
    };
    let thread_snapshot = app_thread_snapshot_from_state(snapshot, thread)?;
    let session_summary = app_session_summary(thread, snapshot.servers.get(&key.server_id));
    Ok(Some((
        thread_snapshot,
        session_summary,
        agent_directory_version,
    )))
}

pub(crate) fn project_thread_state_update(
    snapshot: &AppSnapshot,
    key: &ThreadKey,
    agent_directory_version: u64,
) -> Result<Option<(AppThreadStateRecord, AppSessionSummary, u64)>, String> {
    let Some(thread) = snapshot.threads.get(key) else {
        return Ok(None);
    };
    let thread_state = app_thread_state_record_from_state(snapshot, thread)?;
    let session_summary = app_session_summary(thread, snapshot.servers.get(&key.server_id));
    Ok(Some((
        thread_state,
        session_summary,
        agent_directory_version,
    )))
}

/// Fold one agent-directory entry into a standalone `u64`.
///
/// Entry hashes are combined with `wrapping_add`, i.e. order-independently,
/// so neither the snapshot path nor the incremental path has to sort the
/// thread list first. Ordering in the directory is itself derived from
/// `updated_at`, which is part of the hash, so an ordering change always
/// comes with a value change.
fn agent_directory_entry_version(
    server_id: &str,
    thread_id: &str,
    parent_thread_id: Option<&str>,
    agent_nickname: Option<&str>,
    agent_role: Option<&str>,
    agent_status: AppSubagentStatus,
    updated_at: Option<i64>,
    has_active_turn: bool,
) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    server_id.hash(&mut hasher);
    thread_id.hash(&mut hasher);
    parent_thread_id.hash(&mut hasher);
    agent_nickname.hash(&mut hasher);
    agent_role.hash(&mut hasher);
    // `agent_display_label` is a pure function of nickname + role, both of
    // which are hashed above, so it carries no extra information. Leaving it
    // out avoids a `format!` per thread on every emit.
    agent_status.hash(&mut hasher);
    updated_at.hash(&mut hasher);
    has_active_turn.hash(&mut hasher);
    hasher.finish()
}

pub(crate) fn current_agent_directory_version(snapshot: &AppSnapshot) -> u64 {
    snapshot
        .threads
        .values()
        .map(|thread| {
            agent_directory_entry_version(
                &thread.key.server_id,
                &thread.key.thread_id,
                thread
                    .info
                    .parent_thread_id
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty()),
                thread.info.agent_nickname.as_deref(),
                thread.info.agent_role.as_deref(),
                thread
                    .info
                    .agent_status
                    .as_deref()
                    .map(AppSubagentStatus::from_raw)
                    .unwrap_or(AppSubagentStatus::Unknown),
                thread.info.updated_at,
                thread_has_active_turn(thread),
            )
        })
        .fold(0u64, u64::wrapping_add)
}

fn thread_has_active_turn(thread: &ThreadSnapshot) -> bool {
    thread.active_turn_id.is_some() || matches!(thread.info.status, ThreadSummaryStatus::Active)
}

impl From<ServerHealthSnapshot> for AppServerHealth {
    fn from(value: ServerHealthSnapshot) -> Self {
        match value {
            ServerHealthSnapshot::Disconnected => Self::Disconnected,
            ServerHealthSnapshot::Connecting => Self::Connecting,
            ServerHealthSnapshot::Connected => Self::Connected,
            ServerHealthSnapshot::Unresponsive => Self::Unresponsive,
            ServerHealthSnapshot::Unknown(_) => Self::Unknown,
        }
    }
}

impl From<ServerHealthSnapshot> for AppServerTransportState {
    fn from(value: ServerHealthSnapshot) -> Self {
        match value {
            ServerHealthSnapshot::Disconnected => Self::Disconnected,
            ServerHealthSnapshot::Connecting => Self::Connecting,
            ServerHealthSnapshot::Connected => Self::Connected,
            ServerHealthSnapshot::Unresponsive => Self::Unresponsive,
            ServerHealthSnapshot::Unknown(_) => Self::Unknown,
        }
    }
}

fn agent_directory_version(session_summaries: &[AppSessionSummary]) -> u64 {
    session_summaries
        .iter()
        .map(|summary| {
            agent_directory_entry_version(
                &summary.key.server_id,
                &summary.key.thread_id,
                summary.parent_thread_id.as_deref(),
                summary.agent_nickname.as_deref(),
                summary.agent_role.as_deref(),
                summary.agent_status,
                summary.updated_at,
                summary.has_active_turn,
            )
        })
        .fold(0u64, u64::wrapping_add)
}

fn agent_display_label(
    nickname: Option<&str>,
    role: Option<&str>,
    fallback_identifier: Option<&str>,
) -> Option<String> {
    let clean_nickname = sanitized_label_field(nickname);
    let clean_role = sanitized_label_field(role);
    match (clean_nickname, clean_role) {
        (Some(nickname), Some(role)) => Some(format!("{nickname} [{role}]")),
        (Some(nickname), None) => Some(nickname.to_string()),
        (None, Some(role)) => Some(format!("[{role}]")),
        (None, None) => sanitized_label_field(fallback_identifier).map(str::to_string),
    }
}

fn sanitized_label_field(raw: Option<&str>) -> Option<&str> {
    raw.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then_some(trimmed)
    })
}

#[cfg(test)]
mod tests {
    use super::{
        agent_directory_version, app_session_summary, app_thread_snapshot_from_state,
        app_thread_state_record_from_state, current_agent_directory_version,
        session_summaries_from_snapshot,
    };
    use crate::store::{AppSnapshot, ThreadSnapshot};
    use crate::types::{
        AppModeKind, AppPlanImplementationPromptSnapshot,
        PendingUserInputRequest, ThreadInfo, ThreadKey, ThreadSummaryStatus,
    };

    #[test]
    fn current_agent_directory_version_matches_summary_hash() {
        let mut snapshot = AppSnapshot::default();

        let mut parent = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread-a".to_string(),
                title: Some("Parent".to_string()),
                model: None,
                preview: Some("Preview".to_string()),
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Idle,
                updated_at: Some(20),
            },
        );
        parent.active_turn_id = Some("turn-a".to_string());
        snapshot.threads.insert(parent.key.clone(), parent);

        let child_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-b".to_string(),
        };
        snapshot.threads.insert(
            child_key.clone(),
            ThreadSnapshot {
                key: child_key,
                info: ThreadInfo {
                    id: "thread-b".to_string(),
                    title: None,
                    model: None,
                    preview: None,
                    cwd: None,
                    path: None,
                    model_provider: None,
                    parent_thread_id: Some(" thread-a ".to_string()),
                    forked_from_id: None,
                    agent_nickname: Some("assistant".to_string()),
                    agent_role: Some("coder".to_string()),
                    agent_status: Some("running".to_string()),
                    created_at: None,
                    status: ThreadSummaryStatus::Active,
                    updated_at: Some(10),
                },
                agent_runtime_kind: "codex".to_string(),
                collaboration_mode: AppModeKind::Default,
                model: None,
                reasoning_effort: None,
                effective_approval_policy: None,
                effective_sandbox_policy: None,
                items: Default::default(),
                local_overlay_items: Default::default(),
                activity_cache: Default::default(),
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
            },
        );

        let expected = agent_directory_version(&session_summaries_from_snapshot(&snapshot));
        assert_eq!(current_agent_directory_version(&snapshot), expected);
    }

    #[test]
    fn app_session_summary_treats_active_status_as_active_turn() {
        let thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread-active".to_string(),
                title: Some("Active thread".to_string()),
                model: None,
                preview: Some("working".to_string()),
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Active,
                updated_at: Some(20),
            },
        );

        assert!(thread.active_turn_id.is_none());
        let summary = app_session_summary(&thread, None);
        assert!(summary.has_active_turn);
    }

    #[test]
    fn app_session_summary_keeps_title_distinct_from_preview() {
        let summary = app_session_summary(
            &ThreadSnapshot::from_info(
                "srv",
                ThreadInfo {
                    id: "thread-a".to_string(),
                    title: None,
                    model: None,
                    preview: Some("First user message".to_string()),
                    cwd: None,
                    path: None,
                    model_provider: None,
                    agent_nickname: None,
                    agent_role: None,
                    parent_thread_id: None,
                    forked_from_id: None,
                    agent_status: None,
                    created_at: None,
                    status: ThreadSummaryStatus::Idle,
                    updated_at: Some(20),
                },
            ),
            None,
        );

        assert_eq!(summary.title, "First user message");
        assert_eq!(summary.preview, "First user message");
    }

    #[test]
    fn plan_prompt_projection_hides_when_blocked_and_reappears() {
        let mut snapshot = AppSnapshot::default();
        let thread = ThreadSnapshot {
            pending_plan_implementation_turn_id: Some("turn-1".to_string()),
            ..ThreadSnapshot::from_info(
                "srv",
                ThreadInfo {
                    id: "thread-a".to_string(),
                    title: Some("Parent".to_string()),
                    model: None,
                    preview: Some("Preview".to_string()),
                    cwd: None,
                    path: None,
                    model_provider: None,
                    agent_nickname: None,
                    agent_role: None,
                    parent_thread_id: None,
                    forked_from_id: None,
                    agent_status: None,
                    created_at: None,
                    status: ThreadSummaryStatus::Idle,
                    updated_at: Some(20),
                },
            )
        };
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let visible =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap())
                .unwrap()
                .pending_plan_implementation_prompt;
        assert_eq!(
            visible,
            Some(AppPlanImplementationPromptSnapshot {
                source_turn_id: "turn-1".to_string()
            })
        );

        snapshot.pending_user_inputs.push(PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: "srv".to_string(),
            thread_id: "thread-a".to_string(),
            turn_id: "turn-2".to_string(),
            item_id: "item-2".to_string(),
            questions: Vec::new(),
            requester_agent_nickname: None,
            requester_agent_role: None,
        });
        let hidden = app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap())
            .unwrap()
            .pending_plan_implementation_prompt;
        assert_eq!(hidden, None);
    }

    #[test]
    fn app_thread_snapshot_hides_duplicate_local_user_overlay_once_turn_bound() {
        let mut snapshot = AppSnapshot::default();
        let mut thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread-a".to_string(),
                title: Some("Thread".to_string()),
                model: None,
                preview: Some("hello".to_string()),
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Active,
                updated_at: Some(20),
            },
        );
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        thread
            .local_overlay_items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "local-user-message:1".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let projected =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap()).unwrap();

        assert_eq!(projected.hydrated_conversation_items.len(), 1);
        assert_eq!(
            projected.hydrated_conversation_items[0].id,
            "server-user-item"
        );
    }

    #[test]
    fn merged_hydrated_items_filters_overlay_when_real_item_has_no_turn_id() {
        let mut snapshot = AppSnapshot::default();
        let mut thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread".to_string(),
                title: None,
                model: None,
                preview: None,
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Idle,
                updated_at: None,
            },
        );
        // Real item from ItemStarted (no source_turn_id).
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: None,
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        // Bound overlay for the same message.
        thread
            .local_overlay_items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "local-user-message:1".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let projected =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap()).unwrap();

        assert_eq!(projected.hydrated_conversation_items.len(), 1);
        assert_eq!(
            projected.hydrated_conversation_items[0].id,
            "server-user-item"
        );
    }

    #[test]
    fn app_thread_snapshot_places_bound_local_user_overlay_before_same_turn_items() {
        let mut snapshot = AppSnapshot::default();
        let mut thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread".to_string(),
                title: None,
                model: None,
                preview: None,
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Active,
                updated_at: None,
            },
        );
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "old-user".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "previous prompt".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-0".to_string()),
                source_turn_index: Some(0),
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "old-assistant".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::Assistant(
                    crate::conversation_uniffi::HydratedAssistantMessageData {
                        text: "previous response".to_string(),
                        agent_nickname: None,
                        agent_role: None,
                        phase: None,
                    },
                ),
                source_turn_id: Some("turn-0".to_string()),
                source_turn_index: Some(0),
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "assistant-1".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::Assistant(
                    crate::conversation_uniffi::HydratedAssistantMessageData {
                        text: "new response".to_string(),
                        agent_nickname: None,
                        agent_role: None,
                        phase: None,
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
        thread
            .local_overlay_items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "local-user-message:1".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "new prompt".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let projected =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap()).unwrap();
        let item_ids = projected
            .hydrated_conversation_items
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>();

        assert_eq!(
            item_ids,
            vec![
                "old-user",
                "old-assistant",
                "local-user-message:1",
                "assistant-1"
            ]
        );
    }

    #[test]
    fn app_thread_snapshot_projects_multi_agent_targets_to_display_labels() {
        let mut snapshot = AppSnapshot::default();

        let parent = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "parent-thread".to_string(),
                title: Some("Parent".to_string()),
                model: None,
                preview: Some("Preview".to_string()),
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Idle,
                updated_at: Some(20),
            },
        );
        let parent_key = parent.key.clone();
        snapshot.threads.insert(parent_key.clone(), parent);

        let child = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "child-thread".to_string(),
                title: Some("Child".to_string()),
                model: None,
                preview: Some("Child preview".to_string()),
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: Some("Scout".to_string()),
                agent_role: Some("explorer".to_string()),
                parent_thread_id: Some("parent-thread".to_string()),
                forked_from_id: None,
                agent_status: Some("running".to_string()),
                created_at: None,
                status: ThreadSummaryStatus::Active,
                updated_at: Some(21),
            },
        );
        snapshot.threads.insert(child.key.clone(), child);

        snapshot
            .threads
            .get_mut(&parent_key)
            .expect("parent thread exists")
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "collab-1".to_string(),
                content:
                    crate::conversation_uniffi::HydratedConversationItemContent::MultiAgentAction(
                        crate::conversation_uniffi::HydratedMultiAgentActionData {
                            tool: "spawnAgent".to_string(),
                            status: crate::types::AppOperationStatus::Completed,
                            prompt: Some("Inspect the thread".to_string()),
                            targets: vec!["child-thread".to_string()],
                            receiver_thread_ids: vec!["child-thread".to_string()],
                            agent_states: vec![
                                crate::conversation_uniffi::HydratedMultiAgentStateData {
                                    target_id: "child-thread".to_string(),
                                    status: crate::types::AppSubagentStatus::Running,
                                    message: Some("Working".to_string()),
                                },
                            ],
                        },
                    ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: Some(0),
                timestamp: None,
                is_from_user_turn_boundary: false,
            });

        let projected =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&parent_key).unwrap())
                .unwrap();

        let crate::conversation_uniffi::HydratedConversationItemContent::MultiAgentAction(data) =
            &projected.hydrated_conversation_items[0].content
        else {
            panic!("expected multi-agent action item");
        };

        assert_eq!(data.targets, vec!["Scout [explorer]".to_string()]);
        assert_eq!(data.receiver_thread_ids, vec!["child-thread".to_string()]);
        assert_eq!(data.agent_states[0].target_id, "child-thread");
    }

    /// Regression for task #13. `AppThreadStateRecord` flows with the
    /// `ThreadMetadataChanged` event; if it drops `older_turns_cursor`
    /// or `initial_turns_loaded` the platform mappers will coerce those
    /// to defaults on every metadata update, wiping
    /// `load_thread_turns_page`'s state.
    #[test]
    fn app_thread_state_record_carries_pagination_fields() {
        let mut snapshot = AppSnapshot::default();
        let thread_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let info = ThreadInfo {
            id: "thread-1".to_string(),
            title: None,
            model: None,
            status: ThreadSummaryStatus::Idle,
            preview: None,
            cwd: None,
            path: None,
            model_provider: None,
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            forked_from_id: None,
            agent_status: None,
            created_at: None,
            updated_at: None,
        };
        let mut thread = ThreadSnapshot::from_info("srv", info);
        thread.older_turns_cursor = Some("older-cursor".to_string());
        thread.initial_turns_loaded = true;
        snapshot.threads.insert(thread_key.clone(), thread);

        let record = app_thread_state_record_from_state(
            &snapshot,
            snapshot.threads.get(&thread_key).unwrap(),
        )
        .expect("record");
        assert_eq!(record.older_turns_cursor.as_deref(), Some("older-cursor"));
        assert!(record.initial_turns_loaded);
    }
}
