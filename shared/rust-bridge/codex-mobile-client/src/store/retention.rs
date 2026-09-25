//! Best-effort RAM cache for reloadable inactive history, not a process RSS limit.
use std::collections::{HashMap, HashSet};
use std::mem::size_of;
use std::time::{Duration, Instant};

use super::reducer::AppStoreReducer;
use super::snapshot::{AppSnapshot, ServerHealthSnapshot, ThreadItems, ThreadSnapshot};
use crate::conversation_uniffi::*;
use crate::types::{
    AppOperationStatus, AppPlanStepStatus, AppThreadGoalStatus, ThreadKey, ThreadSummaryStatus,
};

const HIGH_WATER_BYTES: usize = 64 * 1024 * 1024;
const LOW_WATER_BYTES: usize = 48 * 1024 * 1024;

/// Counts owned allocation capacity, excluding inline storage counted by its owner.
/// Hash-table buckets/allocator overhead remain conservative estimates; this is
/// intentionally a cache weight, not a claim to measure total resident memory.
pub(super) trait HeapBytes {
    const HAS_HEAP: bool = true;
    fn heap_bytes(&self) -> usize;
}
impl HeapBytes for String {
    fn heap_bytes(&self) -> usize {
        self.capacity()
    }
}
impl<T: HeapBytes> HeapBytes for Vec<T> {
    fn heap_bytes(&self) -> usize {
        let children = if T::HAS_HEAP {
            self.iter()
                .fold(0usize, |sum, value| sum.saturating_add(value.heap_bytes()))
        } else {
            0
        };
        self.capacity()
            .saturating_mul(size_of::<T>())
            .saturating_add(children)
    }
}
impl<T: HeapBytes> HeapBytes for Option<T> {
    const HAS_HEAP: bool = T::HAS_HEAP;
    fn heap_bytes(&self) -> usize {
        self.as_ref().map_or(0, HeapBytes::heap_bytes)
    }
}
macro_rules! inline_only {
    ($($ty:ty),*) => {$ (impl HeapBytes for $ty { const HAS_HEAP: bool = false; fn heap_bytes(&self) -> usize { 0 } })*};
}
inline_only!(
    u8,
    u32,
    u64,
    i32,
    i64,
    f64,
    bool,
    crate::types::AppMessagePhase,
    AppOperationStatus,
    crate::types::AppSubagentStatus,
    HydratedPlanStepStatus,
    HydratedCommandActionKind
);
macro_rules! record_heap {
    ($ty:ident { $($field:ident),* }) => {
        impl HeapBytes for $ty {
            fn heap_bytes(&self) -> usize {
                let Self { $($field),* } = self;
                0usize $(.saturating_add($field.heap_bytes()))*
            }
        }
    };
}
record_heap!(HydratedConversationItem {
    id,
    content,
    source_turn_id,
    source_turn_index,
    timestamp,
    is_from_user_turn_boundary,
    captured_items_revision
});
record_heap!(HydratedUserMessageData {
    text,
    image_data_uris
});
record_heap!(HydratedAssistantMessageData {
    text,
    agent_nickname,
    agent_role,
    phase
});
record_heap!(HydratedCodeReviewData {
    findings,
    overall_correctness,
    overall_explanation,
    overall_confidence_score
});
record_heap!(HydratedCodeReviewFindingData {
    title,
    body,
    confidence_score,
    priority,
    code_location
});
record_heap!(HydratedCodeReviewCodeLocationData {
    absolute_file_path,
    line_range
});
record_heap!(HydratedCodeReviewLineRangeData { start, end });
record_heap!(HydratedReasoningData { summary, content });
record_heap!(HydratedTodoListData { steps });
record_heap!(HydratedPlanStep { step, status });
record_heap!(HydratedProposedPlanData { content });
record_heap!(HydratedCommandExecutionData {
    command,
    cwd,
    status,
    output,
    exit_code,
    duration_ms,
    process_id,
    actions
});
record_heap!(HydratedCommandActionData {
    kind,
    command,
    name,
    path,
    query
});
record_heap!(HydratedFileChangeEntryData {
    path,
    kind,
    diff,
    additions,
    deletions
});
record_heap!(HydratedFileChangeData { status, changes });
record_heap!(HydratedTurnDiffData { diff });
record_heap!(HydratedMcpToolCallData {
    server,
    tool,
    status,
    duration_ms,
    arguments_json,
    content_summary,
    structured_content_json,
    raw_output_json,
    error_message,
    progress_messages,
    computer_use
});
record_heap!(ComputerUseView {
    tool,
    summary,
    screenshot_png,
    accessibility_text
});
record_heap!(HydratedToolMetadataData { key, value });
record_heap!(HydratedDynamicToolDisplayData {
    title,
    summary,
    metadata
});
record_heap!(HydratedDynamicToolCallData {
    namespace,
    tool,
    status,
    duration_ms,
    success,
    arguments_json,
    content_summary,
    display
});
record_heap!(HydratedMultiAgentStateData {
    target_id,
    status,
    message
});
record_heap!(HydratedMultiAgentActionData {
    tool,
    status,
    prompt,
    targets,
    receiver_thread_ids,
    agent_states
});
record_heap!(HydratedWebSearchData {
    query,
    action_json,
    is_in_progress
});
record_heap!(HydratedImageViewData { path });
record_heap!(HydratedWidgetData {
    title,
    widget_html,
    width,
    height,
    status,
    is_finalized,
    app_id
});
record_heap!(HydratedUserInputResponseOptionData { label, description });
record_heap!(HydratedUserInputResponseQuestionData {
    id,
    header,
    question,
    answer,
    options
});
record_heap!(HydratedUserInputResponseData { questions });
record_heap!(HydratedNoteData { title, body });
record_heap!(HydratedErrorData {
    title,
    message,
    details
});
record_heap!(HydratedImageGenerationData {
    status,
    revised_prompt,
    image_png,
    saved_path
});

