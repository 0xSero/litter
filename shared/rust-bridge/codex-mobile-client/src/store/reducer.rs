use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::RwLock;

use codex_app_server_protocol as upstream;
use tokio::sync::broadcast;

use crate::conversation::{
    command_output_is_truncated, make_error_item, make_model_rerouted_item, make_turn_diff_item,
    truncate_command_output_text,
};
use crate::conversation_uniffi::{
    HydratedAssistantMessageData, HydratedCommandExecutionData, HydratedConversationItem,
    HydratedConversationItemContent, HydratedMcpToolCallData, HydratedProposedPlanData,
    HydratedReasoningData, HydratedUserInputResponseData, HydratedUserInputResponseOptionData,
    HydratedUserInputResponseQuestionData,
};
use crate::session::connection::ServerConfig;
use crate::session::events::UiEvent;
use crate::types::{
    AgentRuntimeInfo, AgentRuntimeKind, PendingApproval, PendingApprovalKey, PendingApprovalSeed,
    PendingApprovalWithSeed, PendingUserInputAnswer, PendingUserInputRequest, ThreadInfo,
    ThreadKey, ThreadSummaryStatus,
};
use crate::types::{
    AppModeKind, AppOperationStatus, AppPlanProgressSnapshot, AppPlanStep, AppVoiceSessionPhase,
    AppVoiceTranscriptEntry, AppVoiceTranscriptUpdate,
};

use super::actions::{
    conversation_item_from_upstream_with_turn, thread_info_from_upstream,
    thread_info_from_upstream_status_change,
};
use super::boundary::{
    AppSessionSummary, app_session_summary, current_agent_directory_version, empty_session_summary,
    project_hydrated_item, project_thread_state_update, project_thread_update,
};
use super::snapshot::{
    AppConnectionProgressSnapshot, AppLifecyclePhaseSnapshot, AppQueuedFollowUpPreview,
    AppSnapshot, AppVoiceSessionSnapshot, IpcFailureClassification, PendingServerMutatingCommand,
    QueuedFollowUpDraft, ServerHealthSnapshot, ServerMutatingCommandKind,
    ServerMutatingCommandRoute, ServerSnapshot, ServerTransportAuthority,
    ServerTransportDiagnostics, ThreadSnapshot,
};
use super::updates::{AppStoreUpdateRecord, ThreadStreamingDeltaKind};
use super::voice::{VoiceDerivedUpdate, VoiceRealtimeState};

const USER_INPUT_NOTE_PREFIX: &str = "user_note: ";
const USER_INPUT_OTHER_OPTION_LABEL: &str = "None of the above";
const LOCAL_USER_MESSAGE_ITEM_PREFIX: &str = "local-user-message:";

fn dedupe_agent_runtimes(runtimes: Vec<AgentRuntimeInfo>) -> Vec<AgentRuntimeInfo> {
    let mut indexes_by_kind: HashMap<AgentRuntimeKind, usize> = HashMap::new();
    let mut deduped: Vec<AgentRuntimeInfo> = Vec::new();
    for runtime in runtimes {
        if let Some(index) = indexes_by_kind.get(&runtime.kind).copied() {
            if runtime.available && !deduped[index].available {
                deduped[index] = runtime;
            }
        } else {
            indexes_by_kind.insert(runtime.kind, deduped.len());
            deduped.push(runtime);
        }
    }
    deduped
}

pub struct AppStoreReducer {
    snapshot: RwLock<AppSnapshot>,
    last_thread_state_updates: RwLock<
        HashMap<
            ThreadKey,
            (
                crate::store::boundary::AppThreadStateRecord,
                crate::store::boundary::AppSessionSummary,
                u64,
            ),
        >,
    >,
    last_thread_item_upserts: RwLock<HashMap<(ThreadKey, String), HydratedConversationItem>>,
    /// Per-call-id running buffer of streaming `dynamic_tool_call` argument
    /// JSON. Keyed by `(thread_key, call_id)`. Entries are cleared when the
    /// call completes or fails (via `ItemCompleted` on the matching
    /// item). The partial buffer is parsed tolerantly so platforms can
    /// render widgets as the model streams the HTML body.
    dynamic_tool_arg_buffers: RwLock<HashMap<(ThreadKey, String), DynamicToolCallArgBuffer>>,
    updates_tx: broadcast::Sender<AppStoreUpdateRecord>,
    voice_state: VoiceRealtimeState,
}

/// State we carry per (thread, call_id) while streaming argument deltas.
/// Holds the concatenated JSON so far plus the item_id the call was
/// announced with — we need it to clear on `ItemCompleted`, and to fill
/// the `item_id` field of the broadcast even when the server later omits
/// it on a particular delta.
#[derive(Debug, Clone)]
pub(crate) struct DynamicToolCallArgBuffer {
    pub(crate) item_id: String,
    pub(crate) buffer: String,
}

enum ItemMutationUpdate {
    Upsert(HydratedConversationItem),
}

impl AppStoreReducer {
    pub fn new() -> Self {
        // Streaming turns can burst small deltas quickly; keep enough headroom so
        // native subscribers do not immediately fall into lagged/full-resync mode.
        let (updates_tx, _) = broadcast::channel(1024);
        Self {
            snapshot: RwLock::new(AppSnapshot::default()),
            last_thread_state_updates: RwLock::new(HashMap::new()),
            last_thread_item_upserts: RwLock::new(HashMap::new()),
            dynamic_tool_arg_buffers: RwLock::new(HashMap::new()),
            updates_tx,
            voice_state: VoiceRealtimeState::default(),
        }
    }

    pub fn snapshot(&self) -> AppSnapshot {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .clone()
    }

