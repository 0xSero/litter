use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hasher};
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
    PendingUserInputAnswer, PendingUserInputKey, PendingUserInputRequest,
    PendingUserInputSeed, ThreadInfo, ThreadKey, ThreadSummaryStatus,
};
#[cfg(test)]
use crate::types::PendingApprovalWithSeed;
use crate::types::{
    AppModeKind, AppOperationStatus, AppPlanProgressSnapshot, AppPlanStep, AppThreadGoal,
    AppVoiceSessionPhase, AppVoiceTranscriptEntry, AppVoiceTranscriptUpdate,
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
    AppSnapshot, AppTerminalSessionPhase, AppVoiceSessionSnapshot, PendingServerMutatingCommand,
    QueuedFollowUpDraft, ServerHealthSnapshot, ServerMutatingCommandKind, ServerSnapshot,
    ServerTransportDiagnostics, TerminalSessionSnapshot, ThreadSnapshot,
};
use super::updates::{AppStoreUpdateRecord, ThreadStreamingDeltaKind};
use super::voice::{VoiceDerivedUpdate, VoiceRealtimeState};
use crate::terminal::TerminalBackendKind;

const USER_INPUT_NOTE_PREFIX: &str = "user_note: ";
const USER_INPUT_OTHER_OPTION_LABEL: &str = "None of the above";
const LOCAL_USER_MESSAGE_ITEM_PREFIX: &str = "local-user-message:";
const DESKTOP_FILE_CONTEXT_HEADER: &str = "# Files mentioned by the user:";
const DESKTOP_FILE_CONTEXT_REQUEST_HEADER: &str = "## My request for Codex:";

/// Bytes of the serialized item head that are fed to the hasher verbatim.
const FINGERPRINT_HEAD_BYTES: usize = 4096;
/// Bytes of the serialized item tail that are fed to the hasher verbatim.
const FINGERPRINT_TAIL_BYTES: usize = 1024;

/// `std::io::Write` sink that digests a bounded head + tail of the stream
/// plus the exact total length, instead of the whole stream.
///
/// A completed command execution can carry >100 KiB of captured output;
/// hashing all of it on every emit dominated the store's per-event cost.
/// Head + tail + total length still discriminates every way an item
/// actually changes in practice: text fields only ever grow or get replaced
/// wholesale (length changes), and the small status/lifecycle fields sit in
/// the head or the tail of the encoding.
struct BoundedHashWriter<'a> {
    hasher: &'a mut DefaultHasher,
    head_remaining: usize,
    tail: [u8; FINGERPRINT_TAIL_BYTES],
    tail_len: usize,
    tail_start: usize,
    total: usize,
}

impl<'a> BoundedHashWriter<'a> {
    fn new(hasher: &'a mut DefaultHasher) -> Self {
        Self {
            hasher,
            head_remaining: FINGERPRINT_HEAD_BYTES,
            tail: [0; FINGERPRINT_TAIL_BYTES],
            tail_len: 0,
            tail_start: 0,
            total: 0,
        }
    }

    /// Fold the retained tail bytes and the total length into the hasher.
    fn finish(self) {
        for offset in 0..self.tail_len {
            let index = (self.tail_start + offset) % FINGERPRINT_TAIL_BYTES;
            self.hasher.write_u8(self.tail[index]);
        }
        self.hasher.write_usize(self.total);
    }
}

impl std::io::Write for BoundedHashWriter<'_> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if self.head_remaining > 0 {
            let take = self.head_remaining.min(buf.len());
            self.hasher.write(&buf[..take]);
            self.head_remaining -= take;
        }
        self.total = self.total.saturating_add(buf.len());

        // Keep a rolling window of the final `FINGERPRINT_TAIL_BYTES`.
        let tail_slice = if buf.len() >= FINGERPRINT_TAIL_BYTES {
            self.tail_len = 0;
            self.tail_start = 0;
            &buf[buf.len() - FINGERPRINT_TAIL_BYTES..]
        } else {
            buf
        };
        for byte in tail_slice {
            if self.tail_len == FINGERPRINT_TAIL_BYTES {
                self.tail[self.tail_start] = *byte;
                self.tail_start = (self.tail_start + 1) % FINGERPRINT_TAIL_BYTES;
            } else {
                let index = (self.tail_start + self.tail_len) % FINGERPRINT_TAIL_BYTES;
                self.tail[index] = *byte;
                self.tail_len += 1;
            }
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Compute a 64-bit fingerprint of a projected `HydratedConversationItem`
/// suitable for redundant-emit dedup in `emit_thread_item_changed`. Streams
/// the item's serde representation into a bounded hasher so we neither
/// retain a full clone of the item alongside the canonical store copy nor
/// pay to digest large captured outputs on every delta.
///
/// A u64 collision would only cost us a single skipped `ThreadItemChanged`
/// emit (followed immediately by another differing fingerprint on the next
/// delta), which is acceptable at our item counts.
fn item_fingerprint(item: &HydratedConversationItem) -> u64 {
    let mut hasher = DefaultHasher::new();
    let mut writer = BoundedHashWriter::new(&mut hasher);
    serde_json::to_writer(&mut writer, item)
        .expect("HydratedConversationItem Serialize impl is infallible");
    writer.finish();
    hasher.finish()
}

fn dedupe_agent_runtimes(runtimes: Vec<AgentRuntimeInfo>) -> Vec<AgentRuntimeInfo> {
    let mut indexes_by_kind: HashMap<AgentRuntimeKind, usize> = HashMap::new();
    let mut deduped: Vec<AgentRuntimeInfo> = Vec::new();
    for runtime in runtimes {
        if let Some(index) = indexes_by_kind.get(&runtime.kind).copied() {
            if runtime.available && !deduped[index].available {
                deduped[index] = runtime;
            }
        } else {
            indexes_by_kind.insert(runtime.kind.clone(), deduped.len());
            deduped.push(runtime);
        }
    }
    deduped
}

pub struct AppStoreReducer {
    snapshot: RwLock<AppSnapshot>,
    /// Local Studio notifications can arrive before the asynchronous store
    /// listener has inserted their thread. Preserve that transport-owned
    /// identity until the first snapshot lands instead of defaulting the new
    /// thread to Codex.
    pending_local_studio_thread_routes: RwLock<HashSet<ThreadKey>>,
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
    /// Per-thread, per-item-id fingerprint of the last emitted projected
    /// item, used to skip redundant `ThreadItemChanged` emits. Storing a u64
    /// hash instead of the item itself avoids a long-lived second copy of
    /// every item in memory — on a 5k-item streaming thread that doubled the
    /// canonical `ThreadSnapshot.items` heap footprint.
    ///
    /// Nested by `ThreadKey` so `clear_thread_update_caches` is a single
    /// `remove` rather than a full-map `retain` on every thread upsert.
    last_thread_item_upserts: RwLock<HashMap<ThreadKey, HashMap<String, u64>>>,
    /// Memoized `current_agent_directory_version`. Invalidated whenever a
    /// snapshot write guard is released (see [`Self::write_snapshot`]), so a
    /// burst of emits that follow a single mutation recompute it at most
    /// once.
    agent_directory_memo: RwLock<Option<u64>>,
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

/// Write guard over [`AppStoreReducer::snapshot`] that invalidates every
/// snapshot-derived memo when it is released.
///
/// The memo is cleared *before* the underlying write lock is dropped (fields
/// drop after the `Drop` body), so no reader can observe the new snapshot
/// alongside a memo computed from the old one.
struct SnapshotWriteGuard<'a> {
    guard: std::sync::RwLockWriteGuard<'a, AppSnapshot>,
    agent_directory_memo: &'a RwLock<Option<u64>>,
}

impl std::ops::Deref for SnapshotWriteGuard<'_> {
    type Target = AppSnapshot;

    fn deref(&self) -> &Self::Target {
        &self.guard
    }
}

impl std::ops::DerefMut for SnapshotWriteGuard<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.guard
    }
}

impl Drop for SnapshotWriteGuard<'_> {
    fn drop(&mut self) {
        *self
            .agent_directory_memo
            .write()
            .expect("agent directory memo poisoned") = None;
    }
}

