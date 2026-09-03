use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use codex_app_server_protocol as upstream;

use crate::conversation_uniffi::HydratedConversationItem;
use crate::types::{
    Account, AgentRuntimeInfo, AgentRuntimeKind, AppModeKind, AppPlanProgressSnapshot, ModelInfo,
    PendingApproval, PendingApprovalKey, PendingApprovalSeed, PendingUserInputKey,
    PendingUserInputRequest, PendingUserInputSeed, RateLimitSnapshot, RateLimits, ThreadInfo,
    ThreadKey,
};
use crate::types::{AppThreadGoal, AppVoiceSessionPhase, AppVoiceTranscriptEntry};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppConnectionStepKind {
    ConnectingToSsh,
    FindingCodex,
    InstallingCodex,
    StartingAppServer,
    OpeningTunnel,
    Connected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppConnectionStepState {
    Pending,
    InProgress,
    Completed,
    Failed,
    AwaitingUserInput,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppConnectionStepSnapshot {
    pub kind: AppConnectionStepKind,
    pub state: AppConnectionStepState,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppConnectionProgressSnapshot {
    pub steps: Vec<AppConnectionStepSnapshot>,
    pub pending_install: bool,
    pub terminal_message: Option<String>,
}

impl AppConnectionProgressSnapshot {
    pub fn ssh_bootstrap() -> Self {
        Self {
            steps: vec![
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::ConnectingToSsh,
                    state: AppConnectionStepState::InProgress,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::FindingCodex,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::InstallingCodex,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::StartingAppServer,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::OpeningTunnel,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::Connected,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
            ],
            pending_install: false,
            terminal_message: None,
        }
    }

    pub fn update_step(
        &mut self,
        kind: AppConnectionStepKind,
        state: AppConnectionStepState,
        detail: Option<String>,
    ) {
        if let Some(step) = self.steps.iter_mut().find(|step| step.kind == kind) {
            step.state = state;
            step.detail = detail;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerHealthSnapshot {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown(String),
}

impl ServerHealthSnapshot {
    pub fn from_wire(health: &str) -> Self {
        match health {
            "disconnected" => Self::Disconnected,
            "connecting" => Self::Connecting,
            "connected" => Self::Connected,
            "unresponsive" => Self::Unresponsive,
            other => Self::Unknown(other.to_string()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppLifecyclePhaseSnapshot {
    Active,
    Inactive,
    Background,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerMutatingCommandKind {
    StartTurn,
    SetQueuedFollowUpsState,
    SteerQueuedFollowUp,
    DeleteQueuedFollowUp,
    ApprovalResponse,
    UserInputResponse,
    CollaborationModeSync,
}

#[derive(Debug, Clone)]
pub struct PendingServerMutatingCommand {
    pub kind: ServerMutatingCommandKind,
    pub thread_id: String,
    pub local_request_id: String,
    pub started_at: Instant,
    pub lifecycle_phase_at_send: AppLifecyclePhaseSnapshot,
}

#[derive(Debug, Clone)]
pub struct ServerTransportDiagnostics {
    pub last_direct_request_ok_at: Option<Instant>,
    pub last_lifecycle_phase: AppLifecyclePhaseSnapshot,
    pub last_lifecycle_transition_at: Option<Instant>,
    pub last_resumed_at: Option<Instant>,
    pub pending_mutation: Option<PendingServerMutatingCommand>,
}

impl Default for ServerTransportDiagnostics {
    fn default() -> Self {
        Self {
            last_direct_request_ok_at: None,
            last_lifecycle_phase: AppLifecyclePhaseSnapshot::Active,
            last_lifecycle_transition_at: None,
            last_resumed_at: None,
            pending_mutation: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServerSnapshot {
    pub server_id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub wake_mac: Option<String>,
    pub is_local: bool,
    pub health: ServerHealthSnapshot,
    pub account: Option<Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<RateLimitSnapshot>,
    pub rate_limits_by_runtime: HashMap<AgentRuntimeKind, RateLimitSnapshot>,
    pub available_models: Option<Vec<ModelInfo>>,
    pub agent_runtimes: Vec<AgentRuntimeInfo>,
    pub connection_progress: Option<AppConnectionProgressSnapshot>,
    pub transport: ServerTransportDiagnostics,
    /// Whether the remote supports `thread/turns/list` + `exclude_turns`.
    /// Defaults to `true` and flips to `false` at runtime if a paginated RPC
    /// comes back as method-not-found or with the legacy embedded-turn shape.
    pub supports_turn_pagination: bool,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct AppVoiceSessionSnapshot {
    pub active_thread: Option<ThreadKey>,
    pub session_id: Option<String>,
    pub phase: Option<AppVoiceSessionPhase>,
    pub last_error: Option<String>,
    pub transcript_entries: Vec<AppVoiceTranscriptEntry>,
    pub handoff_thread_key: Option<ThreadKey>,
}

/// Process-wide monotonic counter handing out `ThreadItems` revisions.
///
/// Revisions are never reused, so a cache keyed on a revision stays correct
/// even when a whole `ThreadItems` value is replaced wholesale (the
/// replacement necessarily carries a revision the cache has never seen).
static THREAD_ITEMS_REVISION: AtomicU64 = AtomicU64::new(1);

fn next_items_revision() -> u64 {
    THREAD_ITEMS_REVISION.fetch_add(1, Ordering::Relaxed)
}

/// Ordered conversation-item list with an `id -> index` map kept in sync by
/// construction.
///
/// Item lookup by id used to be a linear scan over the whole thread, which
/// runs once per streaming token (`append_*_delta`, `upsert_item`,
/// reconciliation). Every mutating entry point here maintains `index` and
/// bumps `revision`; read access goes through `Deref<Target = [_]>` so the
/// invariant cannot be broken from outside this module.
///
/// `revision` is globally unique and monotonic. Derived state computed from
/// the list (see `boundary::ThreadActivityCache`) keys on it for
/// invalidation.
#[derive(Clone)]
pub struct ThreadItems {
    items: Vec<HydratedConversationItem>,
    /// First index at which each id occurs, mirroring the `iter().position()`
    /// / `iter().find()` semantics the linear scans had.
    index: HashMap<String, usize>,
    revision: u64,
}

impl ThreadItems {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            index: HashMap::new(),
            revision: next_items_revision(),
        }
    }

    /// Monotonic, globally unique stamp that changes on every mutation.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn as_slice(&self) -> &[HydratedConversationItem] {
        &self.items
    }

    /// O(1) replacement for `items.iter().position(|item| item.id == id)`.
    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.index.get(id).copied()
    }

    /// O(1) replacement for `items.iter().find(|item| item.id == id)`.
    pub fn get_by_id(&self, id: &str) -> Option<&HydratedConversationItem> {
        self.index_of(id).map(|index| &self.items[index])
    }

    pub fn contains_id(&self, id: &str) -> bool {
        self.index.contains_key(id)
    }

    /// Mutable access by id. The caller must not change `item.id`; use
    /// [`Self::replace_at`] for that.
    pub fn get_mut_by_id(&mut self, id: &str) -> Option<&mut HydratedConversationItem> {
        let index = self.index_of(id)?;
        self.revision = next_items_revision();
        self.items.get_mut(index)
    }

    /// Mutable access by position. The caller must not change `item.id`; use
    /// [`Self::replace_at`] for that.
    pub fn get_mut(&mut self, index: usize) -> Option<&mut HydratedConversationItem> {
        if index >= self.items.len() {
            return None;
        }
        self.revision = next_items_revision();
        self.items.get_mut(index)
    }

    pub fn push(&mut self, item: HydratedConversationItem) {
        self.revision = next_items_revision();
        self.index.entry(item.id.clone()).or_insert(self.items.len());
        self.items.push(item);
    }

    pub fn insert(&mut self, index: usize, item: HydratedConversationItem) {
        self.revision = next_items_revision();
        self.items.insert(index, item);
        self.rebuild_index();
    }

    /// Replace the item at `index` outright, allowing the id to change.
    pub fn replace_at(&mut self, index: usize, item: HydratedConversationItem) {
        self.revision = next_items_revision();
        let id_changed = self.items[index].id != item.id;
        self.items[index] = item;
        if id_changed {
            self.rebuild_index();
        }
    }

    pub fn retain<F>(&mut self, predicate: F)
    where
        F: FnMut(&HydratedConversationItem) -> bool,
    {
        self.revision = next_items_revision();
        self.items.retain(predicate);
        self.rebuild_index();
    }

    pub fn clear(&mut self) {
        self.revision = next_items_revision();
        self.items.clear();
        self.index.clear();
    }

    pub fn into_vec(self) -> Vec<HydratedConversationItem> {
        self.items
    }

    fn rebuild_index(&mut self) {
        self.index.clear();
        self.index.reserve(self.items.len());
        for (position, item) in self.items.iter().enumerate() {
            self.index.entry(item.id.clone()).or_insert(position);
        }
    }
}

impl Default for ThreadItems {
    fn default() -> Self {
        Self::new()
    }
}

impl std::ops::Deref for ThreadItems {
    type Target = [HydratedConversationItem];

    fn deref(&self) -> &Self::Target {
        &self.items
    }
}

impl std::fmt::Debug for ThreadItems {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.items.fmt(formatter)
    }
}

impl From<Vec<HydratedConversationItem>> for ThreadItems {
    fn from(items: Vec<HydratedConversationItem>) -> Self {
        let mut value = Self {
            items,
            index: HashMap::new(),
            revision: next_items_revision(),
        };
        value.rebuild_index();
        value
    }
}

impl FromIterator<HydratedConversationItem> for ThreadItems {
    fn from_iter<I: IntoIterator<Item = HydratedConversationItem>>(iter: I) -> Self {
        Self::from(iter.into_iter().collect::<Vec<_>>())
    }
}

impl Extend<HydratedConversationItem> for ThreadItems {
    fn extend<I: IntoIterator<Item = HydratedConversationItem>>(&mut self, iter: I) {
        self.revision = next_items_revision();
        for item in iter {
            self.index.entry(item.id.clone()).or_insert(self.items.len());
            self.items.push(item);
        }
    }
}

impl<'a> IntoIterator for &'a ThreadItems {
    type Item = &'a HydratedConversationItem;
    type IntoIter = std::slice::Iter<'a, HydratedConversationItem>;

    fn into_iter(self) -> Self::IntoIter {
        self.items.iter()
    }
}

#[derive(Debug, Clone)]
pub struct ThreadSnapshot {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub agent_runtime_kind: AgentRuntimeKind,
    pub collaboration_mode: AppModeKind,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub effective_approval_policy: Option<crate::types::AppAskForApproval>,
    pub effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    pub items: ThreadItems,
    pub local_overlay_items: ThreadItems,
    /// Memoized `extract_conversation_activity` output for this thread,
    /// invalidated by `items` / `local_overlay_items` revisions. Purely
    /// derived state; never part of equality or the wire projection.
    pub(crate) activity_cache: super::boundary::ThreadActivityCache,
    pub queued_follow_ups: Vec<AppQueuedFollowUpPreview>,
    pub(crate) queued_follow_up_drafts: Vec<QueuedFollowUpDraft>,
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<RateLimits>,
    pub realtime_session_id: Option<String>,
    pub goal: Option<AppThreadGoal>,
    pub active_plan_progress: Option<AppPlanProgressSnapshot>,
    pub(crate) pending_plan_implementation_turn_id: Option<String>,
    /// Paginated-turns cursor pointing at the next older page, per
    /// `thread/turns/list` semantics with `sort_direction: Desc`.
    /// `None` means no more older turns on the server OR pagination is not
    /// yet loaded.
    pub older_turns_cursor: Option<String>,
    /// Whether this thread's first page of turns has been loaded into
    /// `items` (either from embedded resume/fork turns on a legacy server,
    /// or from an explicit `thread/turns/list` call on a paginated server).
    /// Gates the UI spinner when a thread is opened with `exclude_turns`.
    pub initial_turns_loaded: bool,
    /// Whether this mobile client has resumed the thread and attached a live
    /// listener during the current store lifetime.
    pub is_resumed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppQueuedFollowUpPreview {
    pub id: String,
    pub kind: AppQueuedFollowUpKind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppQueuedFollowUpKind {
    Message,
    PendingSteer,
    RetryingSteer,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct QueuedFollowUpDraft {
    pub preview: AppQueuedFollowUpPreview,
    pub inputs: Vec<upstream::UserInput>,
    pub source_message_json: Option<serde_json::Value>,
}

impl ThreadSnapshot {
    pub fn from_info(server_id: &str, info: ThreadInfo) -> Self {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: info.id.clone(),
        };
        Self {
            key,
            agent_runtime_kind: "codex".to_string(),
            collaboration_mode: AppModeKind::Default,
            model: info.model.clone(),
            info,
            reasoning_effort: None,
            effective_approval_policy: None,
            effective_sandbox_policy: None,
            items: ThreadItems::new(),
            local_overlay_items: ThreadItems::new(),
            activity_cache: super::boundary::ThreadActivityCache::default(),
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
        }
    }
}

/// Cursor state for paged `thread/list` loading of a single (server, runtime)
/// pair, driven by the home sessions list. Mirrors
/// `ThreadSnapshot::older_turns_cursor` semantics for the session list.
/// Rust-only state; platforms read the aggregate `session_list_has_more`
/// projection on `AppServerSnapshot`.
#[derive(Debug, Clone, Default)]
pub struct SessionPageCursor {
    /// Opaque server cursor pointing at the next newer page. `None` means
    /// either this runtime has not been paged yet (first page) or no more
    /// sessions remain.
    pub cursor: Option<String>,
    /// Whether more sessions remain on this runtime. Set to `false` when the
    /// last page for a runtime returned no `next_cursor`, or when a full
    /// `thread/list` drain (refresh) completed for the server.
    pub has_more: bool,
}

#[derive(Debug, Clone, Default)]
pub struct AppSnapshot {
    pub servers: HashMap<String, ServerSnapshot>,
    pub threads: HashMap<ThreadKey, ThreadSnapshot>,
    /// Per-(server, runtime) cursors for paged session list loading.
    pub session_pages: HashMap<(String, AgentRuntimeKind), SessionPageCursor>,
    pub active_thread: Option<ThreadKey>,
    pub pending_approvals: Vec<PendingApproval>,
    pub(crate) pending_approval_seeds: HashMap<PendingApprovalKey, PendingApprovalSeed>,
    pub pending_user_inputs: Vec<PendingUserInputRequest>,
    pub(crate) pending_user_input_seeds: HashMap<PendingUserInputKey, PendingUserInputSeed>,
    pub voice_session: AppVoiceSessionSnapshot,
    /// Live terminal session snapshots, keyed by session id. Holds the
    /// ring-buffered output tail + lifecycle phase so renderers can
    /// re-attach after view teardown without losing scrollback. The
    /// strong [`crate::terminal::TerminalSession`] handles live on
    /// [`crate::MobileClient::terminal_sessions`]; this snapshot is the
    /// FFI-visible projection.
    pub terminal_sessions: Vec<TerminalSessionSnapshot>,
    /// Id of the currently-focused terminal session, if any. Drives the
    /// "Run in terminal" code-block action via
    /// [`crate::ffi::AppStore::write_to_active_terminal`].
    pub active_terminal_id: Option<String>,
}

/// Lifecycle phase of a terminal session as seen by the store. Maps
/// loosely to the platform-side `TerminalSessionController.Phase`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppTerminalSessionPhase {
    Connecting,
    Running,
    Exited,
    Failed,
}

/// Snapshot of a single terminal session held in the store.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalSessionSnapshot {
    pub id: String,
    pub backend_kind: crate::terminal::TerminalBackendKind,
    pub phase: AppTerminalSessionPhase,
    pub cols: u16,
    pub rows: u16,
    /// Wall-clock milliseconds since `UNIX_EPOCH` of the most recent
    /// activity (output byte or write). Stored as `u64` so the value
    /// crosses the UniFFI boundary without precision loss.
    pub last_activity_ts_ms: u64,
    /// Tail of the output byte stream, capped at 64 KiB (older bytes
    /// dropped as new ones arrive). Used to repaint scrollback when a
    /// renderer re-attaches after view teardown.
    pub output_tail: Vec<u8>,
    /// Exit code if the session has exited. `None` otherwise.
    pub exit_code: Option<i32>,
}

#[cfg(test)]
mod thread_items_tests {
    use super::{ThreadItems, next_items_revision};
    use crate::conversation_uniffi::{
        HydratedAssistantMessageData, HydratedConversationItem, HydratedConversationItemContent,
    };

    fn item(id: &str, text: &str) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: text.to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: None,
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    /// The id index must agree with the linear scan it replaced, for every
    /// mutation shape the store performs.
    fn assert_index_matches_scan(items: &ThreadItems) {
        for (position, entry) in items.iter().enumerate() {
            let expected = items
                .iter()
                .position(|candidate| candidate.id == entry.id)
                .expect("scan finds the item it just yielded");
            assert_eq!(
                items.index_of(&entry.id),
                Some(expected),
                "index disagrees with scan at position {position} for id {}",
                entry.id
            );
            assert!(items.contains_id(&entry.id));
        }
        assert_eq!(items.index_of("missing-id"), None);
        assert!(!items.contains_id("missing-id"));
    }

    #[test]
    fn index_tracks_push_insert_replace_retain_and_extend() {
        let mut items = ThreadItems::new();
        items.push(item("a", "1"));
        items.push(item("b", "2"));
        items.push(item("c", "3"));
        assert_index_matches_scan(&items);
        assert_eq!(items.index_of("b"), Some(1));

        items.insert(0, item("z", "0"));
        assert_index_matches_scan(&items);
        assert_eq!(items.index_of("z"), Some(0));
        assert_eq!(items.index_of("b"), Some(2));

        // Replacement that keeps the id must keep the same slot.
        items.replace_at(2, item("b", "2-updated"));
        assert_index_matches_scan(&items);
        assert_eq!(items.index_of("b"), Some(2));

        // Replacement that changes the id must retire the old one.
        items.replace_at(2, item("b2", "2-renamed"));
        assert_index_matches_scan(&items);
        assert_eq!(items.index_of("b"), None);
        assert_eq!(items.index_of("b2"), Some(2));

        items.retain(|entry| entry.id != "z");
        assert_index_matches_scan(&items);
        assert_eq!(items.index_of("a"), Some(0));

        items.extend(vec![item("d", "4"), item("e", "5")]);
        assert_index_matches_scan(&items);
        assert_eq!(items.index_of("e"), Some(items.len() - 1));

        items.clear();
        assert_index_matches_scan(&items);
        assert!(items.is_empty());
    }

    /// `iter().position()` / `iter().find()` resolve to the *first* match;
    /// the index must do the same when duplicate ids sneak in.
    #[test]
    fn index_resolves_duplicate_ids_to_the_first_occurrence() {
        let mut items = ThreadItems::new();
        items.push(item("dup", "first"));
        items.push(item("other", "x"));
        items.push(item("dup", "second"));
        assert_eq!(items.index_of("dup"), Some(0));
        assert_eq!(items.get_by_id("dup").map(|entry| entry.id.as_str()), Some("dup"));

        items.retain(|entry| entry.id != "other");
        assert_eq!(items.index_of("dup"), Some(0));
        assert_eq!(items.len(), 2);

        let from_vec = ThreadItems::from(vec![item("dup", "a"), item("dup", "b")]);
        assert_eq!(from_vec.index_of("dup"), Some(0));
    }

    #[test]
    fn revisions_are_unique_and_change_on_every_mutation() {
        let mut items = ThreadItems::new();
        let mut seen = vec![items.revision()];

        items.push(item("a", "1"));
        seen.push(items.revision());
        items.get_mut_by_id("a").expect("item a").source_turn_index = Some(1);
        seen.push(items.revision());
        items.get_mut(0).expect("item 0").timestamp = Some(1.0);
        seen.push(items.revision());
        items.replace_at(0, item("a", "2"));
        seen.push(items.revision());
        items.insert(0, item("b", "0"));
        seen.push(items.revision());
        items.extend(vec![item("c", "3")]);
        seen.push(items.revision());
        items.retain(|_| true);
        seen.push(items.revision());
        items.clear();
        seen.push(items.revision());

        // A wholesale replacement must not be able to reuse a revision a
        // derived cache has already seen.
        seen.push(ThreadItems::from(vec![item("a", "1")]).revision());
        seen.push(next_items_revision());

        let unique = seen.iter().copied().collect::<std::collections::HashSet<_>>();
        assert_eq!(unique.len(), seen.len(), "revisions repeated: {seen:?}");
    }

    #[test]
    fn clone_preserves_revision_and_index() {
        let mut items = ThreadItems::new();
        items.push(item("a", "1"));
        items.push(item("b", "2"));
        let cloned = items.clone();
        assert_eq!(cloned.revision(), items.revision());
        assert_eq!(cloned.index_of("b"), Some(1));
    }
}