    pub(crate) fn thread_snapshot(&self, key: &ThreadKey) -> Option<ThreadSnapshot> {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .threads
            .get(key)
            .cloned()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppStoreUpdateRecord> {
        self.updates_tx.subscribe()
    }

    pub fn upsert_server(
        &self,
        config: &ServerConfig,
        health: ServerHealthSnapshot,
        supports_ipc: bool,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let (
                existing_wake_mac,
                existing_account,
                requires_openai_auth,
                existing_rate_limits,
                existing_available_models,
                existing_agent_runtimes,
                existing_supports_ipc,
                existing_has_ipc,
                existing_connection_progress,
                existing_transport,
                existing_codex_version,
                existing_supports_turn_pagination,
            ) = if let Some(existing) = snapshot.servers.get(&config.server_id) {
                (
                    existing.wake_mac.clone(),
                    existing.account.clone(),
                    existing.requires_openai_auth,
                    existing.rate_limits.clone(),
                    existing.available_models.clone(),
                    existing.agent_runtimes.clone(),
                    existing.supports_ipc,
                    existing.has_ipc,
                    existing.connection_progress.clone(),
                    existing.transport.clone(),
                    existing.codex_version.clone(),
                    existing.supports_turn_pagination,
                )
            } else {
                (
                    None,
                    None,
                    false,
                    None,
                    None,
                    vec![AgentRuntimeInfo {
                        kind: AgentRuntimeKind::Codex,
                        name: "codex".to_string(),
                        display_name: "Codex".to_string(),
                        available: true,
                    }],
                    false,
                    false,
                    None,
                    ServerTransportDiagnostics::default(),
                    None,
                    true,
                )
            };
            snapshot.servers.insert(
                config.server_id.clone(),
                ServerSnapshot {
                    server_id: config.server_id.clone(),
                    display_name: config.display_name.clone(),
                    host: config.host.clone(),
                    port: config.port,
                    wake_mac: existing_wake_mac,
                    is_local: config.is_local,
                    supports_ipc: existing_supports_ipc || supports_ipc,
                    has_ipc: existing_has_ipc,
                    health,
                    account: existing_account,
                    requires_openai_auth,
                    rate_limits: existing_rate_limits,
                    available_models: existing_available_models,
                    agent_runtimes: existing_agent_runtimes,
                    connection_progress: existing_connection_progress,
                    transport: existing_transport,
                    codex_version: existing_codex_version,
                    supports_turn_pagination: existing_supports_turn_pagination,
                },
            );
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: config.server_id.clone(),
        });
    }

    pub fn remove_server(&self, server_id: &str) {
        let mut removed_thread_keys = Vec::new();
        let agent_directory_version;
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.servers.remove(server_id);
            snapshot.threads.retain(|key, _| {
                let keep = key.server_id != server_id;
                if !keep {
                    removed_thread_keys.push(key.clone());
                }
                keep
            });
            if snapshot
                .active_thread
                .as_ref()
                .is_some_and(|key| key.server_id == server_id)
            {
                snapshot.active_thread = None;
            }
            snapshot.pending_approvals.retain(|approval| {
                approval
                    .thread_id
                    .as_deref()
                    .is_none_or(|tid| !removed_thread_keys.iter().any(|key| key.thread_id == tid))
            });
            snapshot
                .pending_approval_seeds
                .retain(|key, _| key.server_id != server_id);
            snapshot
                .pending_user_inputs
                .retain(|request| request.server_id != server_id);
            if snapshot
                .voice_session
                .active_thread
                .as_ref()
                .is_some_and(|key| key.server_id == server_id)
            {
                snapshot.voice_session = AppVoiceSessionSnapshot::default();
            }
            agent_directory_version = current_agent_directory_version(&snapshot);
        }
        self.emit(AppStoreUpdateRecord::ServerRemoved {
            server_id: server_id.to_string(),
        });
        for key in removed_thread_keys {
            self.clear_thread_update_caches(&key);
            self.emit(AppStoreUpdateRecord::ThreadRemoved {
                key,
                agent_directory_version,
            });
        }
        self.emit(AppStoreUpdateRecord::ActiveThreadChanged { key: None });
    }

    pub fn sync_thread_list(&self, server_id: &str, threads: &[ThreadInfo]) {
        self.sync_thread_list_for_runtime(server_id, AgentRuntimeKind::Codex, threads);
    }

    pub fn sync_thread_list_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        threads: &[ThreadInfo],
    ) {
        let incoming_ids = threads
            .iter()
            .map(|info| info.id.clone())
            .collect::<HashSet<_>>();
        let mut upserted_thread_keys = Vec::new();
        let mut updated_thread_keys = Vec::new();
        let mut removed_thread_keys = Vec::new();
        let mut active_thread_cleared = false;
        let mut pending_approvals = None;
        let mut pending_user_inputs = None;
        let agent_directory_version;
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let active_thread_key = snapshot.active_thread.clone();
            snapshot.threads.retain(|key, _| {
                let keep = key.server_id != server_id
                    || incoming_ids.contains(&key.thread_id)
                    || active_thread_key.as_ref() == Some(key);
                if !keep {
                    removed_thread_keys.push(key.clone());
                }
                keep
            });
            for info in threads {
                let key = ThreadKey {
                    server_id: server_id.to_string(),
                    thread_id: info.id.clone(),
                };
                if let Some(entry) = snapshot.threads.get_mut(&key) {
                    let mut next_info = info.clone();
                    preserve_thread_title(&entry.info, &mut next_info);
                    preserve_thread_preview(&entry.info, &mut next_info);
                    preserve_thread_created_at(&entry.info, &mut next_info);
                    // thread/list carries no turn data, so it cannot authoritatively
                    // close an in-flight turn. Only TurnCompleted (or a rebuild that
                    // includes the turn list) can downgrade Active → Idle.
                    if matches!(next_info.status, ThreadSummaryStatus::Idle)
                        && entry.active_turn_id.is_some()
                    {
                        next_info.status = entry.info.status.clone();
                    }
                    let next_model = next_info.model.clone().or_else(|| entry.model.clone());
                    let info_changed = entry.info != next_info;
                    let model_changed = entry.model != next_model;
                    if info_changed || model_changed {
                        entry.info = next_info;
                        entry.model = next_model;
                        updated_thread_keys.push(key.clone());
                    }
                    if entry.agent_runtime_kind != runtime_kind {
                        entry.agent_runtime_kind = runtime_kind;
                        updated_thread_keys.push(key);
                    }
                } else {
                    let mut thread = ThreadSnapshot::from_info(server_id, info.clone());
                    thread.agent_runtime_kind = runtime_kind;
                    snapshot.threads.insert(key.clone(), thread);
                    upserted_thread_keys.push(key);
                }
            }
            if snapshot.active_thread.as_ref().is_some_and(|key| {
                key.server_id == server_id && !incoming_ids.contains(&key.thread_id)
            }) {
                let should_clear = snapshot
                    .active_thread
                    .as_ref()
                    .is_some_and(|key| !snapshot.threads.contains_key(key));
                if should_clear {
                    snapshot.active_thread = None;
                    active_thread_cleared = true;
                }
            }
            let approvals_before = snapshot.pending_approvals.len();
            snapshot.pending_approvals.retain(|approval| {
                approval.thread_id.as_deref().is_none_or(|tid| {
                    !removed_thread_keys
                        .iter()
                        .any(|key| key.thread_id.as_str() == tid)
                })
            });
            let remaining_approval_keys = snapshot
                .pending_approvals
                .iter()
                .map(|approval| PendingApprovalKey {
                    server_id: approval.server_id.clone(),
                    request_id: approval.id.clone(),
                })
                .collect::<HashSet<_>>();
            snapshot
                .pending_approval_seeds
                .retain(|key, _| remaining_approval_keys.contains(key));
            if snapshot.pending_approvals.len() != approvals_before {
                pending_approvals = Some(snapshot.pending_approvals.clone());
            }
            let pending_user_inputs_before = snapshot.pending_user_inputs.len();
            snapshot.pending_user_inputs.retain(|request| {
                !(request.server_id == server_id
                    && removed_thread_keys
                        .iter()
                        .any(|key| key.thread_id == request.thread_id))
            });
            if snapshot.pending_user_inputs.len() != pending_user_inputs_before {
                pending_user_inputs = Some(snapshot.pending_user_inputs.clone());
            }
            // See `finalize_thread_list_sync`: we do NOT tear down an
            // active voice session just because the thread/list page
            // happens to omit the voice thread. The thread may simply
            // be too new, or the page may be filtered. Let
            // RealtimeStarted/RealtimeClosed drive voice_session state.
            agent_directory_version = current_agent_directory_version(&snapshot);
        }
        for key in removed_thread_keys {
            self.clear_thread_update_caches(&key);
            self.emit(AppStoreUpdateRecord::ThreadRemoved {
                key,
                agent_directory_version,
            });
        }
        for key in upserted_thread_keys {
            self.emit_thread_upsert(&key);
        }
        for key in updated_thread_keys {
            self.emit_thread_metadata_changed(&key);
        }
        if let Some(approvals) = pending_approvals {
            self.emit(AppStoreUpdateRecord::PendingApprovalsChanged { approvals });
        }
        if let Some(requests) = pending_user_inputs {
            self.emit(AppStoreUpdateRecord::PendingUserInputsChanged { requests });
        }
        if active_thread_cleared {
            self.emit(AppStoreUpdateRecord::ActiveThreadChanged { key: None });
        }
    }

    pub fn upsert_thread_list_page(&self, server_id: &str, threads: &[ThreadInfo]) {
        self.upsert_thread_list_page_for_runtime(server_id, AgentRuntimeKind::Codex, threads);
    }

    pub fn upsert_thread_list_page_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        threads: &[ThreadInfo],
    ) {
        for info in threads {
            let mut snapshot = ThreadSnapshot::from_info(server_id, info.clone());
            snapshot.agent_runtime_kind = runtime_kind;
            self.upsert_thread_snapshot(snapshot);
        }
    }

    pub fn finalize_thread_list_sync(&self, server_id: &str, incoming_ids: &HashSet<String>) {
        let mut removed_thread_keys = Vec::new();
        let mut active_thread_cleared = false;
        let mut pending_approvals = None;
        let mut pending_user_inputs = None;
        let agent_directory_version;
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let active_thread_key = snapshot.active_thread.clone();
            snapshot.threads.retain(|key, _| {
                let keep = key.server_id != server_id
                    || incoming_ids.contains(&key.thread_id)
                    || active_thread_key.as_ref() == Some(key);
                if !keep {
                    removed_thread_keys.push(key.clone());
                }
                keep
            });
            if snapshot.active_thread.as_ref().is_some_and(|key| {
                key.server_id == server_id && !incoming_ids.contains(&key.thread_id)
            }) {
                let should_clear = snapshot
                    .active_thread
                    .as_ref()
                    .is_some_and(|key| !snapshot.threads.contains_key(key));
                if should_clear {
                    snapshot.active_thread = None;
                    active_thread_cleared = true;
                }
            }
            let approvals_before = snapshot.pending_approvals.len();
            snapshot.pending_approvals.retain(|approval| {
                approval.thread_id.as_deref().is_none_or(|tid| {
                    !removed_thread_keys
                        .iter()
                        .any(|key| key.thread_id.as_str() == tid)
                })
            });
            let remaining_approval_keys = snapshot
                .pending_approvals
                .iter()
                .map(|approval| PendingApprovalKey {
                    server_id: approval.server_id.clone(),
                    request_id: approval.id.clone(),
                })
                .collect::<HashSet<_>>();
            snapshot
                .pending_approval_seeds
                .retain(|key, _| remaining_approval_keys.contains(key));
            if snapshot.pending_approvals.len() != approvals_before {
                pending_approvals = Some(snapshot.pending_approvals.clone());
            }
            let pending_user_inputs_before = snapshot.pending_user_inputs.len();
            snapshot.pending_user_inputs.retain(|request| {
                !(request.server_id == server_id
                    && removed_thread_keys
                        .iter()
                        .any(|key| key.thread_id == request.thread_id))
            });
            if snapshot.pending_user_inputs.len() != pending_user_inputs_before {
                pending_user_inputs = Some(snapshot.pending_user_inputs.clone());
            }
            // Intentionally do NOT clear voice_session here based on
            // list-sync output. A list_threads RPC may omit a brand-new
            // voice thread (e.g. the one realtime voice is running on
            // right now was created seconds ago and isn't materialized
            // in the listing yet). When the assistant itself calls the
            // `list_sessions` tool mid-conversation, clearing
            // voice_session here would tear down the live call. The
            // authoritative lifecycle signal is RealtimeStarted /
            // RealtimeClosed.
            agent_directory_version = current_agent_directory_version(&snapshot);
        }
        for key in removed_thread_keys {
            self.emit(AppStoreUpdateRecord::ThreadRemoved {
                key,
                agent_directory_version,
            });
        }
        if let Some(approvals) = pending_approvals {
            self.emit(AppStoreUpdateRecord::PendingApprovalsChanged { approvals });
        }
        if let Some(requests) = pending_user_inputs {
            self.emit(AppStoreUpdateRecord::PendingUserInputsChanged { requests });
        }
        if active_thread_cleared {
            self.emit(AppStoreUpdateRecord::ActiveThreadChanged { key: None });
        }
    }

    pub fn upsert_thread_snapshot(&self, mut thread: ThreadSnapshot) {
        let key = thread.key.clone();
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let existing = snapshot.threads.get(&key).cloned();
            if let Some(existing) = existing.as_ref() {
                // Diagnostic for the duplicate-user-message bug (task #11):
                // catch transient overlap where the incoming snapshot's
                // hydrated User items match an overlay that's already in
                // existing.local_overlay_items (sticking around past its
                // dedupe). Logs once per upsert when the condition fires.
                let user_overlay_count = existing
                    .local_overlay_items
                    .iter()
                    .filter(|item| {
                        matches!(&item.content, HydratedConversationItemContent::User(_))
                    })
                    .count();
                let incoming_user_count = thread
                    .items
                    .iter()
                    .filter(|item| {
                        matches!(&item.content, HydratedConversationItemContent::User(_))
                    })
                    .count();
                if user_overlay_count > 0 && incoming_user_count > 0 {
                    tracing::warn!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        existing_user_overlay_count = user_overlay_count,
                        incoming_user_item_count = incoming_user_count,
                        existing_user_item_count = existing
                            .items
                            .iter()
                            .filter(|item| {
                                matches!(
                                    &item.content,
                                    HydratedConversationItemContent::User(_)
                                )
                            })
                            .count(),
                        "upsert_thread_snapshot: existing overlay + incoming user items overlap"
                    );
                }
                preserve_thread_title(&existing.info, &mut thread.info);
                preserve_thread_preview(&existing.info, &mut thread.info);
                preserve_thread_created_at(&existing.info, &mut thread.info);
                preserve_thread_runtime_state(existing, &mut thread);
                if thread.agent_runtime_kind == AgentRuntimeKind::Codex
                    && existing.agent_runtime_kind != AgentRuntimeKind::Codex
                {
                    thread.agent_runtime_kind = existing.agent_runtime_kind;
                }
                thread.is_resumed = thread.is_resumed || existing.is_resumed;
                preserve_local_overlay_items(existing, &mut thread);
                preserve_queued_follow_ups(existing, &mut thread);
                // Preserve existing items when the incoming snapshot has none
                // (e.g. thread/read with include_turns=false).
                if thread.items.is_empty() && !existing.items.is_empty() {
                    thread.items = existing.items.clone();
                }
            }
            if !thread.queued_follow_up_drafts.is_empty() || thread.queued_follow_ups.is_empty() {
                sync_thread_follow_up_projection(&mut thread);
            }
            snapshot.threads.insert(key.clone(), thread);
        }
        self.emit_thread_upsert(&key);
    }

    pub fn mark_thread_resumed(&self, key: &ThreadKey, is_resumed: bool) {
        let changed = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let Some(thread) = snapshot.threads.get_mut(key) else {
                return;
            };
            if thread.is_resumed == is_resumed {
                false
            } else {
                thread.is_resumed = is_resumed;
                true
            }
        };
        if changed {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub fn enqueue_thread_follow_up_preview(
        &self,
        key: &ThreadKey,
        preview: AppQueuedFollowUpPreview,
    ) {
        self.enqueue_thread_follow_up_draft(
            key,
            QueuedFollowUpDraft {
                preview,
                inputs: Vec::new(),
                source_message_json: None,
            },
        );
    }

    pub(crate) fn enqueue_thread_follow_up_draft(
        &self,
        key: &ThreadKey,
        draft: QueuedFollowUpDraft,
    ) {
        if self
            .mutate_thread_with_result(key, |thread| {
                thread.queued_follow_up_drafts.push(draft);
                sync_thread_follow_up_projection(thread);
            })
            .is_some()
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub(crate) fn stage_local_user_message_overlay(
        &self,
        key: &ThreadKey,
        inputs: &[upstream::UserInput],
    ) -> Option<String> {
        let item = local_user_message_overlay_item(inputs)?;
        let emitted_item = item.clone();
        let item_id = item.id.clone();
        let updated = self.mutate_thread_with_result(key, |thread| {
            thread
                .local_overlay_items
                .retain(|existing| !is_duplicate_overlay_item(&item, existing));
            thread.local_overlay_items.push(item);
        });
        if updated.is_none() {
            // Diagnostic for the duplicate-user-message bug (task #11): if
            // the thread isn't in the store yet, the overlay silently drops
            // and the iOS UI relies entirely on the upstream item arriving
            // via events. If something else later inserts a second copy,
            // we get two bubbles. Log so the next device run shows whether
            // this is the path being hit.
            tracing::warn!(
                target: "store",
                server_id = key.server_id,
                thread_id = key.thread_id,
                overlay_id = item_id,
                "stage_local_user_message_overlay skipped: thread not in store"
            );
            return None;
        }
        self.emit_thread_item_changed(key, emitted_item);
        Some(item_id)
    }

    pub(crate) fn bind_local_user_message_overlay_to_turn(
        &self,
        key: &ThreadKey,
        item_id: &str,
        turn_id: &str,
    ) {
        if let Some((updated_item, removed_item_ids)) =
            self.mutate_thread_with_result(key, |thread| {
                let mut updated_item = None;
                if let Some(item) = thread
                    .local_overlay_items
                    .iter_mut()
                    .find(|item| item.id == item_id)
                {
                    if item.source_turn_id.as_deref() != Some(turn_id) {
                        item.source_turn_id = Some(turn_id.to_string());
                    }
                    updated_item = Some(item.clone());
                }
                let removed_item_ids = duplicate_local_overlay_item_ids(thread);
                remove_duplicate_local_overlay_items(thread);
                (
                    updated_item.filter(|item| {
                        thread
                            .local_overlay_items
                            .iter()
                            .any(|existing| existing.id == item.id)
                    }),
                    removed_item_ids,
                )
            })
        {
            if !removed_item_ids.is_empty() {
                self.emit_thread_upsert(key);
            } else if let Some(item) = updated_item {
                self.emit_thread_item_changed(key, item);
            }
        }
    }

    pub(crate) fn bind_first_pending_local_user_message_overlay_to_turn(
        &self,
        key: &ThreadKey,
        turn_id: &str,
    ) {
        if let Some((updated_item, removed_item_ids)) =
            self.mutate_thread_with_result(key, |thread| {
                let mut updated_item = None;
                if let Some(item) = thread.local_overlay_items.iter_mut().find(|item| {
                    item.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX)
                        && item.source_turn_id.is_none()
                }) {
                    item.source_turn_id = Some(turn_id.to_string());
                    updated_item = Some(item.clone());
                }
                let removed_item_ids = duplicate_local_overlay_item_ids(thread);
                remove_duplicate_local_overlay_items(thread);
                (
                    updated_item.filter(|item| {
                        thread
                            .local_overlay_items
                            .iter()
                            .any(|existing| existing.id == item.id)
                    }),
                    removed_item_ids,
                )
            })
        {
            if !removed_item_ids.is_empty() {
                self.emit_thread_upsert(key);
            } else if let Some(item) = updated_item {
                self.emit_thread_item_changed(key, item);
            }
        }
    }

    pub(crate) fn remove_local_overlay_item(&self, key: &ThreadKey, item_id: &str) {
        if self
            .mutate_thread_with_result(key, |thread| {
                let before = thread.local_overlay_items.len();
                thread.local_overlay_items.retain(|item| item.id != item_id);
                (before != thread.local_overlay_items.len()).then_some(())
            })
            .flatten()
            .is_some()
        {
            self.emit_thread_upsert(key);
        }
    }

    pub fn set_thread_collaboration_mode(&self, key: &ThreadKey, mode: AppModeKind) {
        if self
            .mutate_thread_with_result(key, |thread| {
                if thread.collaboration_mode == mode {
                    return false;
                }
                thread.collaboration_mode = mode;
                true
            })
            .unwrap_or(false)
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub fn dismiss_plan_implementation_prompt(&self, key: &ThreadKey) {
        if self
            .mutate_thread_with_result(key, |thread| {
                let had_prompt = thread.pending_plan_implementation_turn_id.is_some();
                thread.pending_plan_implementation_turn_id = None;
                had_prompt
            })
            .unwrap_or(false)
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub fn remove_thread_follow_up_preview(&self, key: &ThreadKey, preview_id: &str) {
        self.remove_thread_follow_up_draft(key, preview_id);
    }

    pub(crate) fn remove_thread_follow_up_draft(&self, key: &ThreadKey, preview_id: &str) {
        if self
            .mutate_thread_with_result(key, |thread| {
                thread
                    .queued_follow_up_drafts
                    .retain(|draft| draft.preview.id != preview_id);
                sync_thread_follow_up_projection(thread);
            })
            .is_some()
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub(crate) fn update_thread_follow_up_draft_kind(
        &self,
        key: &ThreadKey,
        preview_id: &str,
        kind: super::snapshot::AppQueuedFollowUpKind,
    ) {
        if self
            .mutate_thread_with_result(key, |thread| {
                for draft in &mut thread.queued_follow_up_drafts {
                    if draft.preview.id == preview_id {
                        draft.preview.kind = kind;
                        break;
                    }
                }
                sync_thread_follow_up_projection(thread);
            })
            .is_some()
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub fn set_thread_follow_up_previews(
        &self,
        key: &ThreadKey,
        previews: Vec<AppQueuedFollowUpPreview>,
    ) {
        let drafts = previews
            .into_iter()
            .map(|preview| QueuedFollowUpDraft {
                preview,
                inputs: Vec::new(),
                source_message_json: None,
            })
            .collect();
        self.set_thread_follow_up_drafts(key, drafts);
    }

    pub(crate) fn set_thread_follow_up_drafts(
        &self,
        key: &ThreadKey,
        drafts: Vec<QueuedFollowUpDraft>,
    ) {
        if self
            .mutate_thread_with_result(key, |thread| {
                if thread.queued_follow_up_drafts == drafts {
                    return false;
                }
                thread.queued_follow_up_drafts = drafts;
                sync_thread_follow_up_projection(thread);
                true
            })
            .unwrap_or(false)
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub fn remove_thread(&self, key: &ThreadKey) {
        let agent_directory_version;
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.threads.remove(key);
            if snapshot.active_thread.as_ref() == Some(key) {
                snapshot.active_thread = None;
            }
            if snapshot.voice_session.active_thread.as_ref() == Some(key) {
                snapshot.voice_session = AppVoiceSessionSnapshot::default();
            }
            snapshot
                .pending_approvals
                .retain(|approval| approval.thread_id.as_deref() != Some(key.thread_id.as_str()));
            snapshot.pending_user_inputs.retain(|request| {
                !(request.server_id == key.server_id && request.thread_id == key.thread_id)
            });
            agent_directory_version = current_agent_directory_version(&snapshot);
        }
        self.clear_thread_update_caches(key);
        self.emit(AppStoreUpdateRecord::ThreadRemoved {
            key: key.clone(),
            agent_directory_version,
        });
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.active_thread = key.clone();
        }
        self.emit(AppStoreUpdateRecord::ActiveThreadChanged { key });
    }

    pub fn set_voice_handoff_thread(&self, key: Option<ThreadKey>) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.voice_session.handoff_thread_key = key;
        }
        self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
    }

    pub fn replace_pending_approvals(&self, approvals: Vec<PendingApproval>) {
        let changed = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if snapshot.pending_approvals == approvals && snapshot.pending_approval_seeds.is_empty()
            {
                false
            } else {
                snapshot.pending_approvals = approvals.clone();
                snapshot.pending_approval_seeds.clear();
                true
            }
        };
        if changed {
            self.emit(AppStoreUpdateRecord::PendingApprovalsChanged { approvals });
        }
    }

    pub(crate) fn replace_pending_approvals_with_seeds(
        &self,
        approvals: Vec<PendingApprovalWithSeed>,
    ) {
        let public_approvals = approvals
            .iter()
            .map(|entry| entry.approval.clone())
            .collect::<Vec<_>>();
        let next_seeds = approvals
            .into_iter()
            .map(|entry| {
                (
                    PendingApprovalKey {
                        server_id: entry.approval.server_id.clone(),
                        request_id: entry.approval.id.clone(),
                    },
                    entry.seed,
                )
            })
            .collect::<HashMap<_, _>>();
        let changed = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if snapshot.pending_approvals == public_approvals
                && snapshot.pending_approval_seeds == next_seeds
            {
                false
            } else {
                snapshot.pending_approvals = public_approvals.clone();
                snapshot.pending_approval_seeds = next_seeds;
                true
            }
        };
        if changed {
            self.emit(AppStoreUpdateRecord::PendingApprovalsChanged {
                approvals: public_approvals,
            });
        }
    }

    pub fn replace_pending_user_inputs(&self, requests: Vec<PendingUserInputRequest>) {
        let changed = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if snapshot.pending_user_inputs == requests {
                false
            } else {
                snapshot.pending_user_inputs = requests.clone();
                true
            }
        };
        if changed {
            self.emit(AppStoreUpdateRecord::PendingUserInputsChanged { requests });
        }
    }

    pub fn resolve_approval(&self, request_id: &str) {
        let approvals = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot
                .pending_approvals
                .retain(|approval| approval.id != request_id);
            snapshot
                .pending_approval_seeds
                .retain(|key, _| key.request_id != request_id);
            snapshot.pending_approvals.clone()
        };
        self.emit(AppStoreUpdateRecord::PendingApprovalsChanged { approvals });
    }

    pub(crate) fn pending_approval_seed(
        &self,
        server_id: &str,
        request_id: &str,
    ) -> Option<PendingApprovalSeed> {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .pending_approval_seeds
            .get(&PendingApprovalKey {
                server_id: server_id.to_string(),
                request_id: request_id.to_string(),
            })
            .cloned()
    }

    pub fn resolve_pending_user_input(&self, request_id: &str) {
        let requests = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot
                .pending_user_inputs
                .retain(|request| request.id != request_id);
            snapshot.pending_user_inputs.clone()
        };
        self.emit(AppStoreUpdateRecord::PendingUserInputsChanged { requests });
    }

    pub fn resolve_pending_user_input_with_response(
        &self,
        request_id: &str,
        answers: Vec<PendingUserInputAnswer>,
    ) {
        let (requests, thread_key) = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let request = snapshot
                .pending_user_inputs
                .iter()
                .find(|request| request.id == request_id)
                .cloned();

            let mut thread_key = None;
            if let Some(request) = request {
                thread_key = Some(ThreadKey {
                    server_id: request.server_id.clone(),
                    thread_id: request.thread_id.clone(),
                });
                if let Some(thread) = snapshot.threads.get_mut(&ThreadKey {
                    server_id: request.server_id.clone(),
                    thread_id: request.thread_id.clone(),
                }) {
                    let item = answered_user_input_item(&request, &answers);
                    thread
                        .local_overlay_items
                        .retain(|existing| !is_duplicate_overlay_item(&item, existing));
                    thread.local_overlay_items.push(item);
                }
            }

            snapshot
                .pending_user_inputs
                .retain(|request| request.id != request_id);
            (snapshot.pending_user_inputs.clone(), thread_key)
        };
        self.emit(AppStoreUpdateRecord::PendingUserInputsChanged { requests });
        if let Some(key) = thread_key {
            self.emit_thread_upsert(&key);
        }
    }

    pub fn update_server_account(
        &self,
        server_id: &str,
        account: Option<crate::types::Account>,
        requires_openai_auth: bool,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.account = account;
                server.requires_openai_auth = requires_openai_auth;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn update_server_rate_limits(
        &self,
        server_id: &str,
        rate_limits: Option<crate::types::RateLimitSnapshot>,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.rate_limits = rate_limits;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn update_server_models(
        &self,
        server_id: &str,
        models: Option<Vec<crate::types::ModelInfo>>,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.available_models = models;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn update_server_agent_runtimes(&self, server_id: &str, runtimes: Vec<AgentRuntimeInfo>) {
        let runtimes = dedupe_agent_runtimes(runtimes);
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.agent_runtimes = runtimes;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn set_thread_agent_runtime(&self, key: &ThreadKey, runtime_kind: AgentRuntimeKind) {
        let changed = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let Some(thread) = snapshot.threads.get_mut(key) else {
                return;
            };
            if thread.agent_runtime_kind == runtime_kind {
                false
            } else {
                thread.agent_runtime_kind = runtime_kind;
                true
            }
        };
        if changed {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub fn update_server_ipc_state(&self, server_id: &str, has_ipc: bool) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.transport.actual_ipc_connected = has_ipc;
                match server.transport.authority {
                    ServerTransportAuthority::IpcPrimary => {
                        server.has_ipc = has_ipc;
                    }
                    ServerTransportAuthority::Recovering => {
                        if has_ipc {
                            server.transport.authority = ServerTransportAuthority::IpcPrimary;
                            server.transport.last_ipc_failure = None;
                            server.has_ipc = true;
                        } else {
                            server.has_ipc = false;
                        }
                    }
                    ServerTransportAuthority::DirectOnly => {
                        if has_ipc && server.transport.last_ipc_failure.is_none() {
                            server.transport.authority = ServerTransportAuthority::IpcPrimary;
                            server.has_ipc = true;
                        } else {
                            server.has_ipc = false;
                        }
                    }
                }
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn update_server_health(&self, server_id: &str, health: ServerHealthSnapshot) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.health = health;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn set_server_supports_turn_pagination(&self, server_id: &str, supports: bool) {
        let changed = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            match snapshot.servers.get_mut(server_id) {
                Some(server) if server.supports_turn_pagination != supports => {
                    server.supports_turn_pagination = supports;
                    true
                }
                _ => false,
            }
        };
        if changed {
            self.emit(AppStoreUpdateRecord::ServerChanged {
                server_id: server_id.to_string(),
            });
        }
    }

    pub fn server_supports_turn_pagination(&self, server_id: &str) -> bool {
        let snapshot = self.snapshot.read().expect("app store lock poisoned");
        snapshot
            .servers
            .get(server_id)
            .map(|server| server.supports_turn_pagination)
            .unwrap_or(true)
    }

    pub fn note_app_lifecycle_phase(&self, phase: AppLifecyclePhaseSnapshot) {
        let now = std::time::Instant::now();
        let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
        for server in snapshot.servers.values_mut() {
            server.transport.last_lifecycle_phase = phase;
            server.transport.last_lifecycle_transition_at = Some(now);
            if phase == AppLifecyclePhaseSnapshot::Active {
                server.transport.last_resumed_at = Some(now);
            }
        }
    }

    pub fn server_transport_authority(&self, server_id: &str) -> Option<ServerTransportAuthority> {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .servers
            .get(server_id)
            .map(|server| server.transport.authority)
    }

    pub fn is_server_ipc_primary(&self, server_id: &str) -> bool {
        self.server_transport_authority(server_id) == Some(ServerTransportAuthority::IpcPrimary)
    }

    pub fn server_has_active_turns(&self, server_id: &str) -> bool {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .threads
            .iter()
            .any(|(key, thread)| {
                key.server_id == server_id
                    && (thread.active_turn_id.is_some()
                        || thread.info.status == ThreadSummaryStatus::Active)
            })
    }

    pub fn server_pending_mutation_kind(
        &self,
        server_id: &str,
    ) -> Option<ServerMutatingCommandKind> {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .servers
            .get(server_id)
            .and_then(|server| server.transport.pending_mutation.as_ref())
            .map(|pending| pending.kind)
    }

    pub fn mark_server_ipc_primary(&self, server_id: &str) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.transport.authority = ServerTransportAuthority::IpcPrimary;
                server.transport.last_ipc_failure = None;
                server.has_ipc = server.transport.actual_ipc_connected || server.has_ipc;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn mark_server_ipc_recovering(&self, server_id: &str) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.transport.authority = ServerTransportAuthority::Recovering;
                server.has_ipc = false;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn fail_server_over_to_direct_only(
        &self,
        server_id: &str,
        classification: IpcFailureClassification,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.transport.authority = ServerTransportAuthority::DirectOnly;
                server.transport.last_ipc_failure = Some(classification);
                server.has_ipc = false;
                server.transport.pending_mutation = None;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn note_server_ipc_broadcast(&self, server_id: &str) {
        let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
        if let Some(server) = snapshot.servers.get_mut(server_id) {
            server.transport.last_ipc_broadcast_at = Some(std::time::Instant::now());
        }
    }

    pub fn begin_server_mutating_command(
        &self,
        server_id: &str,
        kind: ServerMutatingCommandKind,
        thread_id: &str,
        route: ServerMutatingCommandRoute,
    ) -> String {
        let request_id = uuid::Uuid::new_v4().to_string();
        let started_at = std::time::Instant::now();
        let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
        if let Some(server) = snapshot.servers.get_mut(server_id) {
            server.transport.pending_mutation = Some(PendingServerMutatingCommand {
                kind,
                thread_id: thread_id.to_string(),
                local_request_id: request_id.clone(),
                started_at,
                route,
                lifecycle_phase_at_send: server.transport.last_lifecycle_phase,
            });
        }
        request_id
    }

    pub fn finish_server_mutating_command_success(
        &self,
        server_id: &str,
        local_request_id: &str,
        route: ServerMutatingCommandRoute,
    ) {
        let now = std::time::Instant::now();
        let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
        if let Some(server) = snapshot.servers.get_mut(server_id) {
            if server
                .transport
                .pending_mutation
                .as_ref()
                .is_some_and(|pending| pending.local_request_id == local_request_id)
            {
                server.transport.pending_mutation = None;
            }
            match route {
                ServerMutatingCommandRoute::Ipc => {
                    server.transport.last_ipc_mutation_ok_at = Some(now)
                }
                ServerMutatingCommandRoute::Direct => {
                    server.transport.last_direct_request_ok_at = Some(now)
                }
            }
        }
    }

    pub fn note_server_direct_request_success(&self, server_id: &str) {
        let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
        if let Some(server) = snapshot.servers.get_mut(server_id) {
            server.transport.last_direct_request_ok_at = Some(std::time::Instant::now());
        }
    }

    pub fn classify_ipc_mutation_failure(
        &self,
        server_id: &str,
        transport_lost: bool,
        timed_out: bool,
    ) -> IpcFailureClassification {
        let snapshot = self.snapshot.read().expect("app store lock poisoned");
        let Some(server) = snapshot.servers.get(server_id) else {
            return IpcFailureClassification::UnknownTimeout;
        };

        if transport_lost || !server.transport.actual_ipc_connected {
            return IpcFailureClassification::IpcConnectionLost;
        }

        if server.health != ServerHealthSnapshot::Connected {
            return IpcFailureClassification::ServerTransportUnhealthy;
        }

        if let Some(pending) = server.transport.pending_mutation.as_ref() {
            if server.transport.last_lifecycle_phase != pending.lifecycle_phase_at_send
                || server
                    .transport
                    .last_lifecycle_transition_at
                    .is_some_and(|at| at >= pending.started_at)
            {
                return IpcFailureClassification::LifecycleInterrupted;
            }
        }

        if timed_out {
            IpcFailureClassification::FollowerCommandTimeoutWhileIpcHealthy
        } else {
            IpcFailureClassification::UnknownTimeout
        }
    }

    pub fn update_server_connection_progress(
        &self,
        server_id: &str,
        connection_progress: Option<AppConnectionProgressSnapshot>,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.connection_progress = connection_progress;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn rename_server(&self, server_id: &str, display_name: String) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.display_name = display_name;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn update_server_wake_mac(&self, server_id: &str, wake_mac: Option<String>) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.wake_mac = wake_mac;
            }
        }
        self.emit(AppStoreUpdateRecord::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub(crate) fn apply_ui_event(&self, event: &UiEvent) {
        match event {
            UiEvent::ThreadStarted { key, notification } => {
                let info = thread_info_from_upstream(notification.thread.clone());
                self.upsert_or_merge_thread(key.clone(), info, |thread| {
                    thread.info.status = ThreadSummaryStatus::Active;
                    if thread.info.parent_thread_id.is_some() {
                        thread.info.agent_status = Some("running".to_string());
                    }
                });
            }
            UiEvent::ThreadArchived { key } => {
                self.remove_thread(key);
            }
            UiEvent::ThreadNameUpdated { key, thread_name } => {
                self.mutate_thread(key, |thread| {
                    thread.info.title = thread_name.clone();
                });
            }
            UiEvent::ThreadStatusChanged { key, notification } => {
                let info = thread_info_from_upstream_status_change(
                    &notification.thread_id,
                    notification.status.clone(),
                );
                self.upsert_or_merge_thread(key.clone(), info, |thread| {
                    if thread.info.parent_thread_id.is_some() {
                        thread.info.agent_status = match thread.info.status {
                            ThreadSummaryStatus::Active => Some("running".to_string()),
                            ThreadSummaryStatus::SystemError => Some("errored".to_string()),
                            ThreadSummaryStatus::Idle => thread
                                .info
                                .agent_status
                                .clone()
                                .or(Some("completed".to_string())),
                            ThreadSummaryStatus::NotLoaded => thread.info.agent_status.clone(),
                        };
                    }
                });
            }
            UiEvent::ModelRerouted { key, notification } => {
                let item = make_model_rerouted_item(
                    &notification.turn_id,
                    Some(notification.from_model.clone()),
                    notification.to_model.clone(),
                    Some(format_model_reroute_reason(&notification.reason)),
                    Some(&notification.turn_id),
                );
                if self
                    .mutate_thread_with_result(key, |thread| {
                        thread.model = Some(notification.to_model.clone());
                        thread.info.model = Some(notification.to_model.clone());
                        upsert_item(thread, item.clone());
                    })
                    .is_some()
                {
                    self.emit_thread_metadata_changed(key);
                    self.emit_thread_item_changed(key, item);
                }
            }
            UiEvent::TurnStarted { key, turn_id } => {
                if self
                    .mutate_thread_with_result(key, |thread| {
                        remove_first_queued_follow_up(thread);
                        thread.active_turn_id = Some(turn_id.clone());
                        thread.active_plan_progress = None;
                        thread.pending_plan_implementation_turn_id = None;
                        thread.info.status = ThreadSummaryStatus::Active;
                        if thread.info.parent_thread_id.is_some() {
                            thread.info.agent_status = Some("running".to_string());
                        }
                    })
                    .is_some()
                {
                    self.bind_first_pending_local_user_message_overlay_to_turn(key, turn_id);
                    self.emit_thread_metadata_changed(key);
                }
            }
            UiEvent::TurnCompleted { key, turn_id, .. } => {
                if self
                    .mutate_thread_with_result(key, |thread| {
                        thread.active_turn_id = None;
                        thread.active_plan_progress = None;
                        thread.info.status = ThreadSummaryStatus::Idle;
                        if thread.info.parent_thread_id.is_some() {
                            thread.info.agent_status = Some("completed".to_string());
                        }
                        // Clean up user input response overlays — they were
                        // answered during this turn and no longer need to show.
                        thread
                            .local_overlay_items
                            .retain(|item| !item.id.starts_with(USER_INPUT_RESPONSE_ITEM_PREFIX));
                        // Clean up steered follow-ups now that the turn is done.
                        thread.queued_follow_up_drafts.retain(|draft| {
                            draft.preview.kind
                                != super::snapshot::AppQueuedFollowUpKind::PendingSteer
                        });
                        sync_thread_follow_up_projection(thread);
                        // Show the plan implementation prompt after the plan
                        // turn finishes so implement_plan can safely start a
                        // new turn without colliding with the active one.
                        if thread.collaboration_mode == AppModeKind::Plan
                            && thread.items.iter().any(|item| {
                                matches!(
                                    item.content,
                                    HydratedConversationItemContent::ProposedPlan { .. }
                                )
                            })
                            && thread.pending_plan_implementation_turn_id.is_none()
                        {
                            thread.pending_plan_implementation_turn_id = Some(turn_id.to_string());
                        }
                    })
                    .is_some()
                {
                    self.emit_thread_metadata_changed(key);
                }
            }
            UiEvent::TurnPlanUpdated { key, notification } => {
                if self
                    .mutate_thread_with_result(key, |thread| {
                        thread.active_plan_progress = Some(AppPlanProgressSnapshot {
                            turn_id: notification.turn_id.clone(),
                            explanation: notification.explanation.clone(),
                            plan: notification
                                .plan
                                .iter()
                                .cloned()
                                .map(AppPlanStep::from)
                                .collect(),
                        });
                    })
                    .is_some()
                {
                    self.emit_thread_metadata_changed(key);
                }
            }
            UiEvent::ItemStarted { key, notification } => {
                if let Some(item) = conversation_item_from_upstream_with_turn(
                    notification.item.clone(),
                    Some(&notification.turn_id),
                ) {
                    self.apply_item_update(key, item);
                }
            }
            UiEvent::ItemCompleted { key, notification } => {
                // Clear any streaming dynamic-tool-call argument buffers
                // that were accumulating for this item — the call has
                // finalized (or failed) and further partial-parse work
                // is wasted.
                if matches!(
                    notification.item,
                    codex_app_server_protocol::ThreadItem::DynamicToolCall { .. }
                ) {
                    let item_id = notification.item.id().to_string();
                    self.clear_dynamic_tool_arg_buffers_for_item(key, &item_id);
                }
                if let Some(item) = conversation_item_from_upstream_with_turn(
                    notification.item.clone(),
                    Some(&notification.turn_id),
                ) {
                    self.apply_item_update(key, item);
                }
                if matches!(
                    notification.item,
                    codex_app_server_protocol::ThreadItem::Plan { .. }
                ) && self
                    .mutate_thread_with_result(key, |thread| {
                        if thread.collaboration_mode != AppModeKind::Plan {
                            thread.collaboration_mode = AppModeKind::Plan;
                            return true;
                        }
                        false
                    })
                    .unwrap_or(false)
                {
                    self.emit_thread_metadata_changed(key);
                }
            }
            UiEvent::MessageDelta {
                key,
                item_id,
                delta,
            } => {
                let inserted_placeholder = self
                    .mutate_thread_with_result(key, |thread| {
                        append_assistant_delta(thread, item_id, delta)
                    })
                    .unwrap_or(false);
                if inserted_placeholder {
                    self.emit_thread_item_changed_by_id(key, item_id);
                } else {
                    self.emit_thread_streaming_delta(
                        key,
                        item_id,
                        ThreadStreamingDeltaKind::AssistantText,
                        delta,
                    );
                }
            }
            UiEvent::ReasoningDelta {
                key,
                item_id,
                delta,
            } => {
                let result = self
                    .mutate_thread_with_result(key, |thread| {
                        append_reasoning_delta(thread, item_id, delta)
                    })
                    .unwrap_or(LiveDeltaApplyResult::Failed);
                if result.streamed() {
                    self.emit_thread_streaming_delta(
                        key,
                        item_id,
                        ThreadStreamingDeltaKind::ReasoningText,
                        delta,
                    );
                } else if result.requires_item_upsert() {
                    self.emit_thread_item_changed_by_id(key, item_id);
                } else {
                    tracing::debug!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        item_id,
                        kind = "reasoning",
                        "falling back to ThreadUpserted after live delta repair failed"
                    );
                    self.emit_thread_upsert(key);
                }
            }
            UiEvent::PlanDelta {
                key,
                item_id,
                delta,
            } => {
                let result = self
                    .mutate_thread_with_result(key, |thread| {
                        append_plan_delta(thread, item_id, delta)
                    })
                    .unwrap_or(LiveDeltaApplyResult::Failed);
                if result.streamed() {
                    self.emit_thread_streaming_delta(
                        key,
                        item_id,
                        ThreadStreamingDeltaKind::PlanText,
                        delta,
                    );
                } else if result.requires_item_upsert() {
                    self.emit_thread_item_changed_by_id(key, item_id);
                } else {
                    tracing::debug!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        item_id,
                        kind = "plan",
                        "falling back to ThreadUpserted after live delta repair failed"
                    );
                    self.emit_thread_upsert(key);
                }
            }
            UiEvent::CommandOutputDelta {
                key,
                item_id,
                delta,
            } => {
                let result = self
                    .mutate_thread_with_result(key, |thread| {
                        append_command_output_delta(thread, item_id, delta)
                    })
                    .unwrap_or(LiveDeltaApplyResult::Failed);
                if result.streamed() {
                    self.emit_thread_streaming_delta(
                        key,
                        item_id,
                        ThreadStreamingDeltaKind::CommandOutput,
                        delta,
                    );
                } else if result.requires_item_upsert() {
                    self.emit_thread_item_changed_by_id(key, item_id);
                } else {
                    tracing::debug!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        item_id,
                        kind = "command_output",
                        "falling back to ThreadUpserted after live delta repair failed"
                    );
                    self.emit_thread_upsert(key);
                }
            }
            UiEvent::DynamicToolCallArgumentsDelta {
                key,
                item_id,
                call_id,
                delta,
            } => {
                // `item_id` may be empty before the provider confirms
                // the item id; key on `call_id` as primary, fall back
                // to `item_id` only when `call_id` is absent. Track the
                // latest non-empty item_id in the buffer so follow-up
                // deltas that do carry one don't lose it.
                let buffer_key = call_id.clone().unwrap_or_else(|| item_id.clone());
                // Hard cap on per-call buffer growth. Widget HTML well past
                // this size is either a runaway stream or pathological; the
                // saved-apps state cap is 256 KB so we match it. Once hit,
                // further deltas are silently dropped for this call; the
                // final ItemCompleted still delivers the full payload.
                const MAX_BUFFER_BYTES: usize = 256 * 1024;
                let (partial, known_item_id) = {
                    let mut guard = self
                        .dynamic_tool_arg_buffers
                        .write()
                        .expect("app store dynamic_tool_arg_buffers poisoned");
                    let entry = guard
                        .entry((key.clone(), buffer_key.clone()))
                        .or_insert_with(|| DynamicToolCallArgBuffer {
                            item_id: item_id.clone(),
                            buffer: String::new(),
                        });
                    if !item_id.is_empty() && entry.item_id.is_empty() {
                        entry.item_id = item_id.clone();
                    }
                    if entry.buffer.len() < MAX_BUFFER_BYTES {
                        let remaining = MAX_BUFFER_BYTES - entry.buffer.len();
                        if delta.len() <= remaining {
                            entry.buffer.push_str(delta);
                        } else {
                            // UTF-8-safe prefix; splitting mid
                            // code-point would poison the buffer.
                            let mut cut = remaining;
                            while cut > 0 && !delta.is_char_boundary(cut) {
                                cut -= 1;
                            }
                            entry.buffer.push_str(&delta[..cut]);
                        }
                    }
                    (entry.buffer.clone(), entry.item_id.clone())
                };

                // Tolerantly extract widget fields from the accumulated
                // buffer and broadcast via `DynamicWidgetStreaming` so
                // platforms can progressively render the widget bubble.
                // Platforms already consume this variant (shipped with
                // SW-I1/SW-A1). `known_item_id` may still be empty on
                // the very first delta; in that case use the buffer_key
                // so platforms have a stable correlation id.
                let streaming_item_id = if !item_id.is_empty() {
                    item_id.clone()
                } else if !known_item_id.is_empty() {
                    known_item_id
                } else {
                    buffer_key.clone()
                };
                if let Some(widget) =
                    crate::conversation::streaming_widget_data_from_partial_arguments(&partial)
                {
                    self.emit(AppStoreUpdateRecord::DynamicWidgetStreaming {
                        key: key.clone(),
                        item_id: streaming_item_id,
                        call_id: buffer_key,
                        widget,
                    });
                }
            }
            UiEvent::TurnDiffUpdated { key, notification } => {
                let item = make_turn_diff_item(
                    &notification.turn_id,
                    notification.diff.clone(),
                    Some(&notification.turn_id),
                );
                if self
                    .mutate_thread_with_result(key, |thread| upsert_item(thread, item.clone()))
                    .is_some()
                {
                    self.emit_thread_item_changed(key, item);
                }
            }
            UiEvent::McpToolCallProgress { key, notification } => {
                let result = self
                    .mutate_thread_with_result(key, |thread| {
                        append_mcp_progress(thread, &notification.item_id, &notification.message)
                    })
                    .unwrap_or(LiveDeltaApplyResult::Failed);
                if result.streamed() {
                    self.emit_thread_streaming_delta(
                        key,
                        &notification.item_id,
                        ThreadStreamingDeltaKind::McpProgress,
                        &notification.message,
                    );
                } else if result.requires_item_upsert() {
                    self.emit_thread_item_changed_by_id(key, &notification.item_id);
                } else {
                    tracing::debug!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        item_id = notification.item_id,
                        kind = "mcp_progress",
                        "falling back to ThreadUpserted after live delta repair failed"
                    );
                    self.emit_thread_upsert(key);
                }
            }
            UiEvent::ApprovalRequested { approval, .. } => {
                let approvals = {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    if !snapshot
                        .pending_approvals
                        .iter()
                        .any(|existing| existing.id == approval.approval.id)
                    {
                        snapshot.pending_approvals.push(approval.approval.clone());
                        snapshot.pending_approval_seeds.insert(
                            PendingApprovalKey {
                                server_id: approval.approval.server_id.clone(),
                                request_id: approval.approval.id.clone(),
                            },
                            approval.seed.clone(),
                        );
                    }
                    snapshot.pending_approvals.clone()
                };
                self.emit(AppStoreUpdateRecord::PendingApprovalsChanged { approvals });
            }
            UiEvent::ServerRequestResolved { notification, .. } => {
                let request_id_string;
                let request_id = match &notification.request_id {
                    codex_app_server_protocol::RequestId::String(value) => value.as_str(),
                    codex_app_server_protocol::RequestId::Integer(value) => {
                        request_id_string = value.to_string();
                        request_id_string.as_str()
                    }
                };
                self.resolve_approval(request_id);
                self.resolve_pending_user_input(request_id);
            }
            UiEvent::AccountRateLimitsUpdated {
                server_id,
                notification,
            } => {
                let rate_limits = notification.rate_limits.clone().into();
                self.update_server_rate_limits(server_id, Some(rate_limits));
            }
            UiEvent::ConnectionStateChanged { server_id, health } => {
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    if let Some(server) = snapshot.servers.get_mut(server_id) {
                        let next_health = ServerHealthSnapshot::from_wire(health);
                        server.health = match (&server.connection_progress, next_health) {
                            // During SSH session replacement the old session can report a transient
                            // disconnect while the new transport is still bootstrapping. Keep the
                            // server visible as connecting until that progress finishes or an
                            // explicit reconnect failure updates the store directly.
                            (Some(_), ServerHealthSnapshot::Disconnected) => {
                                ServerHealthSnapshot::Connecting
                            }
                            (_, health) => health,
                        };
                    }
                }
                self.emit(AppStoreUpdateRecord::ServerChanged {
                    server_id: server_id.clone(),
                });
            }
            UiEvent::ContextTokensUpdated { key, used, limit } => {
                if self
                    .mutate_thread_with_result(key, |thread| {
                        thread.context_tokens_used = Some(*used);
                        thread.model_context_window = Some(*limit);
                    })
                    .is_some()
                {
                    self.emit_thread_metadata_changed(key);
                }
            }
            UiEvent::RealtimeStarted { key, notification } => {
                self.voice_state.reset_thread(key);
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    snapshot.voice_session.active_thread = Some(key.clone());
                    snapshot.voice_session.session_id = notification.realtime_session_id.clone();
                    snapshot.voice_session.phase = Some(AppVoiceSessionPhase::Listening);
                    snapshot.voice_session.last_error = None;
                    snapshot.voice_session.transcript_entries.clear();
                    snapshot.voice_session.handoff_thread_key = None;
                    if let Some(thread) = snapshot.threads.get_mut(key) {
                        thread.realtime_session_id = notification.realtime_session_id.clone();
                    }
                }
                self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
                let protocol_notification = crate::types::AppRealtimeStartedNotification {
                    thread_id: notification.thread_id.clone(),
                    session_id: notification.realtime_session_id.clone(),
                    version: match notification.version {
                        codex_protocol::protocol::RealtimeConversationVersion::V1 => {
                            "v1".to_string()
                        }
                        codex_protocol::protocol::RealtimeConversationVersion::V2 => {
                            "v2".to_string()
                        }
                    },
                };
                self.emit(AppStoreUpdateRecord::RealtimeStarted {
                    key: key.clone(),
                    notification: protocol_notification,
                });
                self.emit_thread_metadata_changed(key);
            }
            UiEvent::RealtimeSdp { key, notification } => {
                let protocol_notification =
                    crate::types::AppRealtimeSdpNotification::from(notification.clone());
                self.emit(AppStoreUpdateRecord::RealtimeSdp {
                    key: key.clone(),
                    notification: protocol_notification,
                });
            }
            UiEvent::RealtimeTranscriptUpdated { key, role, text } => {
                for update in self
                    .voice_state
                    .handle_typed_transcript_delta(key, role, text)
                {
                    match update {
                        VoiceDerivedUpdate::Transcript(update) => {
                            self.apply_voice_transcript_update(key, &update);
                            self.emit(AppStoreUpdateRecord::RealtimeTranscriptUpdated {
                                key: key.clone(),
                                update,
                            });
                        }
                        _ => {}
                    }
                }
            }
            UiEvent::RealtimeItemAdded { key, notification } => {
                for update in self.voice_state.handle_item(key, &notification.item) {
                    match update {
                        VoiceDerivedUpdate::Transcript(update) => {
                            self.apply_voice_transcript_update(key, &update);
                            self.emit(AppStoreUpdateRecord::RealtimeTranscriptUpdated {
                                key: key.clone(),
                                update,
                            });
                        }
                        VoiceDerivedUpdate::HandoffRequest(request) => {
                            {
                                let mut snapshot =
                                    self.snapshot.write().expect("app store lock poisoned");
                                snapshot.voice_session.phase = Some(AppVoiceSessionPhase::Handoff);
                            }
                            self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
                            self.emit(AppStoreUpdateRecord::RealtimeHandoffRequested {
                                key: key.clone(),
                                request,
                            });
                        }
                        VoiceDerivedUpdate::SpeechStarted => {
                            {
                                let mut snapshot =
                                    self.snapshot.write().expect("app store lock poisoned");
                                snapshot.voice_session.phase =
                                    Some(AppVoiceSessionPhase::Listening);
                            }
                            self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
                            self.emit(AppStoreUpdateRecord::RealtimeSpeechStarted {
                                key: key.clone(),
                            });
                        }
                    }
                }
            }
            UiEvent::RealtimeOutputAudioDelta { key, notification } => {
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    if snapshot.voice_session.active_thread.as_ref() == Some(key) {
                        snapshot.voice_session.phase = Some(AppVoiceSessionPhase::Speaking);
                    }
                }
                self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
                let protocol_notification = crate::types::AppRealtimeOutputAudioDeltaNotification {
                    thread_id: notification.thread_id.clone(),
                    audio: crate::types::AppRealtimeAudioChunk {
                        item_id: notification.audio.item_id.clone(),
                        data: notification.audio.data.clone(),
                        sample_rate: notification.audio.sample_rate,
                        num_channels: notification.audio.num_channels.into(),
                        samples_per_channel: notification.audio.samples_per_channel,
                    },
                };
                self.emit(AppStoreUpdateRecord::RealtimeOutputAudioDelta {
                    key: key.clone(),
                    notification: protocol_notification,
                });
            }
            UiEvent::RealtimeError { key, notification } => {
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    snapshot.voice_session.phase = Some(AppVoiceSessionPhase::Error);
                    snapshot.voice_session.last_error = Some(notification.message.clone());
                }
                self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
                let protocol_notification = crate::types::AppRealtimeErrorNotification {
                    thread_id: notification.thread_id.clone(),
                    message: notification.message.clone(),
                };
                self.emit(AppStoreUpdateRecord::RealtimeError {
                    key: key.clone(),
                    notification: protocol_notification,
                });
            }
            UiEvent::RealtimeClosed { key, notification } => {
                self.voice_state.clear_thread(key);
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    if let Some(thread) = snapshot.threads.get_mut(key) {
                        thread.realtime_session_id = None;
                    }
                    let reason = notification.reason.as_deref().unwrap_or("").trim();
                    if reason.is_empty() || reason == "requested" {
                        snapshot.voice_session = AppVoiceSessionSnapshot::default();
                    } else {
                        snapshot.voice_session.active_thread = Some(key.clone());
                        snapshot.voice_session.session_id = None;
                        snapshot.voice_session.phase = Some(AppVoiceSessionPhase::Error);
                        snapshot.voice_session.last_error = Some(reason.to_string());
                        snapshot.voice_session.handoff_thread_key = None;
                    }
                }
                self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
                let protocol_notification = crate::types::AppRealtimeClosedNotification {
                    thread_id: notification.thread_id.clone(),
                    reason: notification.reason.clone(),
                };
                self.emit(AppStoreUpdateRecord::RealtimeClosed {
                    key: key.clone(),
                    notification: protocol_notification,
                });
                self.emit_thread_metadata_changed(key);
            }
            UiEvent::Error { key, message, code } => {
                if let Some(key) = key {
                    let item = {
                        let mut item = None;
                        self.mutate_thread_with_result(key, |thread| {
                            let next = make_error_item(
                                format!("error-{}-{}", key.thread_id, thread.items.len()),
                                message.clone(),
                                *code,
                            );
                            thread.items.push(next.clone());
                            item = Some(next);
                        });
                        item
                    };
                    if let Some(item) = item {
                        self.emit_thread_item_changed(key, item);
                    }
                }
            }
            UiEvent::UserInputRequested { request } => {
                let requests = {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    snapshot
                        .pending_user_inputs
                        .retain(|existing| existing.id != request.id);
                    snapshot.pending_user_inputs.push(request.clone());
                    snapshot.pending_user_inputs.clone()
                };
                self.emit(AppStoreUpdateRecord::PendingUserInputsChanged { requests });
                let key = ThreadKey {
                    server_id: request.server_id.clone(),
                    thread_id: request.thread_id.clone(),
                };
                self.emit_thread_metadata_changed(&key);
            }
            UiEvent::RawNotification { .. } => {}
        }
    }

    fn upsert_or_merge_thread<F>(&self, key: ThreadKey, info: ThreadInfo, mutate: F)
    where
        F: FnOnce(&mut ThreadSnapshot),
    {
        let inserted = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let inserted = !snapshot.threads.contains_key(&key);
            let thread = snapshot
                .threads
                .entry(key.clone())
                .or_insert_with(|| ThreadSnapshot::from_info(&key.server_id, info.clone()));
            thread.info.id = info.id;
            if info.title.is_some() {
                thread.info.title = info.title;
            }
            if info.preview.is_some() {
                thread.info.preview = info.preview;
            }
            if info.cwd.is_some() {
                thread.info.cwd = info.cwd;
            }
            if info.path.is_some() {
                thread.info.path = info.path;
            }
            if info.model_provider.is_some() {
                thread.info.model_provider = info.model_provider;
            }
            if info.agent_nickname.is_some() {
                thread.info.agent_nickname = info.agent_nickname;
            }
            if info.agent_role.is_some() {
                thread.info.agent_role = info.agent_role;
            }
            if info.created_at.is_some() {
                thread.info.created_at = info.created_at;
            }
            if info.updated_at.is_some() {
                thread.info.updated_at = info.updated_at;
            }
            // ThreadStatusChanged is metadata-only; it cannot close an in-flight
            // turn. Only TurnCompleted (or a rebuild with the turn list) is
            // allowed to downgrade Active → Idle.
            thread.info.status = if matches!(info.status, ThreadSummaryStatus::Idle)
                && thread.active_turn_id.is_some()
            {
                thread.info.status.clone()
            } else {
                info.status
            };
            mutate(thread);
            inserted
        };
        if inserted {
            self.emit_thread_upsert(&key);
        } else {
            self.emit_thread_metadata_changed(&key);
        }
    }

    pub(crate) fn mutate_thread<F>(&self, key: &ThreadKey, mutate: F)
    where
        F: FnOnce(&mut ThreadSnapshot),
    {
        if self
            .mutate_thread_with_result(key, |thread| {
                mutate(thread);
            })
            .is_some()
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub(crate) fn mutate_thread_with_result<F, R>(&self, key: &ThreadKey, mutate: F) -> Option<R>
    where
        F: FnOnce(&mut ThreadSnapshot) -> R,
    {
        let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
        let thread = snapshot.threads.get_mut(key)?;
        Some(mutate(thread))
    }

    pub(crate) fn emit_thread_metadata_changed(&self, key: &ThreadKey) {
        let update = {
            let snapshot = self.snapshot.read().expect("app store lock poisoned");
            match project_thread_state_update(&snapshot, key) {
                Ok(Some((mut state, mut session_summary, agent_directory_version))) => {
                    if state.active_turn_id.is_some()
                        || state.info.status == ThreadSummaryStatus::Active
                    {
                        state.info.updated_at = None;
                        session_summary.updated_at = None;
                    }
                    let cached = self
                        .last_thread_state_updates
                        .read()
                        .expect("thread state cache lock poisoned")
                        .get(key)
                        .cloned();
                    if cached
                        == Some((
                            state.clone(),
                            session_summary.clone(),
                            agent_directory_version,
                        ))
                    {
                        None
                    } else {
                        self.last_thread_state_updates
                            .write()
                            .expect("thread state cache lock poisoned")
                            .insert(
                                key.clone(),
                                (
                                    state.clone(),
                                    session_summary.clone(),
                                    agent_directory_version,
                                ),
                            );
                        Some(AppStoreUpdateRecord::ThreadMetadataChanged {
                            state,
                            session_summary,
                            agent_directory_version,
                        })
                    }
                }
                Ok(None) => None,
                Err(error) => {
                    tracing::error!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        %error,
                        "failed to project ThreadMetadataChanged"
                    );
                    Some(AppStoreUpdateRecord::FullResync)
                }
            }
        };
        if let Some(update) = update {
            self.emit(update);
        }
    }

    fn clear_thread_update_caches(&self, key: &ThreadKey) {
        self.last_thread_state_updates
            .write()
            .expect("thread state cache lock poisoned")
            .remove(key);
        self.last_thread_item_upserts
            .write()
            .expect("thread item cache lock poisoned")
            .retain(|(thread_key, _), _| thread_key != key);
    }

    pub(crate) fn emit_thread_upsert(&self, key: &ThreadKey) {
        self.clear_thread_update_caches(key);
        let update = {
            let snapshot = self.snapshot.read().expect("app store lock poisoned");
            match project_thread_update(&snapshot, key) {
                Ok(Some((thread, session_summary, agent_directory_version))) => {
                    tracing::warn!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        item_count = thread.hydrated_conversation_items.len(),
                        active_turn = ?thread.active_turn_id,
                        "emit_thread_upsert"
                    );
                    Some(AppStoreUpdateRecord::ThreadUpserted {
                        thread,
                        session_summary,
                        agent_directory_version,
                    })
                }
                Ok(None) => None,
                Err(error) => {
                    tracing::error!(
                        target: "store",
                        server_id = key.server_id,
                        thread_id = key.thread_id,
                        %error,
                        "failed to project ThreadUpserted"
                    );
                    Some(AppStoreUpdateRecord::FullResync)
                }
            }
        };
        if let Some(update) = update {
            self.emit(update);
        }
    }

    pub(crate) fn emit_thread_item_changed(&self, key: &ThreadKey, item: HydratedConversationItem) {
        let item = {
            let snapshot = self.snapshot.read().expect("app store lock poisoned");
            project_hydrated_item(&snapshot, &key.server_id, &item)
        };
        let cache_key = (key.clone(), item.id.clone());
        {
            let mut cache = self
                .last_thread_item_upserts
                .write()
                .expect("thread item cache lock poisoned");
            if cache.get(&cache_key).is_some_and(|cached| cached == &item) {
                return;
            }
            cache.insert(cache_key, item.clone());
        }
        let session_summary = self.compute_session_summary(key);
        self.emit(AppStoreUpdateRecord::ThreadItemChanged {
            key: key.clone(),
            item: HydratedConversationItem::from(item),
            session_summary,
        });
    }

    /// Snapshot a single thread's `AppSessionSummary` for piggybacking on
    /// per-item events. Falls back to a minimal summary if the thread is
    /// gone by the time this runs (shouldn't happen in practice — emit
    /// sites hold the snapshot lock while deciding to emit).
    fn compute_session_summary(&self, key: &ThreadKey) -> AppSessionSummary {
        let snapshot = self.snapshot.read().expect("app store lock poisoned");
        let Some(thread) = snapshot.threads.get(key) else {
            // Placeholder empty summary — the matching thread has been
            // removed between the mutation and this read. Platform side
            // will get a ThreadRemoved event next and discard anyway.
            return empty_session_summary(key.clone());
        };
        app_session_summary(thread, snapshot.servers.get(&key.server_id))
    }

    pub(crate) fn emit_thread_item_changed_by_id(&self, key: &ThreadKey, item_id: &str) {
        let item = {
            let snapshot = self.snapshot.read().expect("app store lock poisoned");
            snapshot
                .threads
                .get(key)
                .and_then(|thread| thread.items.iter().find(|item| item.id == item_id).cloned())
        };
        if let Some(item) = item {
            self.emit_thread_item_changed(key, item);
        }
    }

    pub(crate) fn emit_thread_streaming_delta(
        &self,
        key: &ThreadKey,
        item_id: &str,
        kind: ThreadStreamingDeltaKind,
        text: &str,
    ) {
        self.emit(AppStoreUpdateRecord::ThreadStreamingDelta {
            key: key.clone(),
            item_id: item_id.to_string(),
            kind,
            text: text.to_string(),
        });
    }

    fn apply_item_update(&self, key: &ThreadKey, item: HydratedConversationItem) {
        let is_user_message = matches!(&item.content, HydratedConversationItemContent::User(_));
        let incoming_item_id = item.id.clone();
        let result = self.mutate_thread_with_result(key, |thread| {
            let existing = thread
                .items
                .iter()
                .find(|existing| existing.id == item.id)
                .cloned();
            let active_turn_id = thread.active_turn_id.as_deref();
            let removed_overlay_ids = thread
                .local_overlay_items
                .iter()
                .filter(|existing| is_superseded_overlay_item(existing, &item, active_turn_id))
                .map(|existing| existing.id.clone())
                .collect::<Vec<_>>();
            // Diagnostic for the duplicate-user-message bug (task #11):
            // when an upstream UserMessage arrives, log the surrounding
            // store state so we can see whether the local overlay was
            // present-and-deduped, present-and-NOT-deduped, or absent —
            // and whether `thread.items` already contains a sibling User
            // item with matching content.
            if is_user_message {
                let other_user_items: Vec<_> = thread
                    .items
                    .iter()
                    .filter(|existing| {
                        existing.id != item.id
                            && matches!(&existing.content, HydratedConversationItemContent::User(_))
                    })
                    .map(|existing| existing.id.clone())
                    .collect();
                let overlay_count = thread.local_overlay_items.len();
                let user_overlay_ids: Vec<_> = thread
                    .local_overlay_items
                    .iter()
                    .filter_map(|existing| {
                        if matches!(&existing.content, HydratedConversationItemContent::User(_)) {
                            Some(existing.id.clone())
                        } else {
                            None
                        }
                    })
                    .collect();
                tracing::warn!(
                    target: "store",
                    server_id = key.server_id,
                    thread_id = key.thread_id,
                    item_id = item.id,
                    item_turn_id = item.source_turn_id.as_deref().unwrap_or(""),
                    item_boundary = item.is_from_user_turn_boundary,
                    existing_user_items = ?other_user_items,
                    user_overlays = ?user_overlay_ids,
                    overlay_count = overlay_count,
                    will_remove_overlays = ?removed_overlay_ids,
                    has_existing_with_id = existing.is_some(),
                    "apply_item_update UserMessage diagnostic"
                );
            }
            thread
                .local_overlay_items
                .retain(|existing| !is_superseded_overlay_item(existing, &item, active_turn_id));
            let queued_count_before = thread.queued_follow_ups.len();
            let mutation = classify_item_mutation(existing.as_ref(), &item);
            let clears_queued_follow_up = item.is_from_user_turn_boundary
                && matches!(&item.content, HydratedConversationItemContent::User(_));
            upsert_item(thread, item);
            if clears_queued_follow_up {
                remove_first_queued_follow_up(thread);
            }
            (
                mutation,
                queued_count_before != thread.queued_follow_ups.len(),
                removed_overlay_ids,
            )
        });
        if result.is_none() && is_user_message {
            tracing::warn!(
                target: "store",
                server_id = key.server_id,
                thread_id = key.thread_id,
                item_id = incoming_item_id,
                "apply_item_update UserMessage skipped: thread not in store"
            );
        }

        match result {
            Some((Some(ItemMutationUpdate::Upsert(item)), queued_changed, removed_overlay_ids)) => {
                if !removed_overlay_ids.is_empty() {
                    self.emit_thread_upsert(key);
                } else {
                    if queued_changed {
                        self.emit_thread_metadata_changed(key);
                    }
                    let session_summary = self.compute_session_summary(key);
                    self.emit(AppStoreUpdateRecord::ThreadItemChanged {
                        key: key.clone(),
                        item,
                        session_summary,
                    });
                }
            }
            Some((None, queued_changed, removed_overlay_ids)) => {
                if !removed_overlay_ids.is_empty() {
                    self.emit_thread_upsert(key);
                } else if queued_changed {
                    self.emit_thread_metadata_changed(key);
                }
            }
            None => {}
        }
    }

    fn apply_voice_transcript_update(&self, key: &ThreadKey, update: &AppVoiceTranscriptUpdate) {
        let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
        if snapshot.voice_session.active_thread.as_ref() != Some(key) {
            return;
        }

        let entry = AppVoiceTranscriptEntry {
            item_id: update.item_id.clone(),
            speaker: update.speaker,
            text: update.text.clone(),
        };
        if let Some(existing) = snapshot
            .voice_session
            .transcript_entries
            .iter_mut()
            .find(|existing| existing.item_id == entry.item_id)
        {
            *existing = entry;
        } else {
            snapshot.voice_session.transcript_entries.push(entry);
        }

        snapshot.voice_session.phase = Some(match (update.speaker, update.is_final) {
            (_, false) => match update.speaker {
                crate::types::AppVoiceSpeaker::User => AppVoiceSessionPhase::Listening,
                crate::types::AppVoiceSpeaker::Assistant => AppVoiceSessionPhase::Speaking,
            },
            (crate::types::AppVoiceSpeaker::Assistant, true) => AppVoiceSessionPhase::Thinking,
            (crate::types::AppVoiceSpeaker::User, true) => AppVoiceSessionPhase::Listening,
        });
    }

    fn emit(&self, update: AppStoreUpdateRecord) {
        match &update {
            AppStoreUpdateRecord::FullResync => tracing::debug!(target: "store", "emit FullResync"),
            AppStoreUpdateRecord::ServerChanged { server_id } => {
                tracing::debug!(target: "store", server_id, "emit ServerChanged")
            }
            AppStoreUpdateRecord::ServerRemoved { server_id } => {
                tracing::debug!(target: "store", server_id, "emit ServerRemoved")
            }
            AppStoreUpdateRecord::ThreadUpserted { thread, .. } => {
                tracing::debug!(
                    target: "store",
                    server_id = thread.key.server_id,
                    thread_id = thread.key.thread_id,
                    "emit ThreadUpserted"
                )
            }
            AppStoreUpdateRecord::ThreadMetadataChanged { state, .. } => {
                tracing::debug!(
                    target: "store",
                    server_id = state.key.server_id,
                    thread_id = state.key.thread_id,
                    "emit ThreadMetadataChanged"
                )
            }
            AppStoreUpdateRecord::ThreadItemChanged { key, item, .. } => {
                tracing::debug!(
                    target: "store",
                    server_id = key.server_id,
                    thread_id = key.thread_id,
                    item_id = item.id,
                    "emit ThreadItemChanged"
                )
            }
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key, item_id, kind, ..
            } => {
                tracing::trace!(
                    target: "store",
                    server_id = key.server_id,
                    thread_id = key.thread_id,
                    item_id,
                    kind = ?kind,
                    "emit ThreadStreamingDelta"
                )
            }
            AppStoreUpdateRecord::ThreadRemoved { key, .. } => {
                tracing::debug!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit ThreadRemoved")
            }
            AppStoreUpdateRecord::ActiveThreadChanged { key } => {
                tracing::debug!(target: "store", thread_id = ?key.as_ref().map(|k| &k.thread_id), "emit ActiveThreadChanged")
            }
            AppStoreUpdateRecord::PendingApprovalsChanged { approvals } => {
                tracing::debug!(target: "store", count = approvals.len(), "emit PendingApprovalsChanged")
            }
            AppStoreUpdateRecord::PendingUserInputsChanged { requests } => {
                tracing::debug!(target: "store", count = requests.len(), "emit PendingUserInputsChanged")
            }
            AppStoreUpdateRecord::VoiceSessionChanged => {
                tracing::debug!(target: "store", "emit VoiceSessionChanged")
            }
            AppStoreUpdateRecord::RealtimeTranscriptUpdated { key, .. } => {
                tracing::trace!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit RealtimeTranscriptUpdated")
            }
            AppStoreUpdateRecord::RealtimeHandoffRequested { key, .. } => {
                tracing::debug!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit RealtimeHandoffRequested")
            }
            AppStoreUpdateRecord::RealtimeSpeechStarted { key } => {
                tracing::debug!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit RealtimeSpeechStarted")
            }
            AppStoreUpdateRecord::RealtimeStarted { key, .. } => {
                tracing::debug!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit RealtimeStarted")
            }
            AppStoreUpdateRecord::RealtimeSdp { key, .. } => {
                tracing::debug!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit RealtimeSdp")
            }
            AppStoreUpdateRecord::RealtimeOutputAudioDelta { .. } => {} // too noisy even for trace
            AppStoreUpdateRecord::RealtimeError { key, .. } => {
                tracing::warn!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit RealtimeError")
            }
            AppStoreUpdateRecord::RealtimeClosed { key, .. } => {
                tracing::debug!(target: "store", server_id = key.server_id, thread_id = key.thread_id, "emit RealtimeClosed")
            }
            AppStoreUpdateRecord::SavedAppsChanged => {
                tracing::debug!(target: "store", "emit SavedAppsChanged")
            }
            AppStoreUpdateRecord::DynamicWidgetStreaming {
                key,
                item_id,
                call_id,
                widget,
            } => {
                tracing::trace!(
                    target: "store",
                    server_id = key.server_id,
                    thread_id = key.thread_id,
                    item_id,
                    call_id,
                    html_len = widget.widget_html.len(),
                    "emit DynamicWidgetStreaming"
                )
            }
        }
        let _ = self.updates_tx.send(update);
    }

    /// Broadcast that the `saved_apps.rs` on-disk index mutated.
    /// Called by every saved-apps UniFFI mutation and by the
    /// finalize-time auto-upsert hook in `dynamic_tools.rs`. Platforms
    /// respond by re-reading via `saved_apps_list`.
    pub(crate) fn emit_saved_apps_changed(&self) {
        self.emit(AppStoreUpdateRecord::SavedAppsChanged);
    }

    /// Drop any streaming `DynamicToolCallArgumentsDelta` buffers that
    /// were accumulating for the given `(thread_key, item_id)`. Called
    /// from `ItemCompleted` for `DynamicToolCall` items, when the
    /// call has finalized on the server. Keyed by the buffer map's
    /// inner value (stored item_id), so we drop every buffer whose
    /// item_id matches — regardless of call_id.
    fn clear_dynamic_tool_arg_buffers_for_item(&self, thread_key: &ThreadKey, item_id: &str) {
        let mut guard = self
            .dynamic_tool_arg_buffers
            .write()
            .expect("app store dynamic_tool_arg_buffers poisoned");
        guard.retain(|(existing_key, _), buffer| {
            !(existing_key == thread_key && buffer.item_id == item_id)
        });
    }
}