impl AppStoreReducer {
    pub fn new() -> Self {
        // Streaming turns can burst small deltas quickly; keep enough headroom so
        // native subscribers do not immediately fall into lagged/full-resync mode.
        let (updates_tx, _) = broadcast::channel(1024);
        Self {
            snapshot: RwLock::new(AppSnapshot::default()),
            pending_local_studio_thread_routes: RwLock::new(HashSet::new()),
            last_thread_state_updates: RwLock::new(HashMap::new()),
            last_thread_item_upserts: RwLock::new(HashMap::new()),
            agent_directory_memo: RwLock::new(None),
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

    /// Acquire the snapshot write lock. Releasing the returned guard drops
    /// every memo derived from the snapshot, so derived-state caches cannot
    /// outlive the state they were computed from.
    fn write_snapshot(&self) -> SnapshotWriteGuard<'_> {
        SnapshotWriteGuard {
            guard: self.snapshot.write().expect("app store lock poisoned"),
            agent_directory_memo: &self.agent_directory_memo,
        }
    }

    /// `current_agent_directory_version`, memoized until the next snapshot
    /// mutation. The caller must already hold a read lock on the snapshot.
    fn agent_directory_version(&self, snapshot: &AppSnapshot) -> u64 {
        if let Some(version) = *self
            .agent_directory_memo
            .read()
            .expect("agent directory memo poisoned")
        {
            return version;
        }
        let version = current_agent_directory_version(snapshot);
        *self
            .agent_directory_memo
            .write()
            .expect("agent directory memo poisoned") = Some(version);
        version
    }

    pub(crate) fn thread_snapshot(&self, key: &ThreadKey) -> Option<ThreadSnapshot> {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .threads
            .get(key)
            .cloned()
    }

    /// Project a single thread for the FFI boundary without cloning the rest
    /// of the app snapshot (all servers, all other threads, all terminal
    /// output tails) first.
    pub(crate) fn project_thread_snapshot(
        &self,
        key: &ThreadKey,
    ) -> Result<Option<crate::store::AppThreadSnapshot>, String> {
        let snapshot = self.snapshot.read().expect("app store lock poisoned");
        super::boundary::project_thread_snapshot(&snapshot, key)
    }

    /// Read the focused terminal session id without cloning the snapshot.
    /// Called synchronously from the UI thread once per rendered code block.
    pub(crate) fn active_terminal_id(&self) -> Option<String> {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .active_terminal_id
            .clone()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppStoreUpdateRecord> {
        self.updates_tx.subscribe()
    }

    pub fn upsert_server(&self, config: &ServerConfig, health: ServerHealthSnapshot) {
        {
            let mut snapshot = self.write_snapshot();
            let (
                existing_wake_mac,
                existing_account,
                requires_openai_auth,
                existing_rate_limits,
                existing_rate_limits_by_runtime,
                existing_available_models,
                existing_agent_runtimes,
                existing_connection_progress,
                existing_transport,
                existing_supports_turn_pagination,
            ) = if let Some(existing) = snapshot.servers.get(&config.server_id) {
                (
                    existing.wake_mac.clone(),
                    existing.account.clone(),
                    existing.requires_openai_auth,
                    existing.rate_limits.clone(),
                    existing.rate_limits_by_runtime.clone(),
                    existing.available_models.clone(),
                    existing.agent_runtimes.clone(),
                    existing.connection_progress.clone(),
                    existing.transport.clone(),
                    existing.supports_turn_pagination,
                )
            } else {
                (
                    None,
                    None,
                    false,
                    None,
                    HashMap::new(),
                    None,
                    vec![AgentRuntimeInfo {
                        kind: "codex".to_string(),
                        name: "codex".to_string(),
                        display_name: "Codex".to_string(),
                        available: true,
                    }],
                    None,
                    ServerTransportDiagnostics::default(),
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
                    health,
                    account: existing_account,
                    requires_openai_auth,
                    rate_limits: existing_rate_limits,
                    rate_limits_by_runtime: existing_rate_limits_by_runtime,
                    available_models: existing_available_models,
                    agent_runtimes: existing_agent_runtimes,
                    connection_progress: existing_connection_progress,
                    transport: existing_transport,
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
            let mut snapshot = self.write_snapshot();
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
            snapshot
                .pending_user_input_seeds
                .retain(|key, _| key.server_id != server_id);
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

    /// Whether a thread that is absent from an incoming `thread/list` page
    /// should survive the reconcile anyway. Besides the active thread and
    /// local-studio, never evict a thread we are actively using: one with an
    /// in-flight turn, queued follow-ups, a staged local overlay, or one
    /// created within the last minute. The brand-new-thread window matters
    /// because a just-started OpenCode session may not appear in
    /// `GET /session` until its first message lands; evicting it then causes
    /// the first `turn/start` overlay and its streamed events to be dropped
    /// (0xSero/litter#283).
    fn keep_thread_absent_from_incoming_page(thread: &ThreadSnapshot) -> bool {
        thread.active_turn_id.is_some()
            || !thread.queued_follow_ups.is_empty()
            || !thread.local_overlay_items.is_empty()
            || thread.info.created_at.is_some_and(|created_at| {
                created_at > 0 && (now_ms() as i64 / 1000).saturating_sub(created_at) < 60
            })
    }

    pub fn sync_thread_list(&self, server_id: &str, threads: &[ThreadInfo]) {
        self.sync_thread_list_for_runtime(server_id, "codex".to_string(), threads);
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
            let mut snapshot = self.write_snapshot();
            let active_thread_key = snapshot.active_thread.clone();
            snapshot.threads.retain(|key, thread| {
                let keep = key.server_id != server_id
                    || incoming_ids.contains(&key.thread_id)
                    || active_thread_key.as_ref() == Some(key)
                    || thread.agent_runtime_kind == "local-studio"
                    || Self::keep_thread_absent_from_incoming_page(thread);
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
                    if entry.agent_runtime_kind != runtime_kind
                        && entry.agent_runtime_kind != "local-studio"
                    {
                        entry.agent_runtime_kind = runtime_kind.clone();
                        updated_thread_keys.push(key);
                    }
                } else {
                    let mut thread = ThreadSnapshot::from_info(server_id, info.clone());
                    thread.agent_runtime_kind = runtime_kind.clone();
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
            let remaining_user_input_keys = snapshot
                .pending_user_inputs
                .iter()
                .map(|request| PendingUserInputKey {
                    server_id: request.server_id.clone(),
                    request_id: request.id.clone(),
                })
                .collect::<HashSet<_>>();
            snapshot
                .pending_user_input_seeds
                .retain(|key, _| remaining_user_input_keys.contains(key));
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
        self.upsert_thread_list_page_for_runtime(server_id, "codex".to_string(), threads);
    }

    pub fn upsert_thread_list_page_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        threads: &[ThreadInfo],
    ) {
        for info in threads {
            let mut snapshot = ThreadSnapshot::from_info(server_id, info.clone());
            snapshot.agent_runtime_kind = runtime_kind.clone();
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
            let mut snapshot = self.write_snapshot();
            let active_thread_key = snapshot.active_thread.clone();
            snapshot.threads.retain(|key, thread| {
                let keep = key.server_id != server_id
                    || incoming_ids.contains(&key.thread_id)
                    || active_thread_key.as_ref() == Some(key)
                    || thread.agent_runtime_kind == "local-studio"
                    || Self::keep_thread_absent_from_incoming_page(thread);
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
            let remaining_user_input_keys = snapshot
                .pending_user_inputs
                .iter()
                .map(|request| PendingUserInputKey {
                    server_id: request.server_id.clone(),
                    request_id: request.id.clone(),
                })
                .collect::<HashSet<_>>();
            snapshot
                .pending_user_input_seeds
                .retain(|key, _| remaining_user_input_keys.contains(key));
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
            let mut snapshot = self.write_snapshot();
            if self
                .pending_local_studio_thread_routes
                .write()
                .expect("pending Local Studio route lock poisoned")
                .remove(&key)
            {
                thread.agent_runtime_kind = "local-studio".to_string();
            }
            // Borrowed, not cloned: `thread` is a local, so the existing
            // entry can be read in place. Cloning it here duplicated every
            // item of the thread on every upsert just to read a handful of
            // preserved fields.
            if let Some(existing) = snapshot.threads.get(&key) {
                preserve_thread_title(&existing.info, &mut thread.info);
                preserve_thread_preview(&existing.info, &mut thread.info);
                preserve_thread_created_at(&existing.info, &mut thread.info);
                preserve_thread_fork_lineage(&existing.info, &mut thread.info);
                preserve_thread_runtime_state(existing, &mut thread);
                if thread.agent_runtime_kind == "codex" && existing.agent_runtime_kind != "codex" {
                    thread.agent_runtime_kind = existing.agent_runtime_kind.clone();
                }
                thread.is_resumed = thread.is_resumed || existing.is_resumed;
                preserve_local_overlay_items(existing, &mut thread);
                preserve_queued_follow_ups(existing, &mut thread);
                preserve_live_tool_items(existing, &mut thread);
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
            let mut snapshot = self.write_snapshot();
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

    pub(crate) fn claim_first_queued_follow_up_draft(
        &self,
        key: &ThreadKey,
    ) -> Option<QueuedFollowUpDraft> {
        let draft = self
            .mutate_thread_with_result(key, |thread| {
                let position = thread.queued_follow_up_drafts.iter().position(|draft| {
                    draft.preview.kind == super::snapshot::AppQueuedFollowUpKind::Message
                })?;
                let draft = thread.queued_follow_up_drafts.remove(position);
                sync_thread_follow_up_projection(thread);
                Some(draft)
            })
            .flatten();
        if draft.is_some() {
            self.emit_thread_metadata_changed(key);
        }
        draft
    }

    pub(crate) fn restore_queued_follow_up_draft_front(
        &self,
        key: &ThreadKey,
        draft: QueuedFollowUpDraft,
    ) {
        if self
            .mutate_thread_with_result(key, |thread| {
                if thread
                    .queued_follow_up_drafts
                    .iter()
                    .any(|existing| existing.preview.id == draft.preview.id)
                {
                    return false;
                }
                thread.queued_follow_up_drafts.insert(0, draft);
                sync_thread_follow_up_projection(thread);
                true
            })
            .unwrap_or(false)
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
        if let Some((updated_item, removed_item_ids, needs_reprojection)) = self
            .mutate_thread_with_result(key, |thread| {
                let mut updated_item = None;
                let mut needs_reprojection = false;
                if let Some(item) = thread.local_overlay_items.get_mut_by_id(item_id) {
                    if item.source_turn_id.as_deref() != Some(turn_id) {
                        item.source_turn_id = Some(turn_id.to_string());
                        needs_reprojection = true;
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
                    needs_reprojection,
                )
            })
        {
            if !removed_item_ids.is_empty() || needs_reprojection {
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
        if let Some((updated_item, removed_item_ids, needs_reprojection)) = self
            .mutate_thread_with_result(key, |thread| {
                let mut updated_item = None;
                let mut needs_reprojection = false;
                let pending_overlay_index =
                    thread.local_overlay_items.iter().position(|item| {
                        item.id.starts_with(LOCAL_USER_MESSAGE_ITEM_PREFIX)
                            && item.source_turn_id.is_none()
                    });
                if let Some(item) = pending_overlay_index
                    .and_then(|index| thread.local_overlay_items.get_mut(index))
                {
                    item.source_turn_id = Some(turn_id.to_string());
                    needs_reprojection = true;
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
                    needs_reprojection,
                )
            })
        {
            if !removed_item_ids.is_empty() || needs_reprojection {
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

    /// Atomically transitions a queued follow-up draft from `Message` to
    /// `PendingSteer`. Returns the updated draft and a snapshot of the
    /// thread's drafts in the new state on success. Returns `None` when the
    /// draft is missing or already in `PendingSteer`/`RetryingSteer` — used
    /// to drop duplicate steer taps before they reach the server.
    pub(crate) fn try_begin_steer_queued_follow_up(
        &self,
        key: &ThreadKey,
        preview_id: &str,
    ) -> Option<(QueuedFollowUpDraft, Vec<QueuedFollowUpDraft>)> {
        let result = self
            .mutate_thread_with_result(key, |thread| {
                let position = thread
                    .queued_follow_up_drafts
                    .iter()
                    .position(|d| d.preview.id == preview_id)?;
                let current_kind = thread.queued_follow_up_drafts[position].preview.kind;
                if current_kind != super::snapshot::AppQueuedFollowUpKind::Message {
                    return None;
                }
                thread.queued_follow_up_drafts[position].preview.kind =
                    super::snapshot::AppQueuedFollowUpKind::PendingSteer;
                let updated = thread.queued_follow_up_drafts[position].clone();
                let next = thread.queued_follow_up_drafts.clone();
                sync_thread_follow_up_projection(thread);
                Some((updated, next))
            })
            .flatten();
        if result.is_some() {
            self.emit_thread_metadata_changed(key);
        }
        result
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
            let mut snapshot = self.write_snapshot();
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
            let remaining_user_input_keys = snapshot
                .pending_user_inputs
                .iter()
                .map(|request| PendingUserInputKey {
                    server_id: request.server_id.clone(),
                    request_id: request.id.clone(),
                })
                .collect::<HashSet<_>>();
            snapshot
                .pending_user_input_seeds
                .retain(|key, _| remaining_user_input_keys.contains(key));
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
            let mut snapshot = self.write_snapshot();
            snapshot.active_thread = key.clone();
        }
        self.emit(AppStoreUpdateRecord::ActiveThreadChanged { key });
    }

    pub fn set_voice_handoff_thread(&self, key: Option<ThreadKey>) {
        {
            let mut snapshot = self.write_snapshot();
            snapshot.voice_session.handoff_thread_key = key;
        }
        self.emit(AppStoreUpdateRecord::VoiceSessionChanged);
    }

    pub fn replace_pending_approvals(&self, approvals: Vec<PendingApproval>) {
        let changed = {
            let mut snapshot = self.write_snapshot();
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

    #[cfg(test)]
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
            let mut snapshot = self.write_snapshot();
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
            let mut snapshot = self.write_snapshot();
            if snapshot.pending_user_inputs == requests {
                false
            } else {
                snapshot.pending_user_inputs = requests.clone();
                let remaining_keys = snapshot
                    .pending_user_inputs
                    .iter()
                    .map(|request| PendingUserInputKey {
                        server_id: request.server_id.clone(),
                        request_id: request.id.clone(),
                    })
                    .collect::<HashSet<_>>();
                snapshot
                    .pending_user_input_seeds
                    .retain(|key, _| remaining_keys.contains(key));
                true
            }
        };
        if changed {
            self.emit(AppStoreUpdateRecord::PendingUserInputsChanged { requests });
        }
    }

    pub fn resolve_approval(&self, request_id: &str) {
        let approvals = {
            let mut snapshot = self.write_snapshot();
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

    pub(crate) fn pending_user_input_seed(
        &self,
        server_id: &str,
        request_id: &str,
    ) -> Option<PendingUserInputSeed> {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .pending_user_input_seeds
            .get(&PendingUserInputKey {
                server_id: server_id.to_string(),
                request_id: request_id.to_string(),
            })
            .cloned()
    }

    pub fn resolve_pending_user_input(&self, request_id: &str) {
        let requests = {
            let mut snapshot = self.write_snapshot();
            snapshot
                .pending_user_inputs
                .retain(|request| request.id != request_id);
            snapshot
                .pending_user_input_seeds
                .retain(|key, _| key.request_id != request_id);
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
            let mut snapshot = self.write_snapshot();
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
            snapshot
                .pending_user_input_seeds
                .retain(|key, _| key.request_id != request_id);
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
            let mut snapshot = self.write_snapshot();
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
        runtime_kind: AgentRuntimeKind,
        rate_limits: Option<crate::types::RateLimitSnapshot>,
    ) {
        {
            let mut snapshot = self.write_snapshot();
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                match rate_limits.clone() {
                    Some(snapshot_value) => {
                        server
                            .rate_limits_by_runtime
                            .insert(runtime_kind, snapshot_value);
                    }
                    None => {
                        server.rate_limits_by_runtime.remove(&runtime_kind);
                    }
                }
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
            let mut snapshot = self.write_snapshot();
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
            let mut snapshot = self.write_snapshot();
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
            let mut snapshot = self.write_snapshot();
            let Some(thread) = snapshot.threads.get_mut(key) else {
                if runtime_kind == "local-studio" {
                    self.pending_local_studio_thread_routes
                        .write()
                        .expect("pending Local Studio route lock poisoned")
                        .insert(key.clone());
                }
                return;
            };
            self.pending_local_studio_thread_routes
                .write()
                .expect("pending Local Studio route lock poisoned")
                .remove(key);
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

    pub fn update_server_health(&self, server_id: &str, health: ServerHealthSnapshot) {
        {
            let mut snapshot = self.write_snapshot();
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
            let mut snapshot = self.write_snapshot();
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
        let mut snapshot = self.write_snapshot();
        for server in snapshot.servers.values_mut() {
            server.transport.last_lifecycle_phase = phase;
            server.transport.last_lifecycle_transition_at = Some(now);
            if phase == AppLifecyclePhaseSnapshot::Active {
                server.transport.last_resumed_at = Some(now);
            }
        }
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

    pub fn begin_server_mutating_command(
        &self,
        server_id: &str,
        kind: ServerMutatingCommandKind,
        thread_id: &str,
    ) -> String {
        let request_id = uuid::Uuid::new_v4().to_string();
        let started_at = std::time::Instant::now();
        let mut snapshot = self.write_snapshot();
        if let Some(server) = snapshot.servers.get_mut(server_id) {
            server.transport.pending_mutation = Some(PendingServerMutatingCommand {
                kind,
                thread_id: thread_id.to_string(),
                local_request_id: request_id.clone(),
                started_at,
                lifecycle_phase_at_send: server.transport.last_lifecycle_phase,
            });
        }
        request_id
    }

    pub fn finish_server_mutating_command_success(&self, server_id: &str, local_request_id: &str) {
        let now = std::time::Instant::now();
        let mut snapshot = self.write_snapshot();
        if let Some(server) = snapshot.servers.get_mut(server_id) {
            if server
                .transport
                .pending_mutation
                .as_ref()
                .is_some_and(|pending| pending.local_request_id == local_request_id)
            {
                server.transport.pending_mutation = None;
            }
            server.transport.last_direct_request_ok_at = Some(now);
        }
    }

    pub fn finish_server_mutating_command_failure(&self, server_id: &str, local_request_id: &str) {
        let mut snapshot = self.write_snapshot();
        if let Some(server) = snapshot.servers.get_mut(server_id)
            && server
                .transport
                .pending_mutation
                .as_ref()
                .is_some_and(|pending| pending.local_request_id == local_request_id)
        {
            server.transport.pending_mutation = None;
        }
    }

    pub fn note_server_direct_request_success(&self, server_id: &str) {
        let mut snapshot = self.write_snapshot();
        if let Some(server) = snapshot.servers.get_mut(server_id) {
            server.transport.last_direct_request_ok_at = Some(std::time::Instant::now());
        }
    }

    pub fn update_server_connection_progress(
        &self,
        server_id: &str,
        connection_progress: Option<AppConnectionProgressSnapshot>,
    ) {
        {
            let mut snapshot = self.write_snapshot();
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
            let mut snapshot = self.write_snapshot();
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
            let mut snapshot = self.write_snapshot();
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
                let status = info.status.clone();
                self.upsert_or_merge_thread(key.clone(), info, |thread| {
                    if matches!(
                        status,
                        ThreadSummaryStatus::Idle | ThreadSummaryStatus::SystemError
                    ) {
                        thread.active_turn_id = None;
                        thread.active_plan_progress = None;
                        thread.info.status = status.clone();
                    }
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
            UiEvent::ThreadGoalUpdated { key, goal, .. } => {
                self.apply_thread_goal(key, goal.clone());
            }
            UiEvent::ThreadGoalCleared { key } => {
                self.clear_thread_goal(key);
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
            UiEvent::FileChangePatchUpdated { key, notification } => {
                // Synthesize the in-flight FileChange item from the
                // progressive notification (codex emits these as a patch
                // is being applied; the canonical ItemCompleted lands at
                // the end). Going through the normal `apply_item_update`
                // path keeps fingerprint dedupe + `emit_thread_item_changed`
                // behaviour identical to a real ItemStarted, so home-row
                // diff stats + Edit log entries climb in real time.
                let upstream_item = upstream::ThreadItem::FileChange {
                    id: notification.item_id.clone(),
                    changes: notification.changes.clone(),
                    status: upstream::PatchApplyStatus::InProgress,
                };
                if let Some(item) = conversation_item_from_upstream_with_turn(
                    upstream_item,
                    Some(&notification.turn_id),
                ) {
                    self.apply_item_update(key, item);
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
                    let mut snapshot = self.write_snapshot();
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
                runtime_kind,
                notification,
            } => {
                let rate_limits = notification.rate_limits.clone().into();
                self.update_server_rate_limits(server_id, runtime_kind.clone(), Some(rate_limits));
            }
            UiEvent::ConnectionStateChanged { server_id, health } => {
                {
                    let mut snapshot = self.write_snapshot();
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
                    let mut snapshot = self.write_snapshot();
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
                    if let VoiceDerivedUpdate::Transcript(update) = update {
                        self.apply_voice_transcript_update(key, &update);
                        self.emit(AppStoreUpdateRecord::RealtimeTranscriptUpdated {
                            key: key.clone(),
                            update,
                        });
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
                                    self.write_snapshot();
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
                                    self.write_snapshot();
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
                    let mut snapshot = self.write_snapshot();
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
                    let mut snapshot = self.write_snapshot();
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
                    let mut snapshot = self.write_snapshot();
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
            UiEvent::UserInputRequested { request, seed } => {
                let requests = {
                    let mut snapshot = self.write_snapshot();
                    snapshot
                        .pending_user_inputs
                        .retain(|existing| existing.id != request.id);
                    snapshot.pending_user_inputs.push(request.clone());
                    let key = PendingUserInputKey {
                        server_id: request.server_id.clone(),
                        request_id: request.id.clone(),
                    };
                    if let Some(seed) = seed {
                        snapshot.pending_user_input_seeds.insert(key, seed.clone());
                    } else {
                        snapshot.pending_user_input_seeds.remove(&key);
                    }
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
            let mut snapshot = self.write_snapshot();
            let pending_local_studio_route = self
                .pending_local_studio_thread_routes
                .write()
                .expect("pending Local Studio route lock poisoned")
                .remove(&key);
            let inserted = !snapshot.threads.contains_key(&key);
            let thread = snapshot
                .threads
                .entry(key.clone())
                .or_insert_with(|| ThreadSnapshot::from_info(&key.server_id, info.clone()));
            if pending_local_studio_route {
                thread.agent_runtime_kind = "local-studio".to_string();
            }
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
        let mut snapshot = self.write_snapshot();
        let thread = snapshot.threads.get_mut(key)?;
        Some(mutate(thread))
    }

    pub(crate) fn apply_thread_goal(&self, key: &ThreadKey, goal: AppThreadGoal) {
        if self
            .mutate_thread_with_result(key, |thread| {
                thread.goal = Some(goal);
            })
            .is_some()
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub(crate) fn clear_thread_goal(&self, key: &ThreadKey) {
        if self
            .mutate_thread_with_result(key, |thread| {
                thread.goal = None;
            })
            .is_some()
        {
            self.emit_thread_metadata_changed(key);
        }
    }

    pub(crate) fn emit_thread_metadata_changed(&self, key: &ThreadKey) {
        let update = {
            let snapshot = self.snapshot.read().expect("app store lock poisoned");
            let version = self.agent_directory_version(&snapshot);
            match project_thread_state_update(&snapshot, key, version) {
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
        // Nested by thread so clearing one thread costs O(items in that
        // thread) rather than O(items across every thread ever emitted).
        self.last_thread_item_upserts
            .write()
            .expect("thread item cache lock poisoned")
            .remove(key);
    }

    pub(crate) fn emit_thread_upsert(&self, key: &ThreadKey) {
        self.clear_thread_update_caches(key);
        let update = {
            let snapshot = self.snapshot.read().expect("app store lock poisoned");
            let version = self.agent_directory_version(&snapshot);
            match project_thread_update(&snapshot, key, version) {
                Ok(Some((thread, session_summary, agent_directory_version))) => {
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
            project_hydrated_item(&snapshot, &key.server_id, &item).into_owned()
        };
        let fingerprint = item_fingerprint(&item);
        {
            let mut cache = self
                .last_thread_item_upserts
                .write()
                .expect("thread item cache lock poisoned");
            let thread_cache = cache.entry(key.clone()).or_default();
            if thread_cache.get(&item.id) == Some(&fingerprint) {
                return;
            }
            thread_cache.insert(item.id.clone(), fingerprint);
        }
        let session_summary = self.compute_session_summary(key);
        self.emit(AppStoreUpdateRecord::ThreadItemChanged {
            key: key.clone(),
            item,
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
                .and_then(|thread| thread.items.get_by_id(item_id).cloned())
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
        let result = self.mutate_thread_with_result(key, |thread| {
            let existing = thread.items.get_by_id(&item.id).cloned();
            let item = merge_reasoning_item_with_existing(existing.as_ref(), item);
            let active_turn_id = thread.active_turn_id.as_deref();
            let mut removed_overlay_ids = Vec::new();
            for existing in thread.local_overlay_items.iter() {
                if is_superseded_overlay_item(existing, &item, active_turn_id) {
                    removed_overlay_ids.push(existing.id.clone());
                }
            }
            if !removed_overlay_ids.is_empty() {
                thread.local_overlay_items.retain(|existing| {
                    !is_superseded_overlay_item(existing, &item, active_turn_id)
                });
            }
            let mutation = classify_item_mutation(existing.as_ref(), &item);
            upsert_item(thread, item);
            (mutation, false, removed_overlay_ids)
        });

        match result {
            Some((Some(ItemMutationUpdate::Upsert(item)), queued_changed, removed_overlay_ids)) => {
                if !removed_overlay_ids.is_empty() {
                    self.emit_thread_upsert(key);
                } else {
                    if queued_changed {
                        self.emit_thread_metadata_changed(key);
                    }
                    // Route through `emit_thread_item_changed` so multi-agent
                    // target ids get projected to display labels (e.g.
                    // "child-thread" → "Scout [explorer]"). The direct
                    // emission used to skip the projector, leaving raw
                    // thread ids in the wire-bound record.
                    self.emit_thread_item_changed(key, item);
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
        let mut snapshot = self.write_snapshot();
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
            AppStoreUpdateRecord::TerminalSessionsChanged => {
                tracing::debug!(target: "store", "emit TerminalSessionsChanged")
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

    /// Insert a new terminal session into the snapshot in
    /// [`AppTerminalSessionPhase::Running`] phase with an empty output
    /// tail. Caller is responsible for placing the live
    /// [`crate::terminal::TerminalSession`] handle on
    /// [`crate::MobileClient::terminal_sessions`].
    pub fn open_terminal_session_record(
        &self,
        id: String,
        backend_kind: TerminalBackendKind,
        cols: u16,
        rows: u16,
    ) {
        let mut snapshot = self.write_snapshot();
        snapshot.terminal_sessions.push(TerminalSessionSnapshot {
            id: id.clone(),
            backend_kind,
            phase: AppTerminalSessionPhase::Running,
            cols,
            rows,
            last_activity_ts_ms: now_ms(),
            output_tail: Vec::new(),
            exit_code: None,
        });
        // The first opened session becomes active by default; if the
        // caller wants a different one, they call `set_active_terminal_id`
        // after.
        if snapshot.active_terminal_id.is_none() {
            snapshot.active_terminal_id = Some(id);
        }
        drop(snapshot);
        let _ = self
            .updates_tx
            .send(AppStoreUpdateRecord::TerminalSessionsChanged);
    }

    /// Append output bytes to the session's ring buffer, capped at
    /// [`TERMINAL_OUTPUT_TAIL_LIMIT`]. Bumps `last_activity_ts_ms`. No-op
    /// if `id` is unknown.
    pub fn append_terminal_output(&self, id: &str, bytes: &[u8]) {
        let mut snapshot = self.write_snapshot();
        let Some(session) = snapshot.terminal_sessions.iter_mut().find(|s| s.id == id) else {
            return;
        };
        push_ring(&mut session.output_tail, bytes, TERMINAL_OUTPUT_TAIL_LIMIT);
        session.last_activity_ts_ms = now_ms();
        // Output bursts are noisy on the broadcast channel; only fire a
        // change update if this is the first byte of a session or if the
        // phase shifted. The renderer subscribes to the live session
        // directly for streaming bytes; broadcast is for non-byte state
        // changes only.
    }

    /// Update the session's row/col dimensions after a successful resize.
    pub fn update_terminal_size(&self, id: &str, cols: u16, rows: u16) {
        let mut snapshot = self.write_snapshot();
        if let Some(session) = snapshot.terminal_sessions.iter_mut().find(|s| s.id == id) {
            session.cols = cols;
            session.rows = rows;
            session.last_activity_ts_ms = now_ms();
        }
    }

    /// Mark the session as exited with the given code and clear it from
    /// being active.
    pub fn mark_terminal_exited(&self, id: &str, exit_code: i32) {
        let mut snapshot = self.write_snapshot();
        if let Some(session) = snapshot.terminal_sessions.iter_mut().find(|s| s.id == id) {
            session.phase = AppTerminalSessionPhase::Exited;
            session.exit_code = Some(exit_code);
            session.last_activity_ts_ms = now_ms();
        }
        if snapshot.active_terminal_id.as_deref() == Some(id) {
            snapshot.active_terminal_id = None;
        }
        drop(snapshot);
        let _ = self
            .updates_tx
            .send(AppStoreUpdateRecord::TerminalSessionsChanged);
    }

    /// Remove a session's snapshot entirely. Used after the caller has
    /// dropped the live session handle and no longer needs the buffered
    /// output (e.g. an explicit "close session and forget" path).
    pub fn remove_terminal_session_record(&self, id: &str) {
        let mut snapshot = self.write_snapshot();
        snapshot.terminal_sessions.retain(|s| s.id != id);
        if snapshot.active_terminal_id.as_deref() == Some(id) {
            snapshot.active_terminal_id = snapshot.terminal_sessions.last().map(|s| s.id.clone());
        }
        drop(snapshot);
        let _ = self
            .updates_tx
            .send(AppStoreUpdateRecord::TerminalSessionsChanged);
    }

    /// Set the currently-focused terminal session id. The id must match
    /// an existing snapshot entry, otherwise active is cleared.
    pub fn set_active_terminal_id(&self, id: Option<String>) {
        let mut snapshot = self.write_snapshot();
        let next = id.filter(|candidate| {
            snapshot
                .terminal_sessions
                .iter()
                .any(|s| &s.id == candidate)
        });
        if snapshot.active_terminal_id == next {
            return;
        }
        snapshot.active_terminal_id = next;
        drop(snapshot);
        let _ = self
            .updates_tx
            .send(AppStoreUpdateRecord::TerminalSessionsChanged);
    }

    /// Take a snapshot of a single terminal session. Cheap clone of the
    /// stored entry; safe to call on hot paths.
    pub fn terminal_session_snapshot(&self, id: &str) -> Option<TerminalSessionSnapshot> {
        let snapshot = self.snapshot.read().expect("app store lock poisoned");
        snapshot
            .terminal_sessions
            .iter()
            .find(|s| s.id == id)
            .cloned()
    }
}

/// Maximum bytes of output we keep per session for re-attach repaint.
/// 64 KiB matches the size budgeted in the plan; on a 100x40 grid that's
/// roughly 16 full screenfuls — enough to cover quick navigations and
/// app backgrounding without permanently retaining megabytes of logs.
pub const TERMINAL_OUTPUT_TAIL_LIMIT: usize = 64 * 1024;

/// Append `bytes` to `buf`, capping the result at `limit` by dropping
/// from the front. Designed for the per-session output tail.
fn push_ring(buf: &mut Vec<u8>, bytes: &[u8], limit: usize) {
    if bytes.is_empty() {
        return;
    }
    // Fast path: incoming chunk is itself larger than the limit; keep
    // only its tail and replace the buffer.
    if bytes.len() >= limit {
        let start = bytes.len() - limit;
        buf.clear();
        buf.extend_from_slice(&bytes[start..]);
        return;
    }
    // Compact only if needed.
    let combined = buf.len() + bytes.len();
    if combined > limit {
        let drop_n = combined - limit;
        buf.drain(..drop_n);
    }
    buf.extend_from_slice(bytes);
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn upsert_item(
    thread: &mut ThreadSnapshot,
    item: crate::conversation_uniffi::HydratedConversationItem,
) {
    match thread.items.index_of(&item.id) {
        Some(index) => thread.items.replace_at(index, item),
        None => thread.items.push(item),
    }
}

fn merge_reasoning_item_with_existing(
    existing: Option<&HydratedConversationItem>,
    mut item: HydratedConversationItem,
) -> HydratedConversationItem {
    let Some(existing) = existing else {
        return item;
    };
    let (
        HydratedConversationItemContent::Reasoning(existing_reasoning),
        HydratedConversationItemContent::Reasoning(incoming_reasoning),
    ) = (&existing.content, &mut item.content)
    else {
        return item;
    };

    if incoming_reasoning
        .summary
        .iter()
        .all(|part| part.trim().is_empty())
        && incoming_reasoning
            .content
            .iter()
            .all(|part| part.trim().is_empty())
        && existing_reasoning
            .summary
            .iter()
            .chain(existing_reasoning.content.iter())
            .any(|part| !part.trim().is_empty())
    {
        incoming_reasoning.summary = existing_reasoning.summary.clone();
        incoming_reasoning.content = existing_reasoning.content.clone();
    }

    item
}

fn append_assistant_delta(thread: &mut ThreadSnapshot, item_id: &str, delta: &str) -> bool {
    let mut inserted_placeholder = false;
    if !thread.items.contains_id(item_id) {
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

    let Some(item) = thread.items.get_mut_by_id(item_id) else {
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
    match thread.items.index_of(item_id) {
        Some(index) => {
            let item = thread
                .items
                .get_mut(index)
                .expect("index_of returned an in-bounds index");
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
    match thread.items.index_of(item_id) {
        Some(index) => {
            let item = thread
                .items
                .get_mut(index)
                .expect("index_of returned an in-bounds index");
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
    match thread.items.index_of(item_id) {
        Some(index) => {
            let item = thread
                .items
                .get_mut(index)
                .expect("index_of returned an in-bounds index");
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
    match thread.items.index_of(item_id) {
        Some(index) => {
            let item = thread
                .items
                .get_mut(index)
                .expect("index_of returned an in-bounds index");
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
                let trimmed = visible_user_text(text);
                if !trimmed.is_empty() {
                    text_parts.push(trimmed);
                }
            }
            upstream::UserInput::Image { url, .. } => images.push(url.clone()),
            upstream::UserInput::LocalImage { path, .. } => {
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

fn visible_user_text(text: &str) -> String {
    let trimmed = text.trim();
    if !trimmed.starts_with(DESKTOP_FILE_CONTEXT_HEADER) {
        return trimmed.to_string();
    }
    let Some((file_context, request)) = trimmed.split_once(DESKTOP_FILE_CONTEXT_REQUEST_HEADER)
    else {
        return trimmed.to_string();
    };
    let request = request.trim();
    if !request.is_empty() {
        return request.to_string();
    }
    file_context_summary(file_context).unwrap_or_else(|| trimmed.to_string())
}

fn file_context_summary(file_context: &str) -> Option<String> {
    let labels: Vec<String> = file_context
        .lines()
        .filter_map(|line| line.trim().strip_prefix("## "))
        .map(|line| line.split_once(':').map(|(label, _)| label).unwrap_or(line))
        .map(str::trim)
        .filter(|label| !label.is_empty())
        .map(|label| format!("[File] {label}"))
        .collect();
    if labels.is_empty() {
        None
    } else {
        Some(labels.join("\n"))
    }
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

fn preserve_live_tool_items(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    let incoming_ids: HashSet<&str> = target.items.iter().map(|item| item.id.as_str()).collect();
    let missing = source
        .items
        .iter()
        .enumerate()
        .filter(|item| {
            item.1.source_turn_id.is_none()
                && is_tool_item(&item.1.content)
                && !incoming_ids.contains(item.1.id.as_str())
        })
        .map(|(index, item)| (index, item.clone()))
        .collect::<Vec<_>>();
    for (source_index, item) in missing {
        let next_anchor = source.items[source_index + 1..]
            .iter()
            .find_map(replay_anchor_key);
        let insertion_index = next_anchor
            .as_ref()
            .and_then(|anchor| {
                target
                    .items
                    .iter()
                    .position(|candidate| replay_anchor_key(candidate).as_ref() == Some(anchor))
            })
            .or_else(|| {
                target.items.iter().rposition(|candidate| {
                    matches!(
                        candidate.content,
                        HydratedConversationItemContent::Assistant(ref data)
                            if data.phase == Some(crate::types::AppMessagePhase::FinalAnswer)
                    )
                })
            })
            .unwrap_or(target.items.len());
        target.items.insert(insertion_index, item);
    }
}

fn replay_anchor_key(item: &HydratedConversationItem) -> Option<String> {
    match &item.content {
        HydratedConversationItemContent::User(data) => Some(format!(
            "user:{}:{}",
            data.text,
            serde_json::to_string(&data.image_data_uris).unwrap_or_default()
        )),
        HydratedConversationItemContent::Assistant(data) => {
            Some(format!("assistant:{}:{:?}", data.text, data.phase))
        }
        _ => None,
    }
}

fn is_tool_item(content: &HydratedConversationItemContent) -> bool {
    matches!(
        content,
        HydratedConversationItemContent::CommandExecution(_)
            | HydratedConversationItemContent::FileChange(_)
            | HydratedConversationItemContent::McpToolCall(_)
            | HydratedConversationItemContent::DynamicToolCall(_)
            | HydratedConversationItemContent::MultiAgentAction(_)
            | HydratedConversationItemContent::WebSearch(_)
            | HydratedConversationItemContent::ImageView(_)
            | HydratedConversationItemContent::Widget(_)
            | HydratedConversationItemContent::ImageGeneration(_)
    )
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

/// Fork lineage and sub-agent parent are immutable for the lifetime of a
/// thread — once known, they don't change. Older `thread/list` responses
/// (and some upstream snapshot paths) omit them, so without this guard a
/// later list-page upsert silently wipes a fork relationship learned via
/// an earlier `thread/read`. Mirrors `preserve_thread_title`.
fn preserve_thread_fork_lineage(existing: &ThreadInfo, incoming: &mut ThreadInfo) {
    let is_blank = |value: &Option<String>| -> bool {
        value.as_deref().map(str::trim).is_none_or(str::is_empty)
    };
    if is_blank(&incoming.forked_from_id) && !is_blank(&existing.forked_from_id) {
        incoming.forked_from_id = existing.forked_from_id.clone();
    }
    if is_blank(&incoming.parent_thread_id) && !is_blank(&existing.parent_thread_id) {
        incoming.parent_thread_id = existing.parent_thread_id.clone();
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
            forked_from_id: None,
            agent_status: None,
            created_at: None,
            updated_at: None,
        }
    }


    // ── Derived-state cache invalidation ──────────────────────────────
    //
    // These cover the memoization introduced for the agent-directory
    // version, the per-thread conversation-activity walk, and the
    // per-thread item-fingerprint cache. Each one trades a recomputation
    // for a staleness risk, so the invalidation paths are pinned here.

    fn assistant_item_named(id: &str, text: &str) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: text.to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: Some(0),
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    /// The memoized agent-directory version must be dropped whenever the
    /// snapshot is written, so a directory-visible change is never masked
    /// by a stale memo.
    #[test]
    fn agent_directory_version_memo_is_invalidated_by_snapshot_writes() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };

        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-1"),
        ));
        let first = {
            let snapshot = reducer.snapshot.read().expect("snapshot");
            reducer.agent_directory_version(&snapshot)
        };
        // Repeat reads with no intervening write are served from the memo
        // and must agree.
        let repeated = {
            let snapshot = reducer.snapshot.read().expect("snapshot");
            reducer.agent_directory_version(&snapshot)
        };
        assert_eq!(first, repeated);

        // A directory-visible mutation (agent status) must move the version.
        reducer.mutate_thread(&key, |thread| {
            thread.info.agent_status = Some("running".to_string());
        });
        let after_status = {
            let snapshot = reducer.snapshot.read().expect("snapshot");
            reducer.agent_directory_version(&snapshot)
        };
        assert_ne!(first, after_status);

        // Adding a second thread must move it again.
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-2"),
        ));
        let after_insert = {
            let snapshot = reducer.snapshot.read().expect("snapshot");
            reducer.agent_directory_version(&snapshot)
        };
        assert_ne!(after_status, after_insert);

        // And removing it must return to the previous value: the version is
        // a pure function of the directory contents.
        reducer.remove_thread(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-2".to_string(),
        });
        let after_remove = {
            let snapshot = reducer.snapshot.read().expect("snapshot");
            reducer.agent_directory_version(&snapshot)
        };
        assert_eq!(after_status, after_remove);
    }

    /// The memoized conversation-activity walk must follow item mutations.
    #[test]
    fn conversation_activity_cache_follows_item_mutations() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info(
            "srv",
            make_thread_info("thread-1"),
        ));

        let summary = |reducer: &AppStoreReducer| -> AppSessionSummary {
            let snapshot = reducer.snapshot.read().expect("snapshot");
            let thread = snapshot.threads.get(&key).expect("thread");
            app_session_summary(thread, None)
        };

        let empty = summary(&reducer);
        assert_eq!(empty.last_response_preview, None);
        assert_eq!(empty.stats, None);
        // A second read hits the cache and must agree with the first.
        assert_eq!(summary(&reducer), empty);

        // Push.
        reducer.mutate_thread(&key, |thread| {
            thread.items.push(assistant_item_named("a-1", "first"));
        });
        let after_push = summary(&reducer);
        assert_eq!(after_push.last_response_preview.as_deref(), Some("first"));
        assert_eq!(
            after_push
                .stats
                .as_ref()
                .map(|stats| stats.assistant_message_count),
            Some(1)
        );

        // In-place edit through the id accessor.
        reducer.mutate_thread(&key, |thread| {
            let item = thread.items.get_mut_by_id("a-1").expect("item a-1");
            item.content =
                HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                    text: "edited".to_string(),
                    agent_nickname: None,
                    agent_role: None,
                    phase: None,
                });
        });
        assert_eq!(
            summary(&reducer).last_response_preview.as_deref(),
            Some("edited")
        );

        // Wholesale replacement of the list.
        reducer.mutate_thread(&key, |thread| {
            thread.items = vec![assistant_item_named("a-2", "replaced")].into();
        });
        assert_eq!(
            summary(&reducer).last_response_preview.as_deref(),
            Some("replaced")
        );

        // Retain that empties the list.
        reducer.mutate_thread(&key, |thread| {
            thread.items.retain(|_| false);
        });
        let emptied = summary(&reducer);
        assert_eq!(emptied.last_response_preview, None);
        assert_eq!(emptied.stats, None);
    }

    /// The overlay-merged activity cache is keyed on *both* lists.
    #[test]
    fn conversation_activity_cache_follows_overlay_mutations() {
        let mut snapshot = AppSnapshot::default();
        let mut thread = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));
        thread.items.push(assistant_item_named("a-1", "hello"));
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let stats = |snapshot: &AppSnapshot| -> crate::store::boundary::AppConversationStats {
            crate::store::boundary::app_thread_snapshot_from_state(
                snapshot,
                snapshot.threads.get(&key).expect("thread"),
            )
            .expect("projection")
            .stats
            .expect("stats")
        };

        let before = stats(&snapshot);
        assert_eq!(before.user_message_count, 0);
        assert_eq!(stats(&snapshot), before);

        snapshot
            .threads
            .get_mut(&key)
            .expect("thread")
            .local_overlay_items
            .push(HydratedConversationItem {
                id: "local-user-message:1".to_string(),
                content: HydratedConversationItemContent::User(HydratedUserMessageData {
                    text: "hi".to_string(),
                    image_data_uris: Vec::new(),
                }),
                source_turn_id: Some("turn-2".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });

        assert_eq!(stats(&snapshot).user_message_count, 1);
    }

    /// Clearing one thread's item-fingerprint cache must not clear another
    /// thread's — the map is nested per thread precisely so that a thread
    /// upsert stays O(items in that thread).
    #[test]
    fn thread_item_fingerprint_cache_clears_only_the_named_thread() {
        let reducer = AppStoreReducer::new();
        for id in ["thread-1", "thread-2"] {
            reducer.upsert_thread_snapshot(ThreadSnapshot::from_info("srv", make_thread_info(id)));
        }
        let key_one = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let key_two = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-2".to_string(),
        };

        let mut receiver = reducer.subscribe();
        reducer.emit_thread_item_changed(&key_one, assistant_item_named("shared", "text"));
        reducer.emit_thread_item_changed(&key_two, assistant_item_named("shared", "text"));
        assert_eq!(
            drain_updates(&mut receiver)
                .iter()
                .filter(|update| matches!(update, AppStoreUpdateRecord::ThreadItemChanged { .. }))
                .count(),
            2
        );

        // Identical re-emits are deduped for both threads.
        reducer.emit_thread_item_changed(&key_one, assistant_item_named("shared", "text"));
        reducer.emit_thread_item_changed(&key_two, assistant_item_named("shared", "text"));
        assert_eq!(
            drain_updates(&mut receiver)
                .iter()
                .filter(|update| matches!(update, AppStoreUpdateRecord::ThreadItemChanged { .. }))
                .count(),
            0
        );

        // Upserting thread-1 clears only thread-1's fingerprints.
        reducer.clear_thread_update_caches(&key_one);
        drain_updates(&mut receiver);
        reducer.emit_thread_item_changed(&key_one, assistant_item_named("shared", "text"));
        reducer.emit_thread_item_changed(&key_two, assistant_item_named("shared", "text"));
        let emitted = drain_updates(&mut receiver)
            .into_iter()
            .filter_map(|update| match update {
                AppStoreUpdateRecord::ThreadItemChanged { key, .. } => Some(key),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(emitted, vec![key_one]);
    }

    /// The bounded item fingerprint must still discriminate the changes the
    /// dedup cache exists to catch, including ones buried behind a large
    /// captured command output.
    #[test]
    fn item_fingerprint_detects_changes_behind_large_output() {
        let base = |output: &str, status: AppOperationStatus| HydratedConversationItem {
            id: "cmd-1".to_string(),
            content: HydratedConversationItemContent::CommandExecution(
                HydratedCommandExecutionData {
                    command: "make test".to_string(),
                    output: Some(output.to_string()),
                    status,
                    exit_code: None,
                    duration_ms: None,
                    process_id: None,
                    actions: Vec::new(),
                    cwd: "/tmp".to_string(),
                },
            ),
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: Some(0),
            timestamp: None,
            is_from_user_turn_boundary: false,
        };

        let big = "x".repeat(200_000);
        let running = base(&big, AppOperationStatus::InProgress);
        assert_eq!(item_fingerprint(&running), item_fingerprint(&running.clone()));

        // Status change after a huge output body: same length, different
        // value — this is what the retained tail window is for.
        let completed = base(&big, AppOperationStatus::Completed);
        assert_ne!(item_fingerprint(&running), item_fingerprint(&completed));

        // Appended output.
        let grown = base(&format!("{big}more"), AppOperationStatus::InProgress);
        assert_ne!(item_fingerprint(&running), item_fingerprint(&grown));

        // Change inside the head window.
        let mut renamed = running.clone();
        renamed.id = "cmd-2".to_string();
        assert_ne!(item_fingerprint(&running), item_fingerprint(&renamed));
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
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected);

        reducer.sync_thread_list_for_runtime(
            "srv",
            "pi".to_string(),
            &[make_thread_info("thread-1")],
        );

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        assert_eq!(
            reducer.thread_snapshot(&key).unwrap().agent_runtime_kind,
            "pi".to_string()
        );
    }

    #[test]
    fn pending_local_studio_route_labels_thread_created_by_async_event() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "alleycat:local-studio:controller".to_string(),
            thread_id: "thread-1".to_string(),
        };

        reducer.set_thread_agent_runtime(&key, "local-studio".to_string());
        reducer.upsert_or_merge_thread(key.clone(), make_thread_info("thread-1"), |_| {});

        assert_eq!(
            reducer.thread_snapshot(&key).unwrap().agent_runtime_kind,
            "local-studio"
        );
    }

    #[test]
    fn pending_thread_route_behavior_is_local_studio_only() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "alleycat:controller".to_string(),
            thread_id: "thread-1".to_string(),
        };

        reducer.set_thread_agent_runtime(&key, "pi".to_string());
        reducer.upsert_or_merge_thread(key.clone(), make_thread_info("thread-1"), |_| {});

        assert_eq!(
            reducer.thread_snapshot(&key).unwrap().agent_runtime_kind,
            "codex"
        );
    }

    #[test]
    fn destructive_sync_never_prunes_or_relabels_local_studio_threads() {
        let reducer = AppStoreReducer::new();
        for id in ["listed", "outside-page"] {
            let mut thread = ThreadSnapshot::from_info("srv", make_thread_info(id));
            thread.agent_runtime_kind = "local-studio".to_string();
            reducer.upsert_thread_snapshot(thread);
        }

        reducer.sync_thread_list("srv", &[make_thread_info("listed")]);

        let snapshot = reducer.snapshot();
        for id in ["listed", "outside-page"] {
            let key = ThreadKey {
                server_id: "srv".to_string(),
                thread_id: id.to_string(),
            };
            assert_eq!(
                snapshot.threads.get(&key).unwrap().agent_runtime_kind,
                "local-studio"
            );
        }
    }

    #[test]
    fn update_server_agent_runtimes_replaces_available_metadata() {
        let reducer = AppStoreReducer::new();
        let config = make_server_config("srv");
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected);

        reducer.update_server_agent_runtimes(
            "srv",
            vec![AgentRuntimeInfo {
                kind: "opencode".to_string(),
                name: "opencode".to_string(),
                display_name: "opencode".to_string(),
                available: true,
            }],
        );

        let snapshot = reducer.snapshot();
        let server = snapshot.servers.get("srv").unwrap();
        assert_eq!(server.agent_runtimes.len(), 1);
        assert_eq!(server.agent_runtimes[0].kind, "opencode".to_string());
    }

    #[test]
    fn failed_server_mutating_command_clears_pending_without_marking_success() {
        let reducer = AppStoreReducer::new();
        let config = make_server_config("srv");
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected);

        let request_id = reducer.begin_server_mutating_command(
            "srv",
            ServerMutatingCommandKind::ApprovalResponse,
            "thread",
        );
        assert_eq!(
            reducer.server_pending_mutation_kind("srv"),
            Some(ServerMutatingCommandKind::ApprovalResponse)
        );

        reducer.finish_server_mutating_command_failure("srv", &request_id);

        let snapshot = reducer.snapshot();
        let server = snapshot.servers.get("srv").expect("server exists");
        assert!(server.transport.pending_mutation.is_none());
        assert!(server.transport.last_direct_request_ok_at.is_none());
    }

    #[test]
    fn stale_server_mutating_failure_does_not_clear_newer_pending_command() {
        let reducer = AppStoreReducer::new();
        let config = make_server_config("srv");
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected);

        let stale_request_id = reducer.begin_server_mutating_command(
            "srv",
            ServerMutatingCommandKind::ApprovalResponse,
            "thread",
        );
        let active_request_id = reducer.begin_server_mutating_command(
            "srv",
            ServerMutatingCommandKind::UserInputResponse,
            "thread",
        );

        reducer.finish_server_mutating_command_failure("srv", &stale_request_id);

        let snapshot = reducer.snapshot();
        let pending = snapshot
            .servers
            .get("srv")
            .expect("server exists")
            .transport
            .pending_mutation
            .as_ref()
            .expect("newer pending command survives stale failure");
        assert_eq!(pending.local_request_id, active_request_id);
        assert_eq!(pending.kind, ServerMutatingCommandKind::UserInputResponse);
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

        reducer.upsert_server(&config, ServerHealthSnapshot::Connecting);
        reducer.update_server_wake_mac("srv", Some("aa:bb:cc:dd:ee:ff".to_string()));
        reducer.upsert_server(&config, ServerHealthSnapshot::Connected);

        let snapshot = reducer.snapshot();
        let server = snapshot.servers.get("srv").expect("server snapshot");
        assert_eq!(server.wake_mac.as_deref(), Some("aa:bb:cc:dd:ee:ff"));
    }

    #[test]
    fn sync_thread_list_preserves_recently_created_thread_not_in_incoming_page() {
        let reducer = AppStoreReducer::new();
        let fresh_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "fresh".to_string(),
        };
        let mut info = make_thread_info("fresh");
        info.created_at = Some((now_ms() / 1000) as i64);
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info("srv", info));

        // The incoming page does not include the just-created thread (e.g. a
        // brand-new OpenCode session is not yet returned by GET /session).
        reducer.sync_thread_list("srv", &[make_thread_info("other")]);

        let snapshot = reducer.snapshot();
        assert!(snapshot.threads.contains_key(&fresh_key));
        assert!(snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "other".to_string(),
        }));
    }

    #[test]
    fn sync_thread_list_evicts_old_inactive_thread_not_in_incoming_page() {
        let reducer = AppStoreReducer::new();
        let stale_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "stale".to_string(),
        };
        let mut info = make_thread_info("stale");
        info.created_at = Some((now_ms() / 1000) as i64 - 3600);
        reducer.upsert_thread_snapshot(ThreadSnapshot::from_info("srv", info));

        reducer.sync_thread_list("srv", &[make_thread_info("other")]);

        let snapshot = reducer.snapshot();
        assert!(!snapshot.threads.contains_key(&stale_key));
        assert!(snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "other".to_string(),
        }));
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
        reducer.upsert_thread_list_page("srv", std::slice::from_ref(&page_one));
        reducer.upsert_thread_list_page("srv", std::slice::from_ref(&page_two));
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
    fn completed_empty_reasoning_item_preserves_streamed_placeholder_content() {
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
            delta: "streamed reasoning".to_string(),
        });
        assert!(!drain_updates(&mut receiver).is_empty());

        reducer.apply_ui_event(&UiEvent::ItemCompleted {
            key: key.clone(),
            notification: upstream::ItemCompletedNotification {
                item: upstream::ThreadItem::Reasoning {
                    id: "reasoning-1".to_string(),
                    summary: Vec::new(),
                    content: Vec::new(),
                },
                thread_id: key.thread_id.clone(),
                turn_id: "turn-1".to_string(),
                completed_at_ms: 0,
            },
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        let item = thread
            .items
            .iter()
            .find(|item| item.id == "reasoning-1")
            .unwrap();
        match &item.content {
            HydratedConversationItemContent::Reasoning(data) => {
                assert_eq!(data.content, vec!["streamed reasoning".to_string()]);
            }
            other => panic!("expected reasoning item, got {other:?}"),
        }
    }

    #[test]
    fn thread_status_changed_idle_clears_active_turn() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let mut thread = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        thread.active_turn_id = Some("turn-1".to_string());
        thread.info.status = ThreadSummaryStatus::Active;
        reducer.upsert_thread_snapshot(thread);
        let mut receiver = reducer.subscribe();
        assert!(drain_updates(&mut receiver).is_empty());

        reducer.apply_ui_event(&UiEvent::ThreadStatusChanged {
            key: key.clone(),
            notification: upstream::ThreadStatusChangedNotification {
                thread_id: key.thread_id.clone(),
                status: upstream::ThreadStatus::Idle,
            },
        });

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert_eq!(thread.active_turn_id, None);
        assert_eq!(thread.info.status, ThreadSummaryStatus::Idle);

        let updates = drain_updates(&mut receiver);
        assert!(updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadMetadataChanged { state, .. }
                if state.key == key
                    && state.active_turn_id.is_none()
                    && state.info.status == ThreadSummaryStatus::Idle
        )));
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
            session_id: "session-1".to_string(),
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
            thread_source: None,
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
                items_view: upstream::TurnItemsView::Full,
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
    fn upsert_thread_snapshot_preserves_live_tool_omitted_from_replay() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let item = |id: &str, content: HydratedConversationItemContent| {
            HydratedConversationItem {
                id: id.to_string(),
                content,
                source_turn_id: None,
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            }
        };
        let mut live = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        live.items.push(item(
            "tool",
            HydratedConversationItemContent::CommandExecution(HydratedCommandExecutionData {
                command: "create image".to_string(),
                cwd: "/tmp".to_string(),
                status: AppOperationStatus::Completed,
                output: Some("done".to_string()),
                exit_code: Some(0),
                duration_ms: Some(1),
                process_id: None,
                actions: Vec::new(),
            }),
        ));
        reducer.upsert_thread_snapshot(live);

        let mut replay = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        replay.items.push(item(
            "final",
            HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: "![image](/tmp/image.png)".to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: Some(crate::types::AppMessagePhase::FinalAnswer),
            }),
        ));
        reducer.upsert_thread_snapshot(replay);

        let thread = reducer
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("thread exists");
        assert_eq!(
            thread
                .items
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec!["tool", "final"]
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
    fn claimed_follow_up_is_not_double_consumed_by_turn_events() {
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

        let claimed = reducer
            .claim_first_queued_follow_up_draft(&key)
            .expect("first draft claimed before request");
        assert_eq!(claimed.preview.id, "queued-1");

        reducer.apply_ui_event(&UiEvent::TurnStarted {
            key: key.clone(),
            turn_id: "turn-2".to_string(),
        });
        reducer.apply_item_update(
            &key,
            HydratedConversationItem {
                id: "user-1".to_string(),
                content: HydratedConversationItemContent::User(HydratedUserMessageData {
                    text: "first".to_string(),
                    image_data_uris: Vec::new(),
                }),
                source_turn_id: Some("turn-2".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            },
        );

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
    fn turn_started_binding_local_user_overlay_emits_thread_upsert_for_reprojection() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let mut thread = ThreadSnapshot::from_info("srv", make_thread_info("thread"));
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "assistant-1".to_string(),
                content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                    text: "response".to_string(),
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
        let overlay_id = reducer
            .stage_local_user_message_overlay(
                &key,
                &[upstream::UserInput::Text {
                    text: "prompt".to_string(),
                    text_elements: Vec::new(),
                }],
            )
            .expect("overlay id");

        let mut receiver = reducer.subscribe();
        let _ = drain_updates(&mut receiver);

        reducer.bind_local_user_message_overlay_to_turn(&key, &overlay_id, "turn-1");

        let updates = drain_updates(&mut receiver);
        assert!(
            updates.iter().any(
                |update| matches!(update, AppStoreUpdateRecord::ThreadUpserted { thread, .. }
                    if thread.key == key
                        && thread
                            .hydrated_conversation_items
                            .iter()
                            .map(|item| item.id.as_str())
                            .collect::<Vec<_>>()
                            == vec![overlay_id.as_str(), "assistant-1"])
            ),
            "binding a local user overlay must emit a reprojected thread upsert; got {updates:?}"
        );
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
        ].into();
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
        ].into();

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
        }].into();
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
        }].into();

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
    fn failed_follow_up_claim_restores_original_queue_order() {
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
        reducer.enqueue_thread_follow_up_preview(
            &key,
            AppQueuedFollowUpPreview {
                id: "queued-2".to_string(),
                kind: crate::store::snapshot::AppQueuedFollowUpKind::Message,
                text: "second follow-up".to_string(),
            },
        );

        let claimed = reducer
            .claim_first_queued_follow_up_draft(&key)
            .expect("first draft claimed");
        reducer.restore_queued_follow_up_draft_front(&key, claimed);

        let snapshot = reducer.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread exists");
        assert_eq!(
            thread
                .queued_follow_ups
                .iter()
                .map(|preview| preview.id.as_str())
                .collect::<Vec<_>>(),
            vec!["queued-1", "queued-2"]
        );
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
                completed_at_ms: 0,
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
        return Some(ItemMutationUpdate::Upsert(item.clone()));
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
                return Some(ItemMutationUpdate::Upsert(item.clone()));
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
                Some(ItemMutationUpdate::Upsert(item.clone()))
            }
        }
        _ if existing.content == item.content => None,
        _ => Some(ItemMutationUpdate::Upsert(item.clone())),
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