impl HeapBytes for HydratedConversationItemContent {
    fn heap_bytes(&self) -> usize {
        match self {
            Self::User(value) => value.heap_bytes(),
            Self::Assistant(value) => value.heap_bytes(),
            Self::CodeReview(value) => value.heap_bytes(),
            Self::Reasoning(value) => value.heap_bytes(),
            Self::TodoList(value) => value.heap_bytes(),
            Self::ProposedPlan(value) => value.heap_bytes(),
            Self::CommandExecution(value) => value.heap_bytes(),
            Self::FileChange(value) => value.heap_bytes(),
            Self::TurnDiff(value) => value.heap_bytes(),
            Self::McpToolCall(value) => value.heap_bytes(),
            Self::DynamicToolCall(value) => value.heap_bytes(),
            Self::MultiAgentAction(value) => value.heap_bytes(),
            Self::WebSearch(value) => value.heap_bytes(),
            Self::ImageView(value) => value.heap_bytes(),
            Self::Widget(value) => value.heap_bytes(),
            Self::UserInputResponse(value) => value.heap_bytes(),
            Self::Divider(value) => value.heap_bytes(),
            Self::Error(value) => value.heap_bytes(),
            Self::Note(value) => value.heap_bytes(),
            Self::ImageGeneration(value) => value.heap_bytes(),
        }
    }
}
impl HeapBytes for ComputerUseTool {
    fn heap_bytes(&self) -> usize {
        match self {
            Self::ListApps => 0,
            Self::GetAppState { app }
            | Self::Drag {
                app,
                from_x: _,
                from_y: _,
                to_x: _,
                to_y: _,
            } => app.heap_bytes(),
            Self::Click {
                app,
                element_index,
                button,
                x: _,
                y: _,
            } => app.heap_bytes() + element_index.heap_bytes() + button.heap_bytes(),
            Self::PerformSecondaryAction {
                app,
                element_index,
                action,
            } => app.heap_bytes() + element_index.heap_bytes() + action.heap_bytes(),
            Self::Scroll {
                app,
                element_index,
                direction,
                pages: _,
            } => app.heap_bytes() + element_index.heap_bytes() + direction.heap_bytes(),
            Self::TypeText { app, text } => app.heap_bytes() + text.heap_bytes(),
            Self::PressKey { app, key } => app.heap_bytes() + key.heap_bytes(),
            Self::SetValue {
                app,
                element_index,
                value,
            } => app.heap_bytes() + element_index.heap_bytes() + value.heap_bytes(),
            Self::Unknown { name } => name.heap_bytes(),
        }
    }
}
impl HeapBytes for HydratedDividerData {
    fn heap_bytes(&self) -> usize {
        match self {
            Self::ContextCompaction { .. } => 0,
            Self::ModelRerouted {
                from_model,
                to_model,
                reason,
            } => from_model.heap_bytes() + to_model.heap_bytes() + reason.heap_bytes(),
            Self::ReviewEntered { review } | Self::ReviewExited { review } => review.heap_bytes(),
        }
    }
}