fn upsert_item(
    thread: &mut ThreadSnapshot,
    item: crate::conversation_uniffi::HydratedConversationItem,
) {
    if let Some(existing) = thread
        .items
        .iter_mut()
        .find(|existing| existing.id == item.id)
    {
        *existing = item;
    } else {
        thread.items.push(item);
    }
}

fn append_assistant_delta(thread: &mut ThreadSnapshot, item_id: &str, delta: &str) -> bool {
    let mut inserted_placeholder = false;
    if !thread.items.iter().any(|item| item.id == item_id) {
        thread.items.push(HydratedConversationItem {
            id: item_id.to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: String::new(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: thread.active_turn_id.clone(),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        });
        inserted_placeholder = true;
    }

    let Some(item) = thread.items.iter_mut().find(|item| item.id == item_id) else {
        return inserted_placeholder;
    };
    if let HydratedConversationItemContent::Assistant(message) = &mut item.content {
        message.text.push_str(delta);
    }
    inserted_placeholder
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LiveDeltaApplyResult {
    Streamed,
    InsertedPlaceholder,
    RepairedPlaceholder,
    Failed,
}

impl LiveDeltaApplyResult {
    fn streamed(self) -> bool {
        matches!(self, Self::Streamed)
    }

    fn requires_item_upsert(self) -> bool {
        matches!(self, Self::InsertedPlaceholder | Self::RepairedPlaceholder)
    }
}

fn append_reasoning_delta(
    thread: &mut ThreadSnapshot,
    item_id: &str,
    delta: &str,
) -> LiveDeltaApplyResult {
    match thread.items.iter().position(|item| item.id == item_id) {
        Some(index) => {
            let item = &mut thread.items[index];
            match &mut item.content {
                HydratedConversationItemContent::Reasoning(reasoning) => {
                    if let Some(last) = reasoning.content.last_mut() {
                        last.push_str(delta);
                    } else {
                        reasoning.content.push(delta.to_string());
                    }
                    LiveDeltaApplyResult::Streamed
                }
                _ => {
                    item.content =
                        HydratedConversationItemContent::Reasoning(HydratedReasoningData {
                            summary: Vec::new(),
                            content: vec![delta.to_string()],
                        });
                    if item.source_turn_id.is_none() {
                        item.source_turn_id = thread.active_turn_id.clone();
                    }
                    LiveDeltaApplyResult::RepairedPlaceholder
                }
            }
        }
        None => {
            thread.items.push(HydratedConversationItem {
                id: item_id.to_string(),
                content: HydratedConversationItemContent::Reasoning(HydratedReasoningData {
                    summary: Vec::new(),
                    content: vec![delta.to_string()],
                }),
                source_turn_id: thread.active_turn_id.clone(),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
            LiveDeltaApplyResult::InsertedPlaceholder
        }
    }
}

fn append_plan_delta(
    thread: &mut ThreadSnapshot,
    item_id: &str,
    delta: &str,
) -> LiveDeltaApplyResult {
    match thread.items.iter().position(|item| item.id == item_id) {
        Some(index) => {
            let item = &mut thread.items[index];
            match &mut item.content {
                HydratedConversationItemContent::ProposedPlan(plan) => {
                    plan.content.push_str(delta);
                    LiveDeltaApplyResult::Streamed
                }
                _ => {
                    item.content =
                        HydratedConversationItemContent::ProposedPlan(HydratedProposedPlanData {
                            content: delta.to_string(),
                        });
                    if item.source_turn_id.is_none() {
                        item.source_turn_id = thread.active_turn_id.clone();
                    }
                    LiveDeltaApplyResult::RepairedPlaceholder
                }
            }
        }
        None => {
            thread.items.push(HydratedConversationItem {
                id: item_id.to_string(),
                content: HydratedConversationItemContent::ProposedPlan(HydratedProposedPlanData {
                    content: delta.to_string(),
                }),
                source_turn_id: thread.active_turn_id.clone(),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
            LiveDeltaApplyResult::InsertedPlaceholder
        }
    }
}

fn append_command_output_delta(
    thread: &mut ThreadSnapshot,
    item_id: &str,
    delta: &str,
) -> LiveDeltaApplyResult {
    match thread.items.iter().position(|item| item.id == item_id) {
        Some(index) => {
            let item = &mut thread.items[index];
            match &mut item.content {
                HydratedConversationItemContent::CommandExecution(command) => {
                    let output = command.output.get_or_insert_with(String::new);
                    if !command_output_is_truncated(output) {
                        output.push_str(delta);
                        if output.len() > 128 * 1024 {
                            *output = truncate_command_output_text(output);
                        }
                    }
                    LiveDeltaApplyResult::Streamed
                }
                _ => {
                    item.content = HydratedConversationItemContent::CommandExecution(
                        HydratedCommandExecutionData {
                            command: String::new(),
                            cwd: String::new(),
                            status: AppOperationStatus::InProgress,
                            output: Some(truncate_command_output_text(delta)),
                            exit_code: None,
                            duration_ms: None,
                            process_id: None,
                            actions: Vec::new(),
                        },
                    );
                    if item.source_turn_id.is_none() {
                        item.source_turn_id = thread.active_turn_id.clone();
                    }
                    LiveDeltaApplyResult::RepairedPlaceholder
                }
            }
        }
        None => {
            thread.items.push(HydratedConversationItem {
                id: item_id.to_string(),
                content: HydratedConversationItemContent::CommandExecution(
                    HydratedCommandExecutionData {
                        command: String::new(),
                        cwd: String::new(),
                        status: AppOperationStatus::InProgress,
                        output: Some(truncate_command_output_text(delta)),
                        exit_code: None,
                        duration_ms: None,
                        process_id: None,
                        actions: Vec::new(),
                    },
                ),
                source_turn_id: thread.active_turn_id.clone(),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
            LiveDeltaApplyResult::InsertedPlaceholder
        }
    }
}

fn append_mcp_progress(
    thread: &mut ThreadSnapshot,
    item_id: &str,
    message: &str,
) -> LiveDeltaApplyResult {
    match thread.items.iter().position(|item| item.id == item_id) {
        Some(index) => {
            let item = &mut thread.items[index];
            match &mut item.content {
                HydratedConversationItemContent::McpToolCall(call) => {
                    if !message.trim().is_empty() {
                        call.progress_messages.push(message.to_string());
                    }
                    LiveDeltaApplyResult::Streamed
                }
                _ => {
                    item.content =
                        HydratedConversationItemContent::McpToolCall(HydratedMcpToolCallData {
                            server: String::new(),
                            tool: String::new(),
                            status: AppOperationStatus::InProgress,
                            duration_ms: None,
                            arguments_json: None,
                            content_summary: None,
                            structured_content_json: None,
                            raw_output_json: None,
                            error_message: None,
                            progress_messages: if message.trim().is_empty() {
                                Vec::new()
                            } else {
                                vec![message.to_string()]
                            },
                            computer_use: None,
                        });
                    if item.source_turn_id.is_none() {
                        item.source_turn_id = thread.active_turn_id.clone();
                    }
                    LiveDeltaApplyResult::RepairedPlaceholder
                }
            }
        }
        None => {
            thread.items.push(HydratedConversationItem {
                id: item_id.to_string(),
                content: HydratedConversationItemContent::McpToolCall(HydratedMcpToolCallData {
                    server: String::new(),
                    tool: String::new(),
                    status: AppOperationStatus::InProgress,
                    duration_ms: None,
                    arguments_json: None,
                    content_summary: None,
                    structured_content_json: None,
                    raw_output_json: None,
                    error_message: None,
                    progress_messages: if message.trim().is_empty() {
                        Vec::new()
                    } else {
                        vec![message.to_string()]
                    },
                    computer_use: None,
                }),
                source_turn_id: thread.active_turn_id.clone(),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
            LiveDeltaApplyResult::InsertedPlaceholder
        }
    }
}

const USER_INPUT_RESPONSE_ITEM_PREFIX: &str = "user-input-response:";

fn local_user_message_overlay_item(
    inputs: &[upstream::UserInput],
) -> Option<HydratedConversationItem> {
    let (text, image_data_uris) = render_user_input(inputs);
    if text.is_empty() && image_data_uris.is_empty() {
        return None;
    }

    Some(HydratedConversationItem {
        id: format!(
            "{LOCAL_USER_MESSAGE_ITEM_PREFIX}{}",
            crate::next_request_id()
        ),
        content: HydratedConversationItemContent::User(
            crate::conversation_uniffi::HydratedUserMessageData {
                text,
                image_data_uris,
            },
        ),
        source_turn_id: None,
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: true,
    })
}

fn render_user_input(inputs: &[upstream::UserInput]) -> (String, Vec<String>) {
    let mut text_parts = Vec::new();
    let mut images = Vec::new();
    for input in inputs {
        match input {
            upstream::UserInput::Text { text, .. } => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    text_parts.push(trimmed.to_string());
                }
            }
            upstream::UserInput::Image { url } => images.push(url.clone()),
            upstream::UserInput::LocalImage { path } => {
                images.push(format!("file://{}", path.display()));
            }
            upstream::UserInput::Skill { name, path } => {
                if !name.is_empty() && path != &PathBuf::new() {
                    text_parts.push(format!("[Skill] {} ({})", name, path.display()));
                } else if !name.is_empty() {
                    text_parts.push(format!("[Skill] {name}"));
                } else if path != &PathBuf::new() {
                    text_parts.push(format!("[Skill] {}", path.display()));
                }
            }
            upstream::UserInput::Mention { name, path } => {
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

fn preserve_local_overlay_items(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    let active_turn_id = target.active_turn_id.as_deref();
    for item in &source.local_overlay_items {
        let item = bind_pending_local_user_overlay_to_target_turn(item, target);
        if target
            .items
            .iter()
            .all(|existing| !is_superseded_overlay_item(&item, existing, active_turn_id))
            && target
                .local_overlay_items
                .iter()
                .all(|existing| !is_superseded_overlay_item(&item, existing, active_turn_id))
        {
            target.local_overlay_items.push(item);
        }
    }
}

fn duplicate_local_overlay_item_ids(thread: &ThreadSnapshot) -> Vec<String> {
    let active_turn_id = thread.active_turn_id.as_deref();
    thread
        .local_overlay_items
        .iter()
        .filter(|item| {
            thread
                .items
                .iter()
                .any(|existing| is_superseded_overlay_item(item, existing, active_turn_id))
        })
        .map(|item| item.id.clone())
        .collect()
}

pub(crate) fn remove_duplicate_local_overlay_items(thread: &mut ThreadSnapshot) {
    let active_turn_id = thread.active_turn_id.as_deref();
    thread.local_overlay_items.retain(|item| {
        thread
            .items
            .iter()
            .all(|existing| !is_superseded_overlay_item(item, existing, active_turn_id))
    });
}

pub(crate) fn reconcile_local_overlay_items(thread: &mut ThreadSnapshot) {
    if let Some(turn_id) = thread.active_turn_id.clone() {
        for item in &mut thread.local_overlay_items {
            if item.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX) && item.source_turn_id.is_none()
            {
                item.source_turn_id = Some(turn_id.clone());
            }
        }
    }
    remove_duplicate_local_overlay_items(thread);
}

fn bind_pending_local_user_overlay_to_target_turn(
    item: &HydratedConversationItem,
    target: &ThreadSnapshot,
) -> HydratedConversationItem {
    if item.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX)
        && item.source_turn_id.is_none()
        && let Some(turn_id) = target.active_turn_id.as_ref()
    {
        let mut bound = item.clone();
        bound.source_turn_id = Some(turn_id.clone());
        return bound;
    }
    item.clone()
}

fn preserve_thread_runtime_state(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    target.collaboration_mode = source.collaboration_mode;
    if target.model.is_none() {
        target.model = source.model.clone();
    }
    if target.reasoning_effort.is_none() {
        target.reasoning_effort = source.reasoning_effort.clone();
    }
    if target.active_plan_progress.is_none() {
        target.active_plan_progress = source.active_plan_progress.clone();
    }
    if target.pending_plan_implementation_turn_id.is_none() {
        target.pending_plan_implementation_turn_id =
            source.pending_plan_implementation_turn_id.clone();
    }
}

fn preserve_thread_title(existing: &ThreadInfo, incoming: &mut ThreadInfo) {
    let incoming_blank = incoming
        .title
        .as_deref()
        .map(str::trim)
        .is_none_or(str::is_empty);
    if !incoming_blank {
        return;
    }

    let existing_title = existing
        .title
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if existing_title.is_some() {
        incoming.title = existing_title;
    }
}

fn preserve_thread_preview(existing: &ThreadInfo, incoming: &mut ThreadInfo) {
    if incoming.preview.is_some() {
        return;
    }
    if existing.preview.is_some() {
        incoming.preview = existing.preview.clone();
    }
}

fn preserve_thread_created_at(existing: &ThreadInfo, incoming: &mut ThreadInfo) {
    if let Some(existing_created) = existing.created_at {
        match incoming.created_at {
            None => incoming.created_at = Some(existing_created),
            Some(incoming_created) if existing_created < incoming_created => {
                incoming.created_at = Some(existing_created);
            }
            _ => {}
        }
    }
}

fn preserve_queued_follow_ups(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    if target.queued_follow_ups.is_empty() {
        target.queued_follow_ups = source.queued_follow_ups.clone();
    }
    if target.queued_follow_up_drafts.is_empty() {
        target.queued_follow_up_drafts = source.queued_follow_up_drafts.clone();
    }
}

fn sync_thread_follow_up_projection(thread: &mut ThreadSnapshot) {
    thread.queued_follow_ups = thread
        .queued_follow_up_drafts
        .iter()
        .map(|draft| draft.preview.clone())
        .collect();
}

pub(crate) fn remove_first_queued_follow_up(thread: &mut ThreadSnapshot) {
    if !thread.queued_follow_up_drafts.is_empty() {
        thread.queued_follow_up_drafts.remove(0);
        sync_thread_follow_up_projection(thread);
        return;
    }
    if !thread.queued_follow_ups.is_empty() {
        thread.queued_follow_ups.remove(0);
    }
}

fn is_duplicate_overlay_item(
    local: &HydratedConversationItem,
    existing: &HydratedConversationItem,
) -> bool {
    if local.id == existing.id && local.id.starts_with(USER_INPUT_RESPONSE_ITEM_PREFIX) {
        return true;
    }

    match (&local.content, &existing.content) {
        (
            HydratedConversationItemContent::UserInputResponse(local_data),
            HydratedConversationItemContent::UserInputResponse(existing_data),
        ) => local.source_turn_id == existing.source_turn_id && local_data == existing_data,
        (
            HydratedConversationItemContent::User(local_data),
            HydratedConversationItemContent::User(existing_data),
        ) => {
            local.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX)
                && local.source_turn_id.is_some()
                && local.source_turn_id == existing.source_turn_id
                && local_data == existing_data
        }
        _ => false,
    }
}

fn is_superseded_overlay_item(
    local: &HydratedConversationItem,
    existing: &HydratedConversationItem,
    _active_turn_id: Option<&str>,
) -> bool {
    if is_duplicate_overlay_item(local, existing) {
        return true;
    }

    match (&local.content, &existing.content) {
        (
            HydratedConversationItemContent::User(local_data),
            HydratedConversationItemContent::User(existing_data),
        ) => {
            local.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX)
                && local.is_from_user_turn_boundary
                && existing.is_from_user_turn_boundary
                && local_data == existing_data
        }
        _ => false,
    }
}

fn answered_user_input_item(
    request: &PendingUserInputRequest,
    answers: &[PendingUserInputAnswer],
) -> HydratedConversationItem {
    let content =
        HydratedConversationItemContent::UserInputResponse(HydratedUserInputResponseData {
            questions: request
                .questions
                .iter()
                .map(|question| {
                    let answer = answers
                        .iter()
                        .find(|answer| answer.question_id == question.id)
                        .map(|answer| {
                            let hide_other_placeholder = answer
                                .answers
                                .iter()
                                .any(|entry| is_user_input_note_answer(entry));
                            answer
                                .answers
                                .iter()
                                .filter_map(|entry| {
                                    display_user_input_answer(entry, hide_other_placeholder)
                                })
                                .collect::<Vec<_>>()
                                .join("\n")
                        })
                        .unwrap_or_default();
                    HydratedUserInputResponseQuestionData {
                        id: question.id.clone(),
                        header: question.header.clone(),
                        question: question.question.clone(),
                        answer,
                        options: question
                            .options
                            .iter()
                            .map(|option| HydratedUserInputResponseOptionData {
                                label: option.label.clone(),
                                description: option.description.clone(),
                            })
                            .collect(),
                    }
                })
                .collect(),
        });

    HydratedConversationItem {
        id: format!("{USER_INPUT_RESPONSE_ITEM_PREFIX}{}", request.id),
        content,
        source_turn_id: Some(request.turn_id.clone()),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

fn is_user_input_note_answer(answer: &str) -> bool {
    answer.trim().starts_with(USER_INPUT_NOTE_PREFIX)
}

fn display_user_input_answer(answer: &str, hide_other_placeholder: bool) -> Option<String> {
    let trimmed = answer.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(note) = trimmed.strip_prefix(USER_INPUT_NOTE_PREFIX) {
        let note = note.trim();
        return (!note.is_empty()).then(|| note.to_string());
    }
    if hide_other_placeholder && trimmed == USER_INPUT_OTHER_OPTION_LABEL {
        return None;
    }
    Some(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversation_uniffi::{HydratedDividerData, HydratedUserMessageData};
    use crate::types::{ApprovalKind, PendingUserInputOption, PendingUserInputQuestion};
    use codex_app_server_protocol::{
        McpToolCallProgressNotification, ModelRerouteReason, ModelReroutedNotification,
        TurnDiffUpdatedNotification, TurnPlanStep, TurnPlanStepStatus, TurnPlanUpdatedNotification,
    };
    use tokio::sync::broadcast::error::TryRecvError;

    fn make_thread_info(id: &str) -> ThreadInfo {
        ThreadInfo {
            id: id.to_string(),
            title: Some(format!("Thread {id}")),
            model: None,
            status: ThreadSummaryStatus::Idle,
            preview: None,
            cwd: Some("/tmp".to_string()),
            path: None,
            model_provider: None,
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            created_at: None,
            updated_at: None,
        }
    }

    fn drain_updates(
        receiver: &mut tokio::sync::broadcast::Receiver<AppStoreUpdateRecord>,
    ) -> Vec<AppStoreUpdateRecord> {
        let mut updates = Vec::new();
        loop {
            match receiver.try_recv() {
                Ok(update) => updates.push(update),
                Err(TryRecvError::Empty) => break,
                Err(error) => panic!("unexpected broadcast receive error: {error:?}"),
            }
        }
        updates
    }

    fn make_server_config(server_id: &str) -> ServerConfig {
        ServerConfig {
            server_id: server_id.to_string(),
            display_name: format!("Server {server_id}"),
            host: "example.local".to_string(),
            port: 22,
            websocket_url: None,
            is_local: false,
            tls: false,
        }
    }

    #[test]
    fn sync_thread_list_for_runtime_tags_threads() {
        let reducer = AppStoreReducer::new();
        let config = make_server_config("srv");
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected, false);

        reducer.sync_thread_list_for_runtime(
            "srv",
            AgentRuntimeKind::Pi,
            &[make_thread_info("thread-1")],
        );

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        assert_eq!(
            reducer.thread_snapshot(&key).unwrap().agent_runtime_kind,
            AgentRuntimeKind::Pi
        );
    }

    #[test]
    fn update_server_agent_runtimes_replaces_available_metadata() {
        let reducer = AppStoreReducer::new();
        let config = make_server_config("srv");
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected, false);

        reducer.update_server_agent_runtimes(
            "srv",
            vec![AgentRuntimeInfo {
                kind: AgentRuntimeKind::Opencode,
                name: "opencode".to_string(),
                display_name: "opencode".to_string(),
                available: true,
            }],
        );

        let snapshot = reducer.snapshot();
        let server = snapshot.servers.get("srv").unwrap();
        assert_eq!(server.agent_runtimes.len(), 1);
        assert_eq!(server.agent_runtimes[0].kind, AgentRuntimeKind::Opencode);
    }

    #[test]
    fn sync_thread_list_preserves_active_missing_thread() {
        let reducer = AppStoreReducer::new();
        let active_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "active".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("active")));
        reducer.set_active_thread(Some(active_key.clone()));
        let mut receiver = reducer.subscribe();

        reducer.sync_thread_list("srv", &[make_thread_info("other")]);

        let snapshot = reducer.snapshot();
        assert!(snapshot.threads.contains_key(&active_key));
        assert_eq!(snapshot.active_thread, Some(active_key));
        let updates = drain_updates(&mut receiver);
        assert!(
            updates
                .iter()
                .all(|update| !matches!(update, AppStoreUpdateRecord::FullResync))
        );
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. } if thread.key.thread_id == "other"
        )));
    }

    #[test]
    fn update_server_wake_mac_persists_across_upsert() {
        let reducer = AppStoreReducer::new();
        let config = make_server_config("srv");

        reducer.upsert_server(&config, ServerHealthSnapshot::Connecting, true);
        reducer.update_server_wake_mac("srv", Some("aa:bb:cc:dd:ee:ff".to_string()));
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected, true);

        let snapshot = reducer.snapshot();
        let server = snapshot.servers.get("srv").expect("server snapshot");
        assert_eq!(server.wake_mac.as_deref(), Some("aa:bb:cc:dd:ee:ff"));
    }

    #[test]
    fn sync_thread_list_emits_incremental_updates_without_full_resync() {
        let reducer = AppStoreReducer::new();
        let existing_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "existing".to_string(),
        };
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("existing"),
        ));
        let mut receiver = reducer.subscribe();

        let mut updated_existing = make_thread_info("existing");
        updated_existing.title = Some("Updated existing".to_string());
        updated_existing.model = Some("gpt-5.4".to_string());
        updated_existing.status = ThreadSummaryStatus::Active;

        let mut inserted = make_thread_info("inserted");
        inserted.model = Some("gpt-5.4".to_string());

        reducer.sync_thread_list("srv", &[updated_existing.clone(), inserted.clone()]);

        let updates = drain_updates(&mut receiver);
        assert!(
            updates
                .iter()
                .all(|update| !matches!(update, AppStoreUpdateRecord::FullResync))
        );
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadMetadataChanged { state, .. }
                if state.key == existing_key
                    && state.info == updated_existing
                    && state.model.as_deref() == Some("gpt-5.4")
        )));
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                if thread.key.thread_id == "inserted"
                    && thread.info == inserted
                    && thread.model.as_deref() == Some("gpt-5.4")
        )));
    }

    #[test]
    fn paginated_thread_list_upserts_pages_before_final_prune() {
        let reducer = AppStoreReducer::new();
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("stale")));
        let mut receiver = reducer.subscribe();

        let page_one = make_thread_info("page-one");
        let page_two = make_thread_info("page-two");
        reducer.upsert_thread_list_page("srv", &[page_one.clone()]);
        reducer.upsert_thread_list_page("srv", &[page_two.clone()]);
        reducer.finalize_thread_list_sync(
            "srv",
            &HashSet::from([page_one.id.clone(), page_two.id.clone()]),
        );

        let snapshot = reducer.snapshot();
        assert!(snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "page-one".to_string(),
        }));
        assert!(snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "page-two".to_string(),
        }));
        assert!(!snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "stale".to_string(),
        }));

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                if thread.key.thread_id == "page-one"
        )));
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                if thread.key.thread_id == "page-two"
        )));
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadRemoved { key, .. }
                if key.thread_id == "stale"
        )));
    }

    #[test]
    fn sync_thread_list_preserves_existing_title_when_incoming_title_missing() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));

        let mut incoming = make_thread_info("thread");
        incoming.title = None;
        incoming.preview = Some("First user message".to_string());

        reducer.sync_thread_list("srv", &[incoming]);

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert_eq!(thread.info.title.as_deref(), Some("Thread thread"));
        assert_eq!(thread.info.preview.as_deref(), Some("First user message"));
    }

    #[test]
    fn turn_diff_updates_become_conversation_items() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));

        reducer.apply_ui_event(&UiEvent::TurnDiffUpdated {
            key: key.clone(),
            notification: TurnDiffUpdatedNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn-1".to_string(),
                diff: "@@ -1 +1 @@\n-old\n+new".to_string(),
            },
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let diff_item = thread
            .items
            .iter()
            .find(|item| item.id == "turn-diff-turn-1")
            .expect("turn diff item exists");
        match &diff_item.content {
            HydratedConversationItemContent::TurnDiff(data) => assert!(data.diff.contains("+new")),
            other => panic!("expected turn diff item, got {other:?}"),
        }
    }

    #[test]
    fn turn_plan_updates_populate_active_plan_progress_without_timeline_items() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));

        reducer.apply_ui_event(&UiEvent::TurnPlanUpdated {
            key: key.clone(),
            notification: TurnPlanUpdatedNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn-1".to_string(),
                explanation: Some("working".to_string()),
                plan: vec![
                    TurnPlanStep {
                        step: "Inspect renderer".to_string(),
                        status: TurnPlanStepStatus::Completed,
                    },
                    TurnPlanStep {
                        step: "Restore task cards".to_string(),
                        status: TurnPlanStepStatus::InProgress,
                    },
                ],
            },
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert!(
            thread
                .items
                .iter()
                .all(|item| item.id != "turn-plan-turn-1"),
            "turn/plan/updated should not create historical timeline items"
        );
        let progress = thread
            .active_plan_progress
            .as_ref()
            .expect("active plan progress should exist");
        assert_eq!(progress.turn_id, "turn-1");
        assert_eq!(progress.explanation.as_deref(), Some("working"));
        assert_eq!(progress.plan.len(), 2);
        assert_eq!(
            progress.plan[0].status,
            crate::types::AppPlanStepStatus::Completed
        );
        assert_eq!(
            progress.plan[1].status,
            crate::types::AppPlanStepStatus::InProgress
        );
        assert_eq!(progress.plan[1].step, "Restore task cards");
    }

    #[test]
    fn mcp_progress_updates_append_to_existing_item() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let mut thread = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "mcp-1".to_string(),
                content: HydratedConversationItemContent::McpToolCall(
                    crate::conversation_uniffi::HydratedMcpToolCallData {
                        server: "github".to_string(),
                        tool: "search".to_string(),
                        status: crate::types::AppOperationStatus::InProgress,
                        duration_ms: None,
                        arguments_json: None,
                        content_summary: None,
                        structured_content_json: None,
                        raw_output_json: None,
                        error_message: None,
                        progress_messages: Vec::new(),
                        computer_use: None,
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
        reducer.upsert_thread_snapshot(thread);

        reducer.apply_ui_event(&UiEvent::McpToolCallProgress {
            key: key.clone(),
            notification: McpToolCallProgressNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn-1".to_string(),
                item_id: "mcp-1".to_string(),
                message: "Fetched 3 results".to_string(),
            },
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let mcp_item = thread.items.iter().find(|item| item.id == "mcp-1").unwrap();
        match &mcp_item.content {
            HydratedConversationItemContent::McpToolCall(data) => {
                assert_eq!(
                    data.progress_messages,
                    vec!["Fetched 3 results".to_string()]
                );
            }
            other => panic!("expected mcp tool item, got {other:?}"),
        }
    }

    #[test]
    fn reasoning_delta_missing_item_creates_placeholder_without_thread_upsert() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let mut thread = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        thread.active_turn_id = Some("turn-1".to_string());
        reducer.upsert_thread_snapshot(thread);
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.apply_ui_event(&UiEvent::ReasoningDelta {
            key: key.clone(),
            item_id: "reasoning-1".to_string(),
            delta: "thinking".to_string(),
        });

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadItemChanged { key: update_key, item, .. }
                if update_key == &key && item.id == "reasoning-1"
        )));
        assert!(
            updates
                .iter()
                .all(|update| !matches!(update, AppStoreUpdateRecord::ThreadUpserted { .. }))
        );

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread
            .items
            .iter()
            .find(|item| item.id == "reasoning-1")
            .unwrap();
        match &item.content {
            HydratedConversationItemContent::Reasoning(data) => {
                assert_eq!(data.content, vec!["thinking".to_string()]);
            }
            other => panic!("expected reasoning item, got {other:?}"),
        }
    }

    #[test]
    fn thread_item_changed_projects_multi_agent_targets_to_display_labels() {
        let reducer = AppStoreReducer::new();
        let parent_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "parent".to_string(),
        };

        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("parent")));

        let mut child_info = make_thread_info("child-thread");
        child_info.agent_nickname = Some("Scout".to_string());
        child_info.agent_role = Some("explorer".to_string());
        child_info.parent_thread_id = Some("parent".to_string());
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info("srv", child_info));

        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.apply_item_update(
            &parent_key,
            HydratedConversationItem {
                id: "collab-1".to_string(),
                content: HydratedConversationItemContent::MultiAgentAction(
                    crate::conversation_uniffi::HydratedMultiAgentActionData {
                        tool: "spawnAgent".to_string(),
                        status: AppOperationStatus::Completed,
                        prompt: Some("Inspect".to_string()),
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
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            },
        );

        let updates = drain_updates(&mut receiver);
        let update_item = updates
            .into_iter()
            .find_map(|update| match update {
                AppStoreUpdateRecord::ThreadItemChanged { key, item, .. } if key == parent_key => {
                    Some(item)
                }
                _ => None,
            })
            .expect("expected ThreadItemChanged update");

        let HydratedConversationItemContent::MultiAgentAction(data) = update_item.content else {
            panic!("expected multi-agent action update");
        };
        assert_eq!(data.targets, vec!["Scout [explorer]".to_string()]);
        assert_eq!(data.receiver_thread_ids, vec!["child-thread".to_string()]);
    }

    #[test]
    fn command_output_delta_repairs_wrong_type_without_thread_upsert() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let mut thread = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        thread.active_turn_id = Some("turn-1".to_string());
        thread.items.push(HydratedConversationItem {
            id: "call-1".to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: "wrong".to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        });
        reducer.upsert_thread_snapshot(thread);
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.apply_ui_event(&UiEvent::CommandOutputDelta {
            key: key.clone(),
            item_id: "call-1".to_string(),
            delta: "stdout".to_string(),
        });

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadItemChanged { key: update_key, item, .. }
                if update_key == &key && item.id == "call-1"
        )));
        assert!(
            updates
                .iter()
                .all(|update| !matches!(update, AppStoreUpdateRecord::ThreadUpserted { .. }))
        );

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread
            .items
            .iter()
            .find(|item| item.id == "call-1")
            .unwrap();
        match &item.content {
            HydratedConversationItemContent::CommandExecution(data) => {
                assert_eq!(data.output.as_deref(), Some("stdout"));
                assert_eq!(data.status, AppOperationStatus::InProgress);
            }
            other => panic!("expected command execution item, got {other:?}"),
        }
    }

    #[test]
    fn mcp_progress_missing_item_creates_placeholder_without_thread_upsert() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let mut thread = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        thread.active_turn_id = Some("turn-1".to_string());
        reducer.upsert_thread_snapshot(thread);
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.apply_ui_event(&UiEvent::McpToolCallProgress {
            key: key.clone(),
            notification: McpToolCallProgressNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn-1".to_string(),
                item_id: "mcp-1".to_string(),
                message: "Fetched 3 results".to_string(),
            },
        });

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadItemChanged { key: update_key, item, .. }
                if update_key == &key && item.id == "mcp-1"
        )));
        assert!(
            updates
                .iter()
                .all(|update| !matches!(update, AppStoreUpdateRecord::ThreadUpserted { .. }))
        );

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread.items.iter().find(|item| item.id == "mcp-1").unwrap();
        match &item.content {
            HydratedConversationItemContent::McpToolCall(data) => {
                assert_eq!(
                    data.progress_messages,
                    vec!["Fetched 3 results".to_string()]
                );
                assert_eq!(data.status, AppOperationStatus::InProgress);
            }
            other => panic!("expected mcp tool item, got {other:?}"),
        }
    }

    #[test]
    fn model_reroutes_become_divider_items() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));

        reducer.apply_ui_event(&UiEvent::ModelRerouted {
            key: key.clone(),
            notification: ModelReroutedNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn-1".to_string(),
                from_model: "gpt-5".to_string(),
                to_model: "gpt-5-mini".to_string(),
                reason: ModelRerouteReason::HighRiskCyberActivity,
            },
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let reroute_item = thread
            .items
            .iter()
            .find(|item| item.id == "model-rerouted-turn-1")
            .expect("model reroute item exists");
        match &reroute_item.content {
            HydratedConversationItemContent::Divider(HydratedDividerData::ModelRerouted {
                from_model,
                to_model,
                reason,
            }) => {
                assert_eq!(from_model.as_deref(), Some("gpt-5"));
                assert_eq!(to_model, "gpt-5-mini");
                assert_eq!(reason.as_deref(), Some("High Risk Cyber Activity"));
            }
            other => panic!("expected model reroute divider, got {other:?}"),
        }
    }

    #[test]
    fn resolved_user_input_appends_response_item() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        reducer.replace_pending_user_inputs(vec![PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: key.server_id.clone(),
            thread_id: key.thread_id.clone(),
            turn_id: "turn-1".to_string(),
            item_id: "tool-1".to_string(),
            questions: vec![PendingUserInputQuestion {
                id: "q-1".to_string(),
                header: Some("Choice".to_string()),
                question: "Pick one".to_string(),
                is_other_allowed: false,
                is_secret: false,
                options: vec![PendingUserInputOption {
                    label: "A".to_string(),
                    description: Some("First".to_string()),
                }],
            }],
            requester_agent_nickname: None,
            requester_agent_role: None,
        }]);

        reducer.resolve_pending_user_input_with_response(
            "req-1",
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["A".to_string()],
            }],
        );

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread
            .local_overlay_items
            .iter()
            .find(|item| item.id == "user-input-response:req-1")
            .expect("response item exists");
        match &item.content {
            HydratedConversationItemContent::UserInputResponse(data) => {
                assert_eq!(data.questions.len(), 1);
                assert_eq!(data.questions[0].answer, "A");
            }
            other => panic!("expected user input response item, got {other:?}"),
        }
    }

    #[test]
    fn replacing_identical_pending_user_inputs_is_silent() {
        let reducer = AppStoreReducer::new();
        let request = PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
            turn_id: "turn-1".to_string(),
            item_id: "tool-1".to_string(),
            questions: vec![PendingUserInputQuestion {
                id: "q-1".to_string(),
                header: Some("Choice".to_string()),
                question: "Pick one".to_string(),
                is_other_allowed: false,
                is_secret: false,
                options: vec![PendingUserInputOption {
                    label: "A".to_string(),
                    description: Some("First".to_string()),
                }],
            }],
            requester_agent_nickname: None,
            requester_agent_role: None,
        };

        reducer.replace_pending_user_inputs(vec![request.clone()]);
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.replace_pending_user_inputs(vec![request]);

        assert!(drain_updates(&mut receiver).is_empty());
    }

    #[test]
    fn replacing_identical_pending_approvals_with_seeds_is_silent() {
        let reducer = AppStoreReducer::new();
        let approval = PendingApproval {
            id: "approval-1".to_string(),
            server_id: "srv".to_string(),
            kind: ApprovalKind::Command,
            thread_id: Some("thread".to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: Some("ls".to_string()),
            path: None,
            grant_root: None,
            cwd: Some("/tmp".to_string()),
            reason: Some("Need approval".to_string()),
        };
        let seeded = PendingApprovalWithSeed {
            approval,
            seed: PendingApprovalSeed {
                request_id: upstream::RequestId::String("approval-1".to_string()),
                raw_params: serde_json::json!({"command": "ls"}),
            },
        };

        reducer.replace_pending_approvals_with_seeds(vec![seeded.clone()]);
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.replace_pending_approvals_with_seeds(vec![seeded]);

        assert!(drain_updates(&mut receiver).is_empty());
    }

    #[test]
    fn resolved_user_input_hides_other_placeholder_when_note_present() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        reducer.replace_pending_user_inputs(vec![PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: key.server_id.clone(),
            thread_id: key.thread_id.clone(),
            turn_id: "turn-1".to_string(),
            item_id: "tool-1".to_string(),
            questions: vec![PendingUserInputQuestion {
                id: "q-1".to_string(),
                header: Some("Choice".to_string()),
                question: "Pick one".to_string(),
                is_other_allowed: true,
                is_secret: false,
                options: vec![PendingUserInputOption {
                    label: "A".to_string(),
                    description: Some("First".to_string()),
                }],
            }],
            requester_agent_nickname: None,
            requester_agent_role: None,
        }]);

        reducer.resolve_pending_user_input_with_response(
            "req-1",
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec![
                    "None of the above".to_string(),
                    "user_note: Custom answer".to_string(),
                ],
            }],
        );

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread
            .local_overlay_items
            .iter()
            .find(|item| item.id == "user-input-response:req-1")
            .expect("response item exists");
        match &item.content {
            HydratedConversationItemContent::UserInputResponse(data) => {
                assert_eq!(data.questions.len(), 1);
                assert_eq!(data.questions[0].answer, "Custom answer");
            }
            other => panic!("expected user input response item, got {other:?}"),
        }
    }

    #[test]
    fn server_backed_user_input_response_supersedes_local_synthetic_copy() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let mut local = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        local.items.push(HydratedConversationItem {
            id: "user-input-response:req-1".to_string(),
            content: HydratedConversationItemContent::UserInputResponse(
                HydratedUserInputResponseData {
                    questions: vec![HydratedUserInputResponseQuestionData {
                        id: "q-1".to_string(),
                        header: Some("Choice".to_string()),
                        question: "Pick one".to_string(),
                        answer: "A".to_string(),
                        options: vec![],
                    }],
                },
            ),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        });
        reducer.upsert_thread_snapshot(local);

        let mut server = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        server.items.push(HydratedConversationItem {
            id: "server-item-1".to_string(),
            content: HydratedConversationItemContent::UserInputResponse(
                HydratedUserInputResponseData {
                    questions: vec![HydratedUserInputResponseQuestionData {
                        id: "q-1".to_string(),
                        header: Some("Choice".to_string()),
                        question: "Pick one".to_string(),
                        answer: "A".to_string(),
                        options: vec![],
                    }],
                },
            ),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        });
        reducer.upsert_thread_snapshot(server);

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert!(thread.local_overlay_items.is_empty());
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "server-item-1");
    }

    #[test]
    fn stage_local_user_message_overlay_projects_immediately() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));

        let overlay_id = reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "hello from composer".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay id");

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread
            .local_overlay_items
            .iter()
            .find(|item| item.id == overlay_id)
            .expect("overlay item exists");
        match &item.content {
            HydratedConversationItemContent::User(data) => {
                assert_eq!(data.text, "hello from composer");
                assert!(data.image_data_uris.is_empty());
            }
            other => panic!("expected user overlay item, got {other:?}"),
        }
        assert!(item.is_from_user_turn_boundary);
        assert!(item.source_turn_id.is_none());
    }

    #[test]
    fn server_backed_user_message_supersedes_local_overlay_after_turn_binding() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        let overlay_id = reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "hello from composer".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay id");
        reducer.bind_local_user_message_overlay_to_turn(&key, &overlay_id, "turn-1");

        reducer.apply_item_update(
            &key,
            HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello from composer".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            },
        );

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                if thread.key == key
        )));

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert!(thread.local_overlay_items.is_empty());
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "server-user-item");
    }

    #[test]
    fn binding_turn_after_server_user_item_arrives_removes_local_overlay() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        let overlay_id = reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "hello from composer".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay id");

        reducer.apply_item_update(
            &key,
            HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello from composer".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            },
        );

        reducer.bind_local_user_message_overlay_to_turn(&key, &overlay_id, "turn-1");

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                if thread.key == key
        )));

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert!(thread.local_overlay_items.is_empty());
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "server-user-item");
    }

    #[test]
    fn server_backed_user_message_immediately_supersedes_unbound_local_overlay() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));

        reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "hello from composer".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay id");

        reducer.apply_item_update(
            &key,
            HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello from composer".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            },
        );

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert!(thread.local_overlay_items.is_empty());
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "server-user-item");
    }

    /// Repro for the duplicate-first-user-message bug surfaced by user
    /// testing on a v0.125 remote. iOS flow on a brand-new thread is:
    ///   1. apply_thread_start_response (handled by MobileClient).
    ///   2. stage_local_user_message_overlay + bind_local_user_message_overlay_to_turn.
    ///   3. apply_item_update twice (ItemStarted + ItemCompleted, same content).
    ///   4. apply_thread_read_response from refreshThreadSnapshot — embedded
    ///      thread.turns carry the same UserMessage.
    ///
    /// After step 3 the overlay should be superseded; after step 4 the
    /// authoritative thread.items must contain exactly one user item.
    /// The merged view (boundary projection) must not duplicate.
    #[test]
    fn first_user_message_does_not_duplicate_after_thread_read() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        // Step 1: thread/start equivalent — populate empty thread snapshot.
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-1"),
        ));

        // Step 2: stage overlay + bind via the TurnStarted-event path
        // (`bind_first_pending_local_user_message_overlay_to_turn`), which
        // is what the real device run does — `start_turn` itself binds via
        // the RPC response, but typically the TurnStarted notification
        // arrives first and the bind there is a no-op for the second call.
        let inputs = vec![upstream::UserInput::Text {
            text: "run some tools im testing".to_string(),
            text_elements: Vec::new(),
        }];
        let overlay_id = reducer
            .stage_local_user_message_overlay(&key, &inputs)
            .expect("overlay id");
        // First bind comes from the TurnStarted event handler (sets the
        // active_turn_id on the thread before the bind, so let's simulate).
        reducer
            .mutate_thread_with_result(&key, |thread| {
                thread.active_turn_id = Some("turn-1".to_string());
            })
            .expect("set active_turn_id");
        reducer.bind_first_pending_local_user_message_overlay_to_turn(&key, "turn-1");
        // Second bind comes from start_turn's RPC response — no-op since
        // overlay is already bound to turn-1.
        reducer.bind_local_user_message_overlay_to_turn(&key, &overlay_id, "turn-1");

        // Step 3: ItemStarted/ItemCompleted with a UserMessage item built via
        // the same `conversation_item_from_upstream` path the event loop uses.
        // This sets `source_turn_id: None` (events don't carry the turn id)
        // and exercises the real dedupe surface.
        let mut update_receiver = reducer.subscribe();
        // Drain any prior emits so we observe only the upcoming ones.
        let _ = drain_updates(&mut update_receiver);

        let upstream_item = upstream::ThreadItem::UserMessage {
            id: "server-user-item".to_string(),
            content: inputs.clone(),
        };
        let server_user_item = crate::store::actions::conversation_item_from_upstream_with_turn(
            upstream_item.clone(),
            None,
        )
        .expect("hydrate user item");
        reducer.apply_item_update(&key, server_user_item.clone());

        // The first apply_item_update must fire `ThreadUpserted` because
        // it removes the local overlay. If it fires only `ThreadItemChanged`
        // (the bug shape from the device log), iOS will see both the overlay
        // and the upstream item as separate bubbles.
        let updates = drain_updates(&mut update_receiver);
        let saw_upsert = updates
            .iter()
            .any(|u| matches!(u, AppStoreUpdateRecord::ThreadUpserted { .. }));
        assert!(
            saw_upsert,
            "apply_item_update for the upstream UserMessage must emit \
             ThreadUpserted to clear the local overlay; got updates={updates:?}"
        );

        // ItemCompleted re-applies the same item idempotently.
        reducer.apply_item_update(&key, server_user_item.clone());

        // After events the local overlay must be superseded and exactly
        // one user item lives in `thread.items`.
        {
            let snap = reducer.snapshot();
            let thread = snap.threads.get(&key).expect("thread");
            assert!(
                thread.local_overlay_items.is_empty(),
                "overlay should be swept once upstream item arrives; got {:?}",
                thread.local_overlay_items
            );
            assert_eq!(thread.items.len(), 1, "events should yield one item");
        }

        // Step 4: thread/read carrying the same UserMessage in
        // thread.turns. Build the equivalent ThreadSnapshot via the same
        // helper apply_thread_read_response uses, then upsert.
        let upstream_thread = upstream::Thread {
            id: "thread-1".to_string(),
            forked_from_id: None,
            preview: "run some tools im testing".to_string(),
            ephemeral: false,
            model_provider: "openai".to_string(),
            created_at: 1,
            updated_at: 2,
            status: upstream::ThreadStatus::Idle,
            path: Some(std::path::PathBuf::from("/tmp/thread.jsonl")),
            cwd: codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path_checked("/tmp")
                .expect("absolute path"),
            cli_version: "0.125.0".to_string(),
            source: upstream::SessionSource::default(),
            agent_nickname: None,
            agent_role: None,
            git_info: None,
            name: Some("Thread".to_string()),
            turns: vec![upstream::Turn {
                id: "turn-1".to_string(),
                status: upstream::TurnStatus::Completed,
                items: vec![upstream::ThreadItem::UserMessage {
                    id: "server-user-item".to_string(),
                    content: inputs.clone(),
                }],
                error: None,
                started_at: None,
                completed_at: None,
                duration_ms: None,
            }],
        };
        let mut read_snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            "srv",
            upstream_thread,
            None,
            None,
            None,
            None,
        )
        .expect("read snapshot");
        read_snapshot.initial_turns_loaded = true;
        read_snapshot.older_turns_cursor = None;
        reducer.upsert_thread_snapshot(read_snapshot);

        // Final state: store + overlay merged should yield exactly one
        // User item with the submitted text.
        let snap = reducer.snapshot();
        let thread = snap.threads.get(&key).expect("thread");
        let user_items_in_store: Vec<_> = thread
            .items
            .iter()
            .filter(|item| matches!(item.content, HydratedConversationItemContent::User(_)))
            .collect();
        let user_overlays: Vec<_> = thread
            .local_overlay_items
            .iter()
            .filter(|item| matches!(item.content, HydratedConversationItemContent::User(_)))
            .collect();
        assert_eq!(
            user_items_in_store.len(),
            1,
            "exactly one user item expected in store after thread/read; \
             store={user_items_in_store:?} overlays={user_overlays:?}"
        );
        assert!(
            user_overlays.is_empty(),
            "overlay should not survive thread/read; remaining: {user_overlays:?}"
        );

        // Final UI projection: AppThreadSnapshot.hydrated_conversation_items
        // is what iOS renders. Confirm the merged view also yields exactly
        // one user bubble.
        let app_snapshot = reducer.snapshot();
        let app_thread = crate::store::boundary::project_thread_snapshot(&app_snapshot, &key)
            .expect("project ok")
            .expect("thread present");
        let user_bubbles_in_view: Vec<_> = app_thread
            .hydrated_conversation_items
            .iter()
            .filter(|item| matches!(item.content, HydratedConversationItemContent::User(_)))
            .collect();
        assert_eq!(
            user_bubbles_in_view.len(),
            1,
            "merged hydrated view must show exactly one user bubble; got {user_bubbles_in_view:?}"
        );
    }

    #[test]
    fn upsert_thread_snapshot_preserves_existing_title_when_incoming_title_missing() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };

        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));

        let mut incoming = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        incoming.info.title = None;
        incoming.info.preview = Some("First user message".to_string());

        reducer.upsert_thread_snapshot(incoming);

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert_eq!(thread.info.title.as_deref(), Some("Thread thread"));
        assert_eq!(thread.info.preview.as_deref(), Some("First user message"));
    }

    #[test]
    fn upsert_thread_snapshot_preserves_existing_preview_when_incoming_preview_missing() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };

        let mut initial = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        initial.info.preview = Some("First user message".to_string());
        reducer.upsert_thread_snapshot(initial);

        // Incoming snapshot has no preview (e.g. from thread/resume with empty preview)
        let mut incoming = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        incoming.info.preview = None;
        reducer.upsert_thread_snapshot(incoming);

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert_eq!(
            thread.info.preview.as_deref(),
            Some("First user message"),
            "existing preview should be preserved when incoming is None"
        );
    }

    #[test]
    fn upsert_thread_snapshot_binds_pending_local_user_overlay_to_incoming_active_turn() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        let overlay_id = reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "hello from composer".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay staged");

        let mut incoming = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        incoming.active_turn_id = Some("turn-1".to_string());
        incoming.info.status = ThreadSummaryStatus::Active;
        incoming
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: HydratedConversationItemContent::User(HydratedUserMessageData {
                    text: "hello from composer".to_string(),
                    image_data_uris: Vec::new(),
                }),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: Some(0),
                timestamp: None,
                is_from_user_turn_boundary: true,
            });

        reducer.upsert_thread_snapshot(incoming);

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-1"));
        assert!(thread.local_overlay_items.is_empty());
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "server-user-item");

        let overlay_still_present = thread
            .items
            .iter()
            .chain(thread.local_overlay_items.iter())
            .any(|item| item.id == overlay_id);
        assert!(!overlay_still_present, "overlay should be deduped");
    }

    #[test]
    fn upsert_thread_snapshot_dedupes_matching_unbound_local_overlay() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "hello from composer".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay staged");

        let mut incoming = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        incoming
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: HydratedConversationItemContent::User(HydratedUserMessageData {
                    text: "hello from composer".to_string(),
                    image_data_uris: Vec::new(),
                }),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: Some(0),
                timestamp: None,
                is_from_user_turn_boundary: true,
            });

        reducer.upsert_thread_snapshot(incoming);

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert!(thread.local_overlay_items.is_empty());
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "server-user-item");
    }

    #[test]
    fn turn_started_consumes_first_queued_follow_up_preview() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        reducer.enqueue_thread_follow_up_preview(
            &key,
            AppQueuedFollowUpPreview {
                id: "queued-1".to_string(),
                kind: crate::store::snapshot::AppQueuedFollowUpKind::Message,
                text: "first".to_string(),
            },
        );
        reducer.enqueue_thread_follow_up_preview(
            &key,
            AppQueuedFollowUpPreview {
                id: "queued-2".to_string(),
                kind: crate::store::snapshot::AppQueuedFollowUpKind::Message,
                text: "second".to_string(),
            },
        );

        reducer.apply_ui_event(&UiEvent::TurnStarted {
            key: key.clone(),
            turn_id: "turn-2".to_string(),
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-2"));
        assert_eq!(thread.queued_follow_ups.len(), 1);
        assert_eq!(thread.queued_follow_ups[0].id, "queued-2");
    }

    #[test]
    fn turn_started_binds_first_pending_local_user_message_overlay() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        let overlay_id = reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "hello from composer".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay id");

        reducer.apply_ui_event(&UiEvent::TurnStarted {
            key: key.clone(),
            turn_id: "turn-2".to_string(),
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread
            .local_overlay_items
            .iter()
            .find(|item| item.id == overlay_id)
            .expect("overlay item exists");
        assert_eq!(item.source_turn_id.as_deref(), Some("turn-2"));
    }

    #[test]
    fn thread_name_updated_emits_thread_state_updated_without_thread_upsert() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.apply_ui_event(&UiEvent::ThreadNameUpdated {
            key: key.clone(),
            thread_name: Some("Renamed".to_string()),
        });

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadMetadataChanged { state, .. }
                if state.key == key && state.info.title.as_deref() == Some("Renamed")
        )));
        assert!(
            updates
                .iter()
                .all(|update| !matches!(update, AppStoreUpdateRecord::ThreadUpserted { .. }))
        );
    }

    #[test]
    fn thread_status_changed_emits_thread_metadata_changed_for_existing_thread() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.apply_ui_event(&UiEvent::ThreadStatusChanged {
            key: key.clone(),
            notification: codex_app_server_protocol::ThreadStatusChangedNotification {
                thread_id: key.thread_id.clone(),
                status: upstream::ThreadStatus::Active {
                    active_flags: Vec::new(),
                },
            },
        });

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadMetadataChanged { state, .. }
                if state.key == key && state.info.status == ThreadSummaryStatus::Active
        )));
        assert!(
            updates
                .iter()
                .all(|update| !matches!(update, AppStoreUpdateRecord::ThreadUpserted { .. }))
        );
    }

    #[test]
    fn duplicate_thread_item_upsert_is_suppressed() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        let item = HydratedConversationItem {
            id: "call-1".to_string(),
            content: HydratedConversationItemContent::CommandExecution(
                HydratedCommandExecutionData {
                    command: "echo hi".to_string(),
                    cwd: "/tmp".to_string(),
                    output: Some("hi".to_string()),
                    exit_code: Some(0),
                    status: AppOperationStatus::Completed,
                    duration_ms: Some(10),
                    process_id: None,
                    actions: Vec::new(),
                },
            ),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: Some(1),
            timestamp: None,
            is_from_user_turn_boundary: false,
        };

        reducer.emit_thread_item_changed(&key, item.clone());
        reducer.emit_thread_item_changed(&key, item);

        let updates = drain_updates(&mut receiver);
        let upsert_count = updates
            .iter()
            .filter(|update| {
                matches!(
                    update,
                    AppStoreUpdateRecord::ThreadItemChanged {
                        key: update_key,
                        item,
                        ..
                    } if update_key == &key && item.id == "call-1"
                )
            })
            .count();
        assert_eq!(upsert_count, 1);
    }

    #[test]
    fn upsert_thread_snapshot_replaces_existing_thread_with_thread_upserted() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };

        let mut existing = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        existing.items = vec![
            HydratedConversationItem {
                id: "user-1".to_string(),
                content: HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: Some(1),
                timestamp: None,
                is_from_user_turn_boundary: true,
            },
            HydratedConversationItem {
                id: "assistant-1".to_string(),
                content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                    text: "old".to_string(),
                    agent_nickname: None,
                    agent_role: None,
                    phase: None,
                }),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: Some(1),
                timestamp: None,
                is_from_user_turn_boundary: false,
            },
        ];
        reducer.upsert_thread_snapshot(existing);

        let mut incoming = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        incoming.items = vec![
            HydratedConversationItem {
                id: "user-1".to_string(),
                content: HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: Some(1),
                timestamp: None,
                is_from_user_turn_boundary: true,
            },
            HydratedConversationItem {
                id: "assistant-1".to_string(),
                content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                    text: "new".to_string(),
                    agent_nickname: None,
                    agent_role: None,
                    phase: None,
                }),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: Some(1),
                timestamp: None,
                is_from_user_turn_boundary: false,
            },
        ];

        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.upsert_thread_snapshot(incoming);

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                if thread.key == key
        )));
    }

    #[test]
    fn upsert_thread_snapshot_emits_thread_upserted_for_changed_items() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };

        let mut existing = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        existing.items = vec![HydratedConversationItem {
            id: "assistant-old".to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: "old".to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: Some(1),
            timestamp: None,
            is_from_user_turn_boundary: false,
        }];
        reducer.upsert_thread_snapshot(existing);

        let mut incoming = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        incoming.items = vec![HydratedConversationItem {
            id: "assistant-new".to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: "new".to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: Some(1),
            timestamp: None,
            is_from_user_turn_boundary: false,
        }];

        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.upsert_thread_snapshot(incoming);

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                if thread.key == key
        )));
    }

    #[test]
    fn user_turn_boundary_item_consumes_stale_queued_follow_up_preview() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        reducer
            .upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info("thread")));
        reducer.enqueue_thread_follow_up_preview(
            &key,
            AppQueuedFollowUpPreview {
                id: "queued-1".to_string(),
                kind: crate::store::snapshot::AppQueuedFollowUpKind::Message,
                text: "queued follow-up".to_string(),
            },
        );

        reducer.apply_item_update(
            &key,
            HydratedConversationItem {
                id: "user-1".to_string(),
                content: HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "queued follow-up".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-2".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            },
        );

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert!(thread.queued_follow_ups.is_empty());
    }

    // ── SW-R3: streaming dynamic tool call argument deltas ───────────

    fn key_thread(thread_id: &str) -> ThreadKey {
        ThreadKey {
            server_id: "srv".to_string(),
            thread_id: thread_id.to_string(),
        }
    }

    #[test]
    fn dynamic_tool_arg_delta_emits_streaming_update_with_growing_prefix() {
        let reducer = AppStoreReducer::new();
        let key = key_thread("thread-1");
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-1"),
        ));
        let mut receiver = reducer.subscribe();
        let _ = drain_updates(&mut receiver);

        for chunk in [
            r#"{"app_id":"fit","title":"Fit","widget_code":"<di"#,
            r#"v>hi"#,
            r#"</div>"}"#,
        ] {
            reducer.apply_ui_event(&UiEvent::DynamicToolCallArgumentsDelta {
                key: key.clone(),
                item_id: "item-1".to_string(),
                call_id: Some("call-1".to_string()),
                delta: chunk.to_string(),
            });
        }

        let updates = drain_updates(&mut receiver);
        let widgets: Vec<_> = updates
            .iter()
            .filter_map(|update| match update {
                AppStoreUpdateRecord::DynamicWidgetStreaming { widget, .. } => Some(widget),
                _ => None,
            })
            .collect();
        assert!(
            widgets.len() >= 2,
            "expected multiple streaming updates, got {widgets:?}"
        );
        for w in &widgets {
            assert!(
                !w.is_finalized,
                "streaming widget must report is_finalized=false"
            );
        }
        // The first streaming update's widget_html must be a prefix of
        // the last update's widget_html.
        let first = &widgets[0].widget_html;
        let last = &widgets.last().unwrap().widget_html;
        assert!(last.starts_with(first), "first={first:?} last={last:?}");
        // Final is the fully-parsed object (complete JSON) — closed tags.
        assert_eq!(last, "<div>hi</div>");
    }

    #[test]
    fn dynamic_tool_arg_delta_reuses_known_item_id_when_later_delta_omits_it() {
        let reducer = AppStoreReducer::new();
        let key = key_thread("thread-omit-item-id");
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-omit-item-id"),
        ));
        let mut receiver = reducer.subscribe();
        let _ = drain_updates(&mut receiver);

        reducer.apply_ui_event(&UiEvent::DynamicToolCallArgumentsDelta {
            key: key.clone(),
            item_id: "item-1".to_string(),
            call_id: Some("call-1".to_string()),
            delta: r#"{"app_id":"fit","title":"Fit","widget_code":"<div"#.to_string(),
        });
        reducer.apply_ui_event(&UiEvent::DynamicToolCallArgumentsDelta {
            key,
            item_id: String::new(),
            call_id: Some("call-1".to_string()),
            delta: r#">hi</div>"}"#.to_string(),
        });

        let item_ids: Vec<_> = drain_updates(&mut receiver)
            .into_iter()
            .filter_map(|update| match update {
                AppStoreUpdateRecord::DynamicWidgetStreaming { item_id, .. } => Some(item_id),
                _ => None,
            })
            .collect();
        assert!(
            !item_ids.is_empty(),
            "expected at least one DynamicWidgetStreaming update"
        );
        assert!(
            item_ids.iter().all(|item_id| item_id == "item-1"),
            "streaming widget updates should keep the known item id, got {item_ids:?}"
        );
    }

    #[test]
    fn dynamic_tool_arg_delta_buffer_clears_on_item_completed() {
        use codex_app_server_protocol::{
            DynamicToolCallStatus, ItemCompletedNotification, ThreadItem,
        };
        let reducer = AppStoreReducer::new();
        let key = key_thread("thread-2");
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-2"),
        ));

        // Seed a running buffer.
        reducer.apply_ui_event(&UiEvent::DynamicToolCallArgumentsDelta {
            key: key.clone(),
            item_id: "item-99".to_string(),
            call_id: Some("call-99".to_string()),
            delta: r#"{"widget_code":"<svg"#.to_string(),
        });
        assert_eq!(reducer.dynamic_tool_arg_buffers.read().unwrap().len(), 1);

        // ItemCompleted for the same (thread, item) drops the buffer.
        reducer.apply_ui_event(&UiEvent::ItemCompleted {
            key: key.clone(),
            notification: ItemCompletedNotification {
                thread_id: key.thread_id.clone(),
                turn_id: "turn-1".to_string(),
                item: ThreadItem::DynamicToolCall {
                    id: "item-99".to_string(),
                    tool: "show_widget".to_string(),
                    namespace: None,
                    arguments: serde_json::json!({}),
                    status: DynamicToolCallStatus::Completed,
                    content_items: None,
                    success: Some(true),
                    duration_ms: None,
                },
            },
        });

        assert!(
            reducer.dynamic_tool_arg_buffers.read().unwrap().is_empty(),
            "buffer should be cleared after item completion"
        );
    }

    #[test]
    fn dynamic_tool_arg_delta_buffers_are_scoped_per_call() {
        let reducer = AppStoreReducer::new();
        let key = key_thread("thread-3");
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-3"),
        ));

        // Two separate calls in the same thread shouldn't cross-pollute.
        reducer.apply_ui_event(&UiEvent::DynamicToolCallArgumentsDelta {
            key: key.clone(),
            item_id: "item-A".to_string(),
            call_id: Some("call-A".to_string()),
            delta: r#"{"widget_code":"AAA"#.to_string(),
        });
        reducer.apply_ui_event(&UiEvent::DynamicToolCallArgumentsDelta {
            key: key.clone(),
            item_id: "item-B".to_string(),
            call_id: Some("call-B".to_string()),
            delta: r#"{"widget_code":"BBB"#.to_string(),
        });

        let buffers = reducer.dynamic_tool_arg_buffers.read().unwrap();
        assert_eq!(buffers.len(), 2);
        let entry_a = buffers
            .get(&(key.clone(), "call-A".to_string()))
            .expect("A buffer");
        let entry_b = buffers
            .get(&(key.clone(), "call-B".to_string()))
            .expect("B buffer");
        assert!(entry_a.buffer.contains("AAA"));
        assert!(entry_b.buffer.contains("BBB"));
        assert_eq!(entry_a.item_id, "item-A");
        assert_eq!(entry_b.item_id, "item-B");
    }
}

fn appended_text_delta(existing: &str, projected: &str) -> Option<String> {
    projected
        .starts_with(existing)
        .then(|| projected[existing.len()..].to_string())
}

fn appended_optional_text_delta(
    existing: &Option<String>,
    projected: &Option<String>,
) -> Option<String> {
    match (existing.as_deref(), projected.as_deref()) {
        (None, None) => Some(String::new()),
        (None, Some(projected)) => Some(projected.to_string()),
        (Some(existing), Some(projected)) => appended_text_delta(existing, projected),
        (Some(_), None) => None,
    }
}

fn classify_item_mutation(
    existing: Option<&HydratedConversationItem>,
    item: &HydratedConversationItem,
) -> Option<ItemMutationUpdate> {
    let Some(existing) = existing else {
        return Some(ItemMutationUpdate::Upsert(HydratedConversationItem::from(
            item.clone(),
        )));
    };

    match (&existing.content, &item.content) {
        (
            HydratedConversationItemContent::CommandExecution(existing_data),
            HydratedConversationItemContent::CommandExecution(projected_data),
        ) => {
            if existing.id != item.id
                || existing.source_turn_id != item.source_turn_id
                || existing.source_turn_index != item.source_turn_index
                || existing.timestamp != item.timestamp
                || existing.is_from_user_turn_boundary != item.is_from_user_turn_boundary
                || existing_data.command != projected_data.command
                || existing_data.cwd != projected_data.cwd
                || existing_data.actions != projected_data.actions
            {
                return Some(ItemMutationUpdate::Upsert(HydratedConversationItem::from(
                    item.clone(),
                )));
            }

            let output_delta =
                appended_optional_text_delta(&existing_data.output, &projected_data.output)?;
            let status_changed = existing_data.status != projected_data.status
                || existing_data.exit_code != projected_data.exit_code
                || existing_data.duration_ms != projected_data.duration_ms
                || existing_data.process_id != projected_data.process_id;
            if output_delta.is_empty() && !status_changed {
                None
            } else {
                Some(ItemMutationUpdate::Upsert(HydratedConversationItem::from(
                    item.clone(),
                )))
            }
        }
        _ if existing.content == item.content => None,
        _ => Some(ItemMutationUpdate::Upsert(HydratedConversationItem::from(
            item.clone(),
        ))),
    }
}

fn format_model_reroute_reason(reason: &codex_app_server_protocol::ModelRerouteReason) -> String {
    let raw = format!("{reason:?}");
    let mut formatted = String::new();
    for (index, ch) in raw.chars().enumerate() {
        if index > 0 && ch.is_uppercase() {
            formatted.push(' ');
        }
        formatted.push(ch);
    }
    formatted
}