#[derive(Default)]
pub(super) struct RetentionState {
    weights: HashMap<ThreadKey, (u64, u64, usize, bool)>,
    viewed: HashMap<ThreadKey, u64>,
    sequence: u64,
    leases: HashMap<ThreadKey, usize>,
    last_sweep: Option<Instant>,
    selection_sweep_scheduled: bool,
}

/// Pins history through response reconciliation; cancellation drops the pin.
pub(crate) struct HistoryLease<'a> {
    store: &'a AppStoreReducer,
    key: ThreadKey,
}
impl Drop for HistoryLease<'_> {
    fn drop(&mut self) {
        let released_last = {
            let mut state = self
                .store
                .retention
                .lock()
                .expect("retention lock poisoned");
            if let Some(count) = state.leases.get_mut(&self.key) {
                *count -= 1;
                if *count == 0 {
                    state.leases.remove(&self.key);
                    true
                } else {
                    false
                }
            } else {
                false
            }
        };
        if released_last {
            self.store.trim_inactive_history(true);
        }
    }
}

fn unfinished(item: &HydratedConversationItem) -> bool {
    let status = match &item.content {
        HydratedConversationItemContent::CommandExecution(v) => Some(v.status),
        HydratedConversationItemContent::FileChange(v) => Some(v.status),
        HydratedConversationItemContent::McpToolCall(v) => Some(v.status),
        HydratedConversationItemContent::DynamicToolCall(v) => Some(v.status),
        HydratedConversationItemContent::MultiAgentAction(v) => Some(v.status),
        HydratedConversationItemContent::ImageGeneration(v) => Some(v.status),
        HydratedConversationItemContent::WebSearch(v) => return v.is_in_progress,
        HydratedConversationItemContent::Widget(v) => return !v.is_finalized,
        _ => None,
    };
    matches!(
        status,
        Some(AppOperationStatus::Pending | AppOperationStatus::InProgress)
    )
}

fn protected(snapshot: &AppSnapshot, thread: &ThreadSnapshot) -> bool {
    let key = &thread.key;
    let Some(server) = snapshot.servers.get(&key.server_id) else {
        return true;
    };
    !matches!(server.health, ServerHealthSnapshot::Connected)
        || snapshot.active_thread.as_ref() == Some(key)
        || snapshot.voice_session.active_thread.as_ref() == Some(key)
        || snapshot.voice_session.handoff_thread_key.as_ref() == Some(key)
        || thread.active_turn_id.is_some()
        || matches!(thread.info.status, ThreadSummaryStatus::Active)
        || thread.realtime_session_id.is_some()
        || !thread.local_overlay_items.is_empty()
        || !thread.queued_follow_ups.is_empty()
        || !thread.queued_follow_up_drafts.is_empty()
        || thread.pending_plan_implementation_turn_id.is_some()
        || thread.active_plan_progress.as_ref().is_some_and(|p| {
            p.plan
                .iter()
                .any(|s| s.status != AppPlanStepStatus::Completed)
        })
        || thread
            .goal
            .as_ref()
            .is_some_and(|g| g.status == AppThreadGoalStatus::Active)
        || server
            .transport
            .pending_mutation
            .as_ref()
            .is_some_and(|p| p.thread_id.is_empty() || p.thread_id == key.thread_id)
        || snapshot.pending_approvals.iter().any(|p| {
            p.server_id == key.server_id
                && p.thread_id.as_ref().is_none_or(|id| id == &key.thread_id)
        })
        || snapshot
            .pending_user_inputs
            .iter()
            .any(|p| p.server_id == key.server_id && p.thread_id == key.thread_id)
}

impl AppStoreReducer {
    pub(crate) fn history_lease(&self, key: &ThreadKey) -> HistoryLease<'_> {
        *self
            .retention
            .lock()
            .expect("retention lock poisoned")
            .leases
            .entry(key.clone())
            .or_default() += 1;
        HistoryLease {
            store: self,
            key: key.clone(),
        }
    }

    pub(super) fn note_history_viewed(&self, key: Option<&ThreadKey>) {
        if let Some(key) = key {
            let mut state = self.retention.lock().expect("retention lock poisoned");
            state.sequence = state.sequence.saturating_add(1);
            let sequence = state.sequence;
            state.viewed.insert(key.clone(), sequence);
        }
    }

    pub(crate) fn schedule_selection_sweep(&self) -> bool {
        let mut state = self.retention.lock().expect("retention lock poisoned");
        if state.selection_sweep_scheduled {
            return false;
        }
        state.selection_sweep_scheduled = true;
        true
    }

    pub(crate) fn run_selection_sweep(&self) {
        self.retention
            .lock()
            .expect("retention lock poisoned")
            .selection_sweep_scheduled = false;
        self.trim_inactive_history(true);
    }

    pub(crate) fn trim_inactive_history(&self, force: bool) {
        self.trim_history_to_budget(HIGH_WATER_BYTES, LOW_WATER_BYTES, force);
    }

    pub(crate) fn trim_history_to_budget(&self, high: usize, low: usize, force: bool) {
        // No payload traversal on streaming updates. Coalesce ordinary lifecycle
        // boundaries; a view switch can release the previous transcript promptly.
        {
            let mut state = self.retention.lock().expect("retention lock poisoned");
            if !force
                && state
                    .last_sweep
                    .is_some_and(|t| t.elapsed() < Duration::from_secs(1))
            {
                return;
            }
            state.last_sweep = Some(Instant::now());
        }
        let mut released_items = Vec::new();
        let evicted = {
            let mut snapshot = self.write_snapshot();
            let mut state = self.retention.lock().expect("retention lock poisoned");
            let buffers = self
                .dynamic_tool_arg_buffers
                .read()
                .expect("argument buffer lock poisoned");
            let buffered_keys: HashSet<_> = buffers.keys().map(|(key, _)| key).collect();
            state
                .weights
                .retain(|key, _| snapshot.threads.contains_key(key));
            state
                .viewed
                .retain(|key, _| snapshot.threads.contains_key(key));
            let mut candidates = Vec::new();
            let mut bytes = 0usize;
            for (key, thread) in &snapshot.threads {
                if thread.items.is_empty()
                    || protected(&snapshot, thread)
                    || state.leases.contains_key(key)
                    || buffered_keys.contains(key)
                {
                    continue;
                }
                let revisions = (
                    thread.items.revision(),
                    thread.local_overlay_items.revision(),
                );
                let entry = state.weights.entry(key.clone()).or_insert((0, 0, 0, false));
                if (entry.0, entry.1) != revisions {
                    *entry = (
                        revisions.0,
                        revisions.1,
                        thread.items.retained_bytes() + thread.local_overlay_items.retained_bytes(),
                        thread.items.iter().any(unfinished),
                    );
                }
                if entry.3 {
                    continue;
                }
                // Derived caches can populate without changing item revisions.
                let weight = entry
                    .2
                    .saturating_add(thread.activity_cache.retained_bytes());
                bytes = bytes.saturating_add(weight);
                candidates.push((
                    state.viewed.get(key).copied().unwrap_or(0),
                    key.clone(),
                    weight,
                ));
            }
            let mut evicted = Vec::new();
            if bytes > high {
                candidates.sort_by(|a, b| {
                    a.0.cmp(&b.0)
                        .then_with(|| a.1.server_id.cmp(&b.1.server_id))
                        .then_with(|| a.1.thread_id.cmp(&b.1.thread_id))
                });
                for (_, key, weight) in candidates {
                    if bytes <= low {
                        break;
                    }
                    let thread = snapshot
                        .threads
                        .get_mut(&key)
                        .expect("candidate remains present");
                    let empty = ThreadItems::new();
                    thread
                        .activity_cache
                        .retain_evicted_summary(&thread.items, empty.revision());
                    released_items.push(std::mem::replace(&mut thread.items, empty));
                    thread.items_source_revision = None;
                    thread.older_turns_cursor = None;
                    thread.initial_turns_loaded = false;
                    state.weights.remove(&key);
                    bytes = bytes.saturating_sub(weight);
                    evicted.push(key);
                }
            }
            evicted
        };
        // Destruct potentially large histories outside the canonical write lock.
        drop(released_items);
        for key in evicted {
            self.emit_thread_upsert(&key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::connection::ServerConfig;
    use crate::store::boundary::app_session_summary;
    use crate::types::{PendingApproval, PendingUserInputRequest, ThreadInfo};

    fn key(id: &str) -> ThreadKey {
        ThreadKey {
            server_id: "srv".into(),
            thread_id: id.into(),
        }
    }
    fn item(capacity: usize) -> HydratedConversationItem {
        let mut text = String::with_capacity(capacity);
        text.push_str("hello");
        HydratedConversationItem {
            id: "item".into(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text,
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: None,
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
            captured_items_revision: 0,
        }
    }
    fn thread(id: &str, capacity: usize) -> ThreadSnapshot {
        let mut thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: id.into(),
                title: Some("Title".into()),
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
            },
        );
        thread.items.push(item(capacity));
        thread.initial_turns_loaded = true;
        thread.older_turns_cursor = Some("old-page".into());
        thread
    }
    fn store() -> AppStoreReducer {
        let store = AppStoreReducer::new();
        store.upsert_server(
            &ServerConfig {
                server_id: "srv".into(),
                display_name: "Server".into(),
                host: "localhost".into(),
                port: 1,
                websocket_url: None,
                is_local: false,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        store
    }
    fn assert_loaded(store: &AppStoreReducer, id: &str) {
        assert!(!store.thread_snapshot(&key(id)).unwrap().items.is_empty());
    }

    #[test]
    fn retained_weight_counts_spare_string_vector_and_image_capacity() {
        assert!(item(16_384).heap_bytes() >= 16_384);
        let bytes: Vec<u8> = Vec::with_capacity(32_768);
        assert_eq!(bytes.heap_bytes(), 32_768);
        let mut image = item(1);
        image.content =
            HydratedConversationItemContent::ImageGeneration(HydratedImageGenerationData {
                status: AppOperationStatus::Completed,
                revised_prompt: None,
                image_png: Some(bytes),
                saved_path: None,
            });
        assert!(image.heap_bytes() >= 32_768);
        let mut items = ThreadItems::new();
        for _ in 0..30 {
            items.push(item(4096));
        }
        let retained = items.retained_bytes();
        items.clear();
        assert!(
            items.retained_bytes() > 0,
            "clear retains vector/index capacity"
        );
        assert!(items.retained_bytes() < retained);
        items = ThreadItems::new();
        assert_eq!(items.retained_bytes(), 0);
    }

    #[test]
    fn lru_trim_releases_allocations_preserves_summary_and_emits_empty_capture() {
        let store = store();
        for id in ["older", "recent"] {
            store.upsert_thread_snapshot(thread(id, 8192));
        }
        store.note_history_viewed(Some(&key("recent")));
        let before = store
            .thread_snapshot(&key("older"))
            .unwrap()
            .items
            .revision();
        let mut updates = store.subscribe();
        store.trim_history_to_budget(12_000, 12_000, true);
        let empty = store.thread_snapshot(&key("older")).unwrap();
        assert_eq!(empty.items.retained_bytes(), 0);
        assert!(!empty.initial_turns_loaded);
        assert_eq!(empty.older_turns_cursor, None);
        assert!(empty.items.revision() > before);
        let summary = app_session_summary(&empty, None);
        assert_eq!(summary.last_response_preview.as_deref(), Some("hello"));
        assert_eq!(summary.stats.unwrap().assistant_message_count, 1);
        assert_loaded(&store, "recent");
        let update = updates.try_recv().unwrap();
        assert!(
            matches!(update, super::super::updates::AppStoreUpdateRecord::ThreadUpserted { thread, .. }
            if thread.key == key("older") && thread.hydrated_conversation_items.is_empty()
                && thread.captured_items_revision > before && !thread.initial_turns_loaded)
        );
        let mut metadata = ThreadSnapshot::from_info("srv", empty.info.clone());
        metadata.info.title = Some("New title".into());
        store.upsert_thread_snapshot(metadata);
        let after = store.thread_snapshot(&key("older")).unwrap();
        assert_eq!(
            app_session_summary(&after, None)
                .last_response_preview
                .as_deref(),
            Some("hello")
        );
        assert_eq!(after.info.title.as_deref(), Some("New title"));
    }

    #[test]
    fn summary_is_bounded_without_retaining_full_last_message() {
        let store = store();
        let mut t = thread("huge", 1);
        if let HydratedConversationItemContent::Assistant(data) =
            &mut t.items.get_mut(0).unwrap().content
        {
            data.text = "🐈".repeat(100_000);
        }
        store.upsert_thread_snapshot(t);
        store.trim_history_to_budget(1, 0, true);
        let after = store.thread_snapshot(&key("huge")).unwrap();
        assert_eq!(
            app_session_summary(&after, None)
                .last_response_preview
                .unwrap()
                .chars()
                .count(),
            1024
        );
        assert!(after.activity_cache.retained_bytes() < 16_384);
    }

    #[test]
    fn protection_predicates_keep_live_unsaved_and_offline_work() {
        for case in 0..16 {
            let store = store();
            store.upsert_thread_snapshot(thread("protected", 8192));
            let key = key("protected");
            {
                let mut s = store.write_snapshot();
                match case {
                    0 => s.active_thread = Some(key.clone()),
                    1 => s.voice_session.active_thread = Some(key.clone()),
                    2 => s.voice_session.handoff_thread_key = Some(key.clone()),
                    3 => {
                        s.servers.get_mut("srv").unwrap().health =
                            ServerHealthSnapshot::Disconnected
                    }
                    4 => s.threads.get_mut(&key).unwrap().active_turn_id = Some("turn".into()),
                    5 => s.threads.get_mut(&key).unwrap().info.status = ThreadSummaryStatus::Active,
                    6 => {
                        s.threads.get_mut(&key).unwrap().realtime_session_id = Some("voice".into())
                    }
                    7 => s
                        .threads
                        .get_mut(&key)
                        .unwrap()
                        .local_overlay_items
                        .push(item(5)),
                    8 => {
                        s.threads
                            .get_mut(&key)
                            .unwrap()
                            .pending_plan_implementation_turn_id = Some("plan".into())
                    }
                    9 => s.pending_approvals.push(PendingApproval {
                        id: "request".into(),
                        server_id: "srv".into(),
                        kind: crate::types::ApprovalKind::Command,
                        thread_id: None,
                        turn_id: None,
                        item_id: None,
                        command: None,
                        path: None,
                        grant_root: None,
                        cwd: None,
                        reason: None,
                    }),
                    10 => s.pending_user_inputs.push(PendingUserInputRequest {
                        id: "input".into(),
                        server_id: "srv".into(),
                        thread_id: key.thread_id.clone(),
                        turn_id: "turn".into(),
                        item_id: "item".into(),
                        questions: vec![],
                        requester_agent_nickname: None,
                        requester_agent_role: None,
                    }),
                    11 => s.threads.get_mut(&key).unwrap().queued_follow_ups.push(
                        super::super::snapshot::AppQueuedFollowUpPreview {
                            id: "queued".into(),
                            kind: super::super::snapshot::AppQueuedFollowUpKind::Message,
                            text: "unsent".into(),
                        },
                    ),
                    12 => {
                        s.threads.get_mut(&key).unwrap().goal = Some(crate::types::AppThreadGoal {
                            thread_id: key.thread_id.clone(),
                            objective: "active".into(),
                            status: AppThreadGoalStatus::Active,
                            token_budget: None,
                            tokens_used: 0,
                            time_used_seconds: 0,
                            created_at: 0,
                            updated_at: 0,
                        })
                    }
                    13 => {
                        s.threads.get_mut(&key).unwrap().active_plan_progress =
                            Some(crate::types::AppPlanProgressSnapshot {
                                turn_id: "turn".into(),
                                explanation: None,
                                plan: vec![crate::types::AppPlanStep {
                                    step: "Work".into(),
                                    status: AppPlanStepStatus::InProgress,
                                }],
                            })
                    }
                    14 => {
                        s.servers.get_mut("srv").unwrap().transport.pending_mutation =
                            Some(super::super::snapshot::PendingServerMutatingCommand {
                                kind: super::super::snapshot::ServerMutatingCommandKind::StartTurn,
                                thread_id: key.thread_id.clone(),
                                local_request_id: "send".into(),
                                started_at: Instant::now(),
                                lifecycle_phase_at_send:
                                    super::super::snapshot::AppLifecyclePhaseSnapshot::Active,
                            })
                    }
                    15 => s
                        .threads
                        .get_mut(&key)
                        .unwrap()
                        .queued_follow_up_drafts
                        .push(super::super::snapshot::QueuedFollowUpDraft {
                            preview: super::super::snapshot::AppQueuedFollowUpPreview {
                                id: "draft".into(),
                                kind: super::super::snapshot::AppQueuedFollowUpKind::Message,
                                text: "unsaved".into(),
                            },
                            inputs: vec![],
                            source_message_json: None,
                        }),
                    _ => unreachable!(),
                }
            }
            store.trim_history_to_budget(1, 0, true);
            assert!(
                !store.thread_snapshot(&key).unwrap().items.is_empty(),
                "guard {case}"
            );
        }
    }

    #[test]
    fn offline_becomes_eligible_after_reconnect_and_selection_itself_does_not_sweep() {
        let store = store();
        store.upsert_thread_snapshot(thread("old", 8192));
        store
            .write_snapshot()
            .servers
            .get_mut("srv")
            .unwrap()
            .health = ServerHealthSnapshot::Disconnected;
        store.trim_history_to_budget(1, 0, true);
        assert_loaded(&store, "old");
        store
            .write_snapshot()
            .servers
            .get_mut("srv")
            .unwrap()
            .health = ServerHealthSnapshot::Connected;
        store.set_active_thread(None);
        assert_loaded(&store, "old");
        assert!(store.schedule_selection_sweep());
        assert!(!store.schedule_selection_sweep());
        store.trim_history_to_budget(1, 0, true);
        assert!(store.thread_snapshot(&key("old")).unwrap().items.is_empty());
    }

    #[test]
    fn nested_history_lease_protects_cursor_until_last_release() {
        let store = store();
        store.upsert_thread_snapshot(thread("page", 8192));
        let key = key("page");
        let outer = store.history_lease(&key);
        let inner = store.history_lease(&key);
        store.trim_history_to_budget(1, 0, true);
        assert_loaded(&store, "page");
        drop(inner);
        assert_eq!(store.retention.lock().unwrap().leases.get(&key), Some(&1));
        store.trim_history_to_budget(1, 0, true);
        assert_eq!(
            store
                .thread_snapshot(&key)
                .unwrap()
                .older_turns_cursor
                .as_deref(),
            Some("old-page")
        );
        drop(outer);
        assert!(!store.retention.lock().unwrap().leases.contains_key(&key));
        store.trim_history_to_budget(1, 0, true);
        assert!(store.thread_snapshot(&key).unwrap().items.is_empty());
    }

    #[test]
    fn final_history_lease_release_enforces_budget_without_another_event() {
        let store = store();
        let key = key("large");
        let lease = store.history_lease(&key);
        store.upsert_thread_snapshot(thread("large", HIGH_WATER_BYTES + 4096));
        assert_loaded(&store, "large");
        drop(lease);
        // No next navigation, RPC or timer is needed to release the oversize cache.
        let after = store.thread_snapshot(&key).unwrap();
        assert!(after.items.is_empty());
        assert!(!after.initial_turns_loaded);
    }

    #[test]
    fn late_final_tool_completion_releases_idle_history_protection() {
        use crate::session::events::UiEvent;
        use codex_app_server_protocol::{
            DynamicToolCallStatus, ItemCompletedNotification, ItemStartedNotification, ThreadItem,
        };
        let store = store();
        let key = key("large");
        let mut thread = thread("large", HIGH_WATER_BYTES + 4096);
        thread.active_turn_id = Some("turn".into());
        thread.info.status = ThreadSummaryStatus::Active;
        store.upsert_thread_snapshot(thread);
        let tool = |status| ThreadItem::DynamicToolCall {
            id: "tool".into(),
            tool: "calculate".into(),
            namespace: None,
            arguments: serde_json::json!({}),
            status,
            content_items: None,
            success: Some(true),
            duration_ms: None,
        };
        store.apply_ui_event(&UiEvent::ItemStarted {
            key: key.clone(),
            notification: ItemStartedNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn".into(),
                item: tool(DynamicToolCallStatus::InProgress),
                started_at_ms: 0,
            },
        });
        store.apply_ui_event(&UiEvent::DynamicToolCallArgumentsDelta {
            key: key.clone(),
            item_id: "tool".into(),
            call_id: Some("call".into()),
            delta: "partial".into(),
        });
        store.apply_ui_event(&UiEvent::TurnCompleted {
            key: key.clone(),
            turn_id: "turn".into(),
            error: None,
        });
        assert_loaded(&store, "large");
        store.apply_ui_event(&UiEvent::ItemCompleted {
            key: key.clone(),
            notification: ItemCompletedNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn".into(),
                item: tool(DynamicToolCallStatus::Completed),
                completed_at_ms: 0,
            },
        });
        assert!(store.dynamic_tool_arg_buffers.read().unwrap().is_empty());
        let after = store.thread_snapshot(&key).unwrap();
        assert!(after.items.is_empty());
        assert!(!after.initial_turns_loaded);
    }

    #[tokio::test]
    async fn cancellation_releases_history_pin() {
        let store = std::sync::Arc::new(store());
        store.upsert_thread_snapshot(thread("page", 8192));
        let ready = std::sync::Arc::new(tokio::sync::Notify::new());
        let task = {
            let store = store.clone();
            let ready = ready.clone();
            tokio::spawn(async move {
                let _lease = store.history_lease(&key("page"));
                ready.notify_one();
                std::future::pending::<()>().await;
            })
        };
        ready.notified().await;
        store.trim_history_to_budget(1, 0, true);
        assert_loaded(&store, "page");
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(store.retention.lock().unwrap().leases.is_empty());
        store.trim_history_to_budget(1, 0, true);
        assert!(
            store
                .thread_snapshot(&key("page"))
                .unwrap()
                .items
                .is_empty()
        );
    }
    #[test]
    fn unfinished_widget_and_argument_buffers_are_not_evicted() {
        for buffered in [false, true] {
            let store = store();
            let mut t = thread("live", 8192);
            if !buffered {
                t.items.get_mut(0).unwrap().content =
                    HydratedConversationItemContent::Widget(HydratedWidgetData {
                        title: "draft".into(),
                        widget_html: "<html>".into(),
                        width: 100.0,
                        height: 100.0,
                        status: "streaming".into(),
                        is_finalized: false,
                        app_id: None,
                    });
            }
            store.upsert_thread_snapshot(t);
            if buffered {
                store.dynamic_tool_arg_buffers.write().unwrap().insert(
                    (key("live"), "call".into()),
                    super::super::reducer::DynamicToolCallArgBuffer {
                        item_id: "item".into(),
                        buffer: "partial".into(),
                    },
                );
            }
            store.trim_history_to_budget(1, 0, true);
            assert_loaded(&store, "live");
        }
    }
    #[test]
    #[ignore = "manual scoped lock-contention diagnostic; reports timing, not a device latency guarantee"]
    fn diagnostic_selection_latency_during_history_trim() {
        use std::sync::{
            Arc, Barrier,
            atomic::{AtomicBool, Ordering},
        };
        let store = Arc::new(store());
        {
            let mut snapshot = store.write_snapshot();
            for index in 0..32 {
                let mut t = thread(&format!("history-{index}"), 32_768);
                for row in 1..128 {
                    let mut value = item(32_768);
                    value.id = format!("item-{row}");
                    t.items.push(value);
                }
                // Prime the existing display summary, as normal ThreadUpsert does.
                let _ = app_session_summary(&t, None);
                snapshot.threads.insert(t.key.clone(), t);
            }
        }
        let ready = Arc::new(Barrier::new(2));
        let done = Arc::new(AtomicBool::new(false));
        let task = {
            let store = store.clone();
            let ready = ready.clone();
            let done = done.clone();
            std::thread::spawn(move || {
                ready.wait();
                store.trim_inactive_history(true);
                done.store(true, Ordering::Release);
            })
        };
        ready.wait();
        let mut timings = Vec::new();
        while !done.load(Ordering::Acquire) || timings.len() < 1000 {
            let started = Instant::now();
            store.set_active_thread(None);
            timings.push(started.elapsed().as_micros());
            std::thread::yield_now();
        }
        task.join().unwrap();
        timings.sort_unstable();
        println!(
            "selection_during_trim samples={} p50_us={} p95_us={} p99_us={} max_us={}",
            timings.len(),
            timings[timings.len() / 2],
            timings[timings.len() * 95 / 100],
            timings[timings.len() * 99 / 100],
            timings.last().unwrap()
        );
        let snapshot = store.snapshot();
        assert!(
            snapshot
                .threads
                .values()
                .filter(|t| !t.items.is_empty())
                .count()
                < 32
        );
    }
}
