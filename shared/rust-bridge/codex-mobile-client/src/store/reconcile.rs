use std::any::Any;
use std::collections::HashSet;

use crate::MobileClient;
use crate::conversation_uniffi::{HydratedConversationItem, HydratedConversationItemContent};
use crate::store::ThreadSnapshot;
use crate::transport::RpcError;
use crate::types::server_requests::{AppListThreadTurnsResponse, AppTurnsSortDirection};
use crate::types::{AgentRuntimeKind, ThreadInfo, ThreadKey};
use codex_app_server_protocol as upstream;

impl MobileClient {
    /// Reconcile direct public RPC calls into the canonical app store.
    ///
    /// The public client RPC surface calls this hook after the upstream RPC
    /// returns. The reconciliation policy lives here:
    /// - snapshot/query RPCs reduce authoritative responses directly
    /// - mutations without authoritative payloads trigger targeted refreshes
    /// - event-complete RPCs are no-ops because upstream notifications drive
    ///   the reducer already
    pub async fn reconcile_public_rpc<P: Any, R: Any>(
        &self,
        wire_method: &str,
        server_id: &str,
        params: Option<&P>,
        response: &R,
    ) -> Result<(), RpcError> {
        if wire_method == "turn/start" {
            tracing::info!(
                "reconcile_public_rpc wire_method={} server_id={}",
                wire_method,
                server_id
            );
        }
        match wire_method {
            "thread/start" => {
                let response = downcast_public_rpc_response::<upstream::ThreadStartResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_start_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/list" => {
                let response = downcast_public_rpc_response::<upstream::ThreadListResponse>(
                    wire_method,
                    response,
                )?;
                self.sync_thread_list(server_id, &response.data)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/read" => {
                let response = downcast_public_rpc_response::<upstream::ThreadReadResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_read_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/resume" => {
                let response = downcast_public_rpc_response::<upstream::ThreadResumeResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_resume_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/fork" => {
                let response = downcast_public_rpc_response::<upstream::ThreadForkResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_fork_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/rollback" => {
                let response = downcast_public_rpc_response::<upstream::ThreadRollbackResponse>(
                    wire_method,
                    response,
                )?;
                let params = downcast_public_rpc_params::<upstream::ThreadRollbackParams>(
                    wire_method,
                    params.map(|value| value as &dyn Any),
                )?;
                self.apply_thread_rollback_response(server_id, &params.thread_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "account/read" => {
                let response = downcast_public_rpc_response::<upstream::GetAccountResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_account_response(server_id, response);
                Ok(())
            }
            "account/rateLimits/read" => {
                let response = downcast_public_rpc_response::<
                    upstream::GetAccountRateLimitsResponse,
                >(wire_method, response)?;
                // `account/rateLimits/read` is Codex-runtime specific upstream.
                self.apply_account_rate_limits_response(server_id, "codex".to_string(), response);
                Ok(())
            }
            "model/list" => {
                let response = downcast_public_rpc_response::<upstream::ModelListResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_model_list_response(server_id, response);
                Ok(())
            }
            "account/login/start" => self.sync_server_account(server_id).await,
            "account/logout" => self.sync_server_account_after_logout(server_id).await,
            _ => Ok(()),
        }
    }

    pub(crate) fn clear_server_account(&self, server_id: &str) {
        self.app_store.update_server_account(server_id, None, false);
    }

    pub fn apply_account_response(&self, server_id: &str, response: &upstream::GetAccountResponse) {
        self.app_store.update_server_account(
            server_id,
            response.account.clone().map(Into::into),
            response.requires_openai_auth,
        );
    }

    pub fn apply_account_rate_limits_response(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        response: &upstream::GetAccountRateLimitsResponse,
    ) {
        self.app_store.update_server_rate_limits(
            server_id,
            runtime_kind,
            Some(response.rate_limits.clone().into()),
        );
    }

    pub fn apply_model_list_response(
        &self,
        server_id: &str,
        response: &upstream::ModelListResponse,
    ) {
        self.app_store.update_server_models(
            server_id,
            Some(response.data.iter().cloned().map(Into::into).collect()),
        );
    }

    pub fn sync_thread_list(
        &self,
        server_id: &str,
        threads: &[upstream::Thread],
    ) -> Result<Vec<ThreadInfo>, String> {
        let threads = threads
            .iter()
            .cloned()
            .filter_map(crate::thread_info_from_upstream_thread)
            .collect::<Vec<_>>();
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(threads)
    }

    pub fn upsert_thread_list_page(
        &self,
        server_id: &str,
        threads: &[upstream::Thread],
    ) -> Vec<ThreadInfo> {
        self.upsert_thread_list_page_for_runtime(server_id, "codex".to_string(), threads)
    }

    pub fn upsert_thread_list_page_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        threads: &[upstream::Thread],
    ) -> Vec<ThreadInfo> {
        let threads = threads
            .iter()
            .cloned()
            .filter_map(crate::thread_info_from_upstream_thread)
            .collect::<Vec<_>>();
        self.app_store
            .upsert_thread_list_page_for_runtime(server_id, runtime_kind, &threads);
        threads
    }

    pub fn finalize_thread_list_sync(
        &self,
        server_id: &str,
        thread_ids: impl IntoIterator<Item = String>,
    ) {
        let incoming_ids = thread_ids.into_iter().collect();
        self.app_store
            .finalize_thread_list_sync(server_id, &incoming_ids);
    }

    pub(crate) async fn sync_server_account_after_logout(
        &self,
        server_id: &str,
    ) -> Result<(), RpcError> {
        match self.sync_server_account(server_id).await {
            Ok(()) => Ok(()),
            Err(error) => {
                self.clear_server_account(server_id);
                Err(error)
            }
        }
    }

    pub fn apply_thread_start_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadStartResponse,
    ) -> Result<ThreadKey, String> {
        self.apply_thread_start_response_for_runtime(server_id, "codex".to_string(), response)
    }

    pub fn apply_thread_start_response_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        response: &upstream::ThreadStartResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .map(Into::into)
                .map(crate::reasoning_effort_string),
            Some(response.approval_policy.clone().into()),
            Some(response.sandbox.clone().into()),
        )
        .map_err(|e| e.to_string())?;
        snapshot.agent_runtime_kind = runtime_kind;
        // A freshly-started thread has no turns to page; mark the initial
        // page as loaded so UI does not auto-fire `thread/turns/list`
        // (which the server rejects until the first user message lands).
        snapshot.initial_turns_loaded = true;
        snapshot.older_turns_cursor = None;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub fn apply_thread_read_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadReadResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            None,
            None,
            response.approval_policy.clone().map(Into::into),
            response.sandbox.clone().map(Into::into),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        // Share the preserve-on-empty merge with resume/fork. A paginated
        // v0.125+ server returns `thread.turns: []` on thread/read — we
        // must keep any items + `older_turns_cursor` the prior
        // `load_thread_turns_page` stored. A legacy (or authoritative)
        // response with embedded turns clears the cursor because the
        // embedded list is the full history.
        apply_pagination_merge(existing.as_ref(), &mut snapshot, &response.thread.turns);
        // thread/read is authoritative for `initial_turns_loaded`: if the
        // server returned no turns AND no prior state exists, treat the
        // thread as having no history rather than a pending page load, so
        // the iOS spinner doesn't stick (task #10 invariant).
        if existing.is_none() && response.thread.turns.is_empty() {
            snapshot.initial_turns_loaded = true;
        }
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub fn apply_thread_resume_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadResumeResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .map(Into::into)
                .map(crate::reasoning_effort_string),
            Some(response.approval_policy.clone().into()),
            Some(response.sandbox.clone().into()),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        apply_pagination_merge(existing.as_ref(), &mut snapshot, &response.thread.turns);
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub fn apply_thread_fork_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadForkResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .map(Into::into)
                .map(crate::reasoning_effort_string),
            Some(response.approval_policy.clone().into()),
            Some(response.sandbox.clone().into()),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        apply_pagination_merge(existing.as_ref(), &mut snapshot, &response.thread.turns);
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    /// Merge a paged `thread/turns/list` response into the canonical thread
    /// snapshot.
    ///
    /// `direction` matches the `sortDirection` the client sent with the
    /// request. For `Descending` (newest-first) pages the hydrated turns
    /// are in newest-first order; the store keeps items in chronological
    /// (ascending) order, so this reverses per-page before merging. Turns
    /// already in the store (by `source_turn_id`) are deduped.
    pub fn apply_thread_turns_page(
        &self,
        server_id: &str,
        thread_id: &str,
        page: &AppListThreadTurnsResponse,
        direction: AppTurnsSortDirection,
    ) -> Result<(), String> {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let mut thread = match self.app_store.thread_snapshot(&key) {
            Some(thread) => thread,
            None => return Err(format!("thread {thread_id} not in store")),
        };
        merge_paged_turns(&mut thread, page, direction);
        // Diagnostic for the pagination-cursor-lost bug (task #13): log
        // the post-merge state so platform teams can correlate a logcat
        // entry here with the `AppLoadThreadTurnsOutcome` they received.
        tracing::info!(
            target: "store",
            server_id,
            thread_id,
            item_count = thread.items.len(),
            older_turns_cursor = thread.older_turns_cursor.as_deref().unwrap_or(""),
            initial_turns_loaded = thread.initial_turns_loaded,
            "apply_thread_turns_page merged"
        );
        self.app_store.upsert_thread_snapshot(thread);
        Ok(())
    }

    pub fn apply_thread_rollback_response(
        &self,
        server_id: &str,
        thread_id: &str,
        response: &upstream::ThreadRollbackResponse,
    ) -> Result<ThreadKey, String> {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let current = self.app_store.thread_snapshot(&key);
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            current.as_ref().and_then(|thread| thread.model.clone()),
            current.as_ref().and_then(|thread| {
                thread
                    .reasoning_effort
                    .as_deref()
                    .and_then(crate::reasoning_effort_from_string)
                    .map(crate::reasoning_effort_string)
            }),
            current
                .as_ref()
                .and_then(|thread| thread.effective_approval_policy.clone()),
            current
                .as_ref()
                .and_then(|thread| thread.effective_sandbox_policy.clone()),
        )
        .map_err(|e| e.to_string())?;
        if let Some(current) = current.as_ref() {
            crate::copy_thread_runtime_fields(current, &mut snapshot);
            crate::reconcile_active_turn(Some(current), &mut snapshot, &response.thread.turns);
        }
        let next_key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(next_key)
    }
}

/// Decide how a resume/fork response's embedded `thread.turns` field maps
/// into the store's existing items list.
///
/// v0.125+ servers honor `exclude_turns: true` by returning an empty turns
/// array; we must preserve the store's existing hydrated items so the UI
/// does not flicker to empty while pagination loads the first page. Legacy
/// servers ignore `exclude_turns` and return the embedded turns — we treat
/// those as an authoritative hydration.
fn apply_pagination_merge(
    existing: Option<&ThreadSnapshot>,
    target: &mut ThreadSnapshot,
    upstream_turns: &[upstream::Turn],
) {
    if upstream_turns.is_empty() {
        if let Some(current) = existing {
            target.items = current.items.clone();
            target.older_turns_cursor = current.older_turns_cursor.clone();
            target.initial_turns_loaded = current.initial_turns_loaded;
        } else {
            target.initial_turns_loaded = false;
            target.older_turns_cursor = None;
        }
    } else {
        // Legacy remote (or explicit hydration): the response carries the
        // full turn history. Authoritative — paged cursor no longer applies.
        target.initial_turns_loaded = true;
        target.older_turns_cursor = None;
    }
}

fn user_replay_item_key(item: &HydratedConversationItem) -> Option<String> {
    match &item.content {
        HydratedConversationItemContent::User(data) => Some(format!(
            "user:{}:{}",
            data.text,
            serde_json::to_string(&data.image_data_uris).unwrap_or_default()
        )),
        _ => None,
    }
}

fn logical_replay_item_key(item: &HydratedConversationItem) -> Option<String> {
    match &item.content {
        HydratedConversationItemContent::User(_) => user_replay_item_key(item),
        HydratedConversationItemContent::Assistant(data) => {
            Some(format!("assistant:{}:{:?}", data.text, data.phase))
        }
        HydratedConversationItemContent::Reasoning(data) => Some(format!(
            "reasoning:{}:{}",
            serde_json::to_string(&data.summary).unwrap_or_default(),
            serde_json::to_string(&data.content).unwrap_or_default()
        )),
        _ => None,
    }
}

fn is_stream_text_item(item: &HydratedConversationItem) -> bool {
    matches!(
        item.content,
        HydratedConversationItemContent::Assistant(_)
            | HydratedConversationItemContent::Reasoning(_)
    )
}

fn prune_replayed_live_span(
    thread: &mut ThreadSnapshot,
    group_user_keys: &[String],
    incoming_item_ids: &HashSet<String>,
) {
    if group_user_keys.is_empty() {
        return;
    }

    let mut in_replayed_live_span = false;
    thread.items.retain(|item| {
        if let Some(key) = user_replay_item_key(item) {
            if group_user_keys.contains(&key) {
                if item.source_turn_id.is_none() {
                    in_replayed_live_span = true;
                    return false;
                }
                in_replayed_live_span = incoming_item_ids.contains(&item.id);
            } else {
                in_replayed_live_span = false;
            }
            return true;
        }

        if in_replayed_live_span && item.source_turn_id.is_none() && is_stream_text_item(item) {
            return false;
        }

        true
    });
}

fn replace_existing_items_by_id(
    thread: &mut ThreadSnapshot,
    incoming: impl IntoIterator<Item = HydratedConversationItem>,
) -> HashSet<String> {
    let mut replaced = HashSet::new();
    for item in incoming {
        if let Some(existing) = thread
            .items
            .iter_mut()
            .find(|existing| existing.id == item.id)
        {
            replaced.insert(item.id.clone());
            *existing = item;
        }
    }
    replaced
}

fn merge_paged_turns(
    thread: &mut ThreadSnapshot,
    page: &AppListThreadTurnsResponse,
    direction: AppTurnsSortDirection,
) {
    // Items within a single paged turn come in hydrated order (ascending).
    // When the server returns a Desc page (newest-first) we receive turns in
    // reverse chronological order, so we need to group by source_turn_id,
    // reverse the turn-order, then flatten.
    let mut turns_in_page: Vec<Vec<HydratedConversationItem>> = Vec::new();
    let mut current_turn_id: Option<String> = None;
    for item in &page.turns {
        let item_turn = item.source_turn_id.clone();
        if item_turn != current_turn_id {
            turns_in_page.push(Vec::new());
            current_turn_id = item_turn;
        }
        if let Some(group) = turns_in_page.last_mut() {
            group.push(item.clone());
        }
    }

    if matches!(direction, AppTurnsSortDirection::Descending) {
        // Desc page: newest turn first — reverse to get chronological order.
        turns_in_page.reverse();
    }

    // Build sets of existing turn ids and item ids already in the store for
    // dedupe. Item-id dedupe is essential because live ItemStarted/Completed
    // events hydrate with `source_turn_id: None` (see
    // `conversation_item_from_upstream` in store/actions.rs), so a paged turn
    // carrying the same upstream item id won't share a turn id with the
    // already-stored copy and would otherwise be added twice.
    let existing_turn_ids: HashSet<String> = thread
        .items
        .iter()
        .filter_map(|item| item.source_turn_id.clone())
        .collect();
    let existing_item_ids: HashSet<String> =
        thread.items.iter().map(|item| item.id.clone()).collect();

    let mut new_items: Vec<HydratedConversationItem> = Vec::new();
    for group in turns_in_page {
        let group_turn_id = group.first().and_then(|item| item.source_turn_id.clone());
        let incoming_item_ids: HashSet<String> = group.iter().map(|item| item.id.clone()).collect();

        // Preferred path for new Alleycat/Pi bridges: live stream items and
        // later replay items carry the same upstream item id. Replace the
        // sourceless live copy with the authoritative paged copy so metadata
        // such as `source_turn_id` is repaired without any content guessing.
        let replaced_item_ids = replace_existing_items_by_id(thread, group.iter().cloned());

        let group_user_keys = group
            .iter()
            .filter_map(user_replay_item_key)
            .collect::<Vec<_>>();
        let group_replays_existing_user = group_user_keys.iter().any(|key| {
            thread
                .items
                .iter()
                .filter_map(user_replay_item_key)
                .any(|existing_key| existing_key == *key)
        });
        let group_has_persisted_text = group.iter().any(|item| {
            item.source_turn_id.is_some()
                && matches!(
                    item.content,
                    HydratedConversationItemContent::Assistant(_)
                        | HydratedConversationItemContent::Reasoning(_)
                )
        });
        if let Some(id) = group_turn_id.as_deref() {
            if existing_turn_ids.contains(id) {
                // A reconnect repair page is authoritative for completed turn
                // text. Drop stale streaming assistant/reasoning placeholders
                // absent from the replay, while preserving the historical
                // turn-id dedupe for non-stream/user items.
                if thread.active_turn_id.is_none()
                    && group_replays_existing_user
                    && group_has_persisted_text
                {
                    prune_replayed_live_span(thread, &group_user_keys, &incoming_item_ids);
                    thread.items.retain(|item| {
                        incoming_item_ids.contains(&item.id)
                            || !is_stream_text_item(item)
                            || item.source_turn_id.as_deref() != Some(id)
                    });
                }
                continue;
            }
        }
        if thread.active_turn_id.is_none()
            && group_replays_existing_user
            && group_has_persisted_text
        {
            prune_replayed_live_span(thread, &group_user_keys, &incoming_item_ids);
        }
        for item in group {
            if existing_item_ids.contains(&item.id) || replaced_item_ids.contains(&item.id) {
                continue;
            }
            // Compatibility path for older/non-Codex bridges that synthesized
            // optimistic/live item ids before the underlying agent persisted
            // history. A later `thread/turns/list` can return the same logical
            // content with a different persisted id. Prefer the replay copy
            // when it carries a turn id, and avoid duplicate user / assistant /
            // reasoning bubbles after reconnect repair pages.
            if let Some(key) = logical_replay_item_key(&item)
                && let Some(existing) = thread.items.iter_mut().find(|existing| {
                    existing.source_turn_id.is_none()
                        && logical_replay_item_key(existing).as_deref() == Some(&key)
                })
            {
                if item.source_turn_id.is_some() && existing.source_turn_id.is_none() {
                    *existing = item;
                }
                continue;
            }
            new_items.push(item);
        }
    }

    // For Desc direction the `next_cursor` points at older turns; prepend new
    // items before existing ones since our store is chronological ascending.
    // For Asc direction (future use) append.
    if matches!(direction, AppTurnsSortDirection::Descending) {
        let mut merged = new_items;
        merged.extend(thread.items.iter().cloned());
        thread.items = merged;
        thread.older_turns_cursor = page.next_cursor.clone();
    } else {
        thread.items.extend(new_items);
    }
    thread.initial_turns_loaded = true;
}

fn downcast_public_rpc_response<'a, T: Any>(
    wire_method: &str,
    response: &'a dyn Any,
) -> Result<&'a T, RpcError> {
    response.downcast_ref::<T>().ok_or_else(|| {
        RpcError::Deserialization(format!(
            "unexpected response type while reconciling {wire_method}"
        ))
    })
}

fn downcast_public_rpc_params<'a, T: Any>(
    wire_method: &str,
    params: Option<&'a dyn Any>,
) -> Result<&'a T, RpcError> {
    params
        .and_then(|value| value.downcast_ref::<T>())
        .ok_or_else(|| {
            RpcError::Deserialization(format!(
                "unexpected params type while reconciling {wire_method}"
            ))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::connection::ServerConfig;
    use crate::store::ServerHealthSnapshot;
    use codex_app_server_protocol as upstream;
    use std::path::PathBuf;

    fn test_abs_path(path: &str) -> codex_utils_absolute_path::AbsolutePathBuf {
        codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path_checked(path)
            .expect("test path must be absolute")
    }

    fn test_upstream_thread(id: &str) -> upstream::Thread {
        upstream::Thread {
            id: id.to_string(),
            session_id: format!("session-{id}"),
            forked_from_id: None,
            preview: "hello".to_string(),
            ephemeral: false,
            model_provider: "openai".to_string(),
            created_at: 1,
            updated_at: 2,
            status: upstream::ThreadStatus::Idle,
            path: Some(PathBuf::from("/tmp/thread.jsonl")),
            cwd: test_abs_path("/tmp"),
            cli_version: "1.0.0".to_string(),
            source: upstream::SessionSource::default(),
            thread_source: None,
            agent_nickname: None,
            agent_role: None,
            git_info: None,
            name: Some("Thread".to_string()),
            turns: Vec::new(),
        }
    }

    #[tokio::test]
    async fn account_read_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".into(),
                display_name: "Server".into(),
                host: "127.0.0.1".into(),
                port: 9234,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::GetAccountResponse {
            account: Some(upstream::Account::Chatgpt {
                email: "user@example.com".into(),
                plan_type: codex_protocol::account::PlanType::Pro,
            }),
            requires_openai_auth: true,
        };

        client
            .reconcile_public_rpc("account/read", "srv", Option::<&()>::None, &response)
            .await
            .expect("account/read reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server should still exist");
        assert_eq!(server.account, response.account.clone().map(Into::into));
        assert!(server.requires_openai_auth);
    }

    #[tokio::test]
    async fn account_rate_limits_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::GetAccountRateLimitsResponse {
            rate_limits: upstream::RateLimitSnapshot {
                limit_id: Some("primary".to_string()),
                limit_name: Some("Primary".to_string()),
                primary: Some(upstream::RateLimitWindow {
                    used_percent: 42,
                    window_duration_mins: Some(60),
                    resets_at: Some(123456789),
                }),
                secondary: None,
                credits: Some(upstream::CreditsSnapshot {
                    has_credits: true,
                    unlimited: false,
                    balance: Some("5.00".to_string()),
                }),
                plan_type: Some(codex_protocol::account::PlanType::Plus),
                rate_limit_reached_type: None,
            },
            rate_limits_by_limit_id: None,
        };

        client
            .reconcile_public_rpc(
                "account/rateLimits/read",
                "srv",
                Option::<&()>::None,
                &response,
            )
            .await
            .expect("account/rateLimits/read reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server snapshot should exist");
        assert_eq!(
            server.rate_limits,
            Some(response.rate_limits.clone().into())
        );
    }

    #[tokio::test]
    async fn model_list_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::ModelListResponse {
            data: vec![upstream::Model {
                id: "gpt-5.4".to_string(),
                model: "gpt-5.4".to_string(),
                upgrade: None,
                display_name: "gpt-5.4".to_string(),
                description: "Balanced flagship".to_string(),
                hidden: false,
                supported_reasoning_efforts: vec![upstream::ReasoningEffortOption {
                    reasoning_effort: codex_protocol::openai_models::ReasoningEffort::Medium,
                    description: "Balanced".to_string(),
                }],
                default_reasoning_effort: codex_protocol::openai_models::ReasoningEffort::Medium,
                input_modalities: vec![codex_protocol::openai_models::InputModality::Text],
                supports_personality: true,
                additional_speed_tiers: Vec::new(),
                service_tiers: Vec::new(),
                is_default: true,
                availability_nux: None,
                upgrade_info: None,
            }],
            next_cursor: None,
        };

        client
            .reconcile_public_rpc("model/list", "srv", Option::<&()>::None, &response)
            .await
            .expect("model/list reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server snapshot should exist");
        assert_eq!(
            server.available_models,
            Some(response.data.into_iter().map(Into::into).collect())
        );
    }

    #[tokio::test]
    async fn thread_reconciliation_param_handling_matches_wire_method() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let list_response = upstream::ThreadListResponse {
            data: vec![test_upstream_thread("thread-1")],
            next_cursor: None,
            backwards_cursor: None,
        };

        client
            .reconcile_public_rpc("thread/list", "srv", Option::<&()>::None, &list_response)
            .await
            .expect("thread/list reconciliation should succeed without params");

        let rollback_response = upstream::ThreadRollbackResponse {
            thread: test_upstream_thread("thread-1"),
        };

        let missing_params_error = client
            .reconcile_public_rpc(
                "thread/rollback",
                "srv",
                Option::<&()>::None,
                &rollback_response,
            )
            .await
            .expect_err("thread/rollback should reject missing params");
        assert!(
            missing_params_error
                .to_string()
                .contains("unexpected params type while reconciling thread/rollback")
        );

        let params = upstream::ThreadRollbackParams {
            thread_id: "thread-1".to_string(),
            num_turns: 1,
        };
        client
            .reconcile_public_rpc("thread/rollback", "srv", Some(&params), &rollback_response)
            .await
            .expect("thread/rollback reconciliation should succeed with params");

        let snapshot = client.app_snapshot();
        assert!(snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        }));
    }

    fn item_with_turn(turn_id: &str, item_id: &str) -> HydratedConversationItem {
        use crate::conversation_uniffi::{
            HydratedConversationItemContent, HydratedUserMessageData,
        };
        HydratedConversationItem {
            id: item_id.to_string(),
            content: HydratedConversationItemContent::User(HydratedUserMessageData {
                text: "hi".to_string(),
                image_data_uris: Vec::new(),
            }),
            source_turn_id: Some(turn_id.to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn assistant_item(
        turn_id: Option<&str>,
        item_id: &str,
        text: &str,
    ) -> HydratedConversationItem {
        use crate::conversation_uniffi::{
            HydratedAssistantMessageData, HydratedConversationItemContent,
        };
        HydratedConversationItem {
            id: item_id.to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: text.to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: turn_id.map(ToOwned::to_owned),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn test_thread_snapshot() -> ThreadSnapshot {
        let info = ThreadInfo {
            id: "thread-1".to_string(),
            title: None,
            model: None,
            status: crate::types::ThreadSummaryStatus::Idle,
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
        ThreadSnapshot::from_info("srv", info)
    }

    #[test]
    fn merge_paged_turns_empty_store_first_desc_page() {
        let mut thread = test_thread_snapshot();
        let page = AppListThreadTurnsResponse {
            // Desc page: turn-3 newest, then turn-2, then turn-1.
            turns: vec![
                item_with_turn("turn-3", "i3"),
                item_with_turn("turn-2", "i2"),
                item_with_turn("turn-1", "i1"),
            ],
            next_cursor: Some("cursor-older".to_string()),
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        // Store should be chronological ascending.
        let ids: Vec<Option<String>> = thread
            .items
            .iter()
            .map(|item| item.source_turn_id.clone())
            .collect();
        assert_eq!(
            ids,
            vec![
                Some("turn-1".to_string()),
                Some("turn-2".to_string()),
                Some("turn-3".to_string()),
            ]
        );
        assert_eq!(thread.older_turns_cursor.as_deref(), Some("cursor-older"));
        assert!(thread.initial_turns_loaded);
    }

    #[test]
    fn merge_paged_turns_prepends_older_page() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![item_with_turn("turn-3", "i3")];
        thread.initial_turns_loaded = true;
        thread.older_turns_cursor = Some("cursor-first".to_string());
        let page = AppListThreadTurnsResponse {
            turns: vec![
                item_with_turn("turn-2", "i2"),
                item_with_turn("turn-1", "i1"),
            ],
            next_cursor: None, // no more older
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<Option<String>> = thread
            .items
            .iter()
            .map(|item| item.source_turn_id.clone())
            .collect();
        assert_eq!(
            ids,
            vec![
                Some("turn-1".to_string()),
                Some("turn-2".to_string()),
                Some("turn-3".to_string()),
            ]
        );
        assert!(thread.older_turns_cursor.is_none());
        assert!(thread.initial_turns_loaded);
    }

    #[test]
    fn merge_paged_turns_dedupes_existing_turn_id() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![item_with_turn("turn-3", "i3")];
        thread.initial_turns_loaded = true;
        let page = AppListThreadTurnsResponse {
            turns: vec![
                item_with_turn("turn-3", "i3-dup"),
                item_with_turn("turn-2", "i2"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        // Dupe of turn-3 should not reappear; turn-2 prepended.
        let ids: Vec<Option<String>> = thread
            .items
            .iter()
            .map(|item| item.source_turn_id.clone())
            .collect();
        assert_eq!(
            ids,
            vec![Some("turn-2".to_string()), Some("turn-3".to_string())]
        );
    }

    #[test]
    fn merge_paged_turns_replaces_same_item_id_with_authoritative_replay_item() {
        let mut thread = test_thread_snapshot();
        let mut live_item = item_with_turn("turn-live", "stable-user-id");
        live_item.source_turn_id = None;
        thread.items = vec![live_item];
        let page = AppListThreadTurnsResponse {
            turns: vec![item_with_turn("turn-1", "stable-user-id")],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "stable-user-id");
        assert_eq!(thread.items[0].source_turn_id.as_deref(), Some("turn-1"));
    }

    #[test]
    fn merge_paged_turns_replaces_same_logical_live_item_with_replay_item() {
        let mut thread = test_thread_snapshot();
        let mut live_item = item_with_turn("turn-live", "live-user-id");
        live_item.source_turn_id = None;
        let replay_item = item_with_turn("turn-1", "persisted-user-id");
        thread.items = vec![live_item];
        let page = AppListThreadTurnsResponse {
            turns: vec![replay_item],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "persisted-user-id");
        assert_eq!(thread.items[0].source_turn_id.as_deref(), Some("turn-1"));
    }

    #[test]
    fn merge_paged_turns_removes_sourceless_stream_text_when_replay_repairs_turn() {
        let mut thread = test_thread_snapshot();
        let mut live_user = item_with_turn("turn-live", "live-user-id");
        live_user.source_turn_id = None;
        thread.items = vec![
            live_user,
            assistant_item(None, "live-assistant-id", "partial"),
        ];
        let page = AppListThreadTurnsResponse {
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<String> = thread.items.iter().map(|item| item.id.clone()).collect();
        assert_eq!(ids, vec!["persisted-user-id", "persisted-assistant-id"]);
    }

    #[test]
    fn merge_paged_turns_repair_preserves_text_from_other_turns() {
        let mut thread = test_thread_snapshot();
        let mut live_user = item_with_turn("turn-live", "live-user-id");
        live_user.source_turn_id = None;
        thread.items = vec![
            item_with_turn("turn-0", "older-user-id"),
            assistant_item(Some("turn-0"), "older-assistant-id", "older final"),
            live_user,
            assistant_item(None, "live-assistant-id", "partial"),
        ];
        let page = AppListThreadTurnsResponse {
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<String> = thread.items.iter().map(|item| item.id.clone()).collect();
        assert!(
            ids.contains(&"older-assistant-id".to_string()),
            "repair for turn-1 must preserve assistant text from turn-0; ids={ids:?}"
        );
        assert!(
            !ids.contains(&"live-assistant-id".to_string()),
            "repair for turn-1 should prune the stale live assistant placeholder; ids={ids:?}"
        );
    }

    #[test]
    fn merge_paged_turns_keeps_active_stream_text_while_loading_pages() {
        let mut thread = test_thread_snapshot();
        thread.active_turn_id = Some("active-turn".to_string());
        let mut live_user = item_with_turn("turn-live", "live-user-id");
        live_user.source_turn_id = None;
        thread.items = vec![
            live_user,
            assistant_item(Some("active-turn"), "active-assistant-id", "partial"),
        ];
        let page = AppListThreadTurnsResponse {
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        assert!(
            thread
                .items
                .iter()
                .any(|item| item.id == "active-assistant-id")
        );
    }

    #[test]
    fn merge_paged_turns_prunes_stale_stream_text_for_existing_turn_replay() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![
            item_with_turn("turn-1", "persisted-user-id"),
            assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            assistant_item(Some("turn-1"), "late-stream-assistant-id", "late duplicate"),
        ];
        let page = AppListThreadTurnsResponse {
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<String> = thread.items.iter().map(|item| item.id.clone()).collect();
        assert_eq!(ids, vec!["persisted-user-id", "persisted-assistant-id"]);
    }

    #[test]
    fn apply_pagination_merge_preserves_existing_on_empty_turns() {
        let mut existing = test_thread_snapshot();
        existing.items = vec![item_with_turn("turn-1", "i1")];
        existing.initial_turns_loaded = true;
        existing.older_turns_cursor = Some("cursor-1".to_string());
        let mut target = test_thread_snapshot();
        target.items = Vec::new();
        apply_pagination_merge(Some(&existing), &mut target, &[]);
        assert_eq!(target.items.len(), 1);
        assert!(target.initial_turns_loaded);
        assert_eq!(target.older_turns_cursor.as_deref(), Some("cursor-1"));
    }

    #[test]
    fn apply_pagination_merge_legacy_nonempty_is_authoritative() {
        let mut existing = test_thread_snapshot();
        existing.items = vec![item_with_turn("stale", "s1")];
        existing.initial_turns_loaded = true;
        existing.older_turns_cursor = Some("cursor-1".to_string());
        let mut target = test_thread_snapshot();
        // target already populated from upstream thread with hydrated items.
        target.items = vec![item_with_turn("turn-1", "i1")];
        let upstream_turn = upstream::Turn {
            id: "turn-1".to_string(),
            status: upstream::TurnStatus::Completed,
            items: Vec::new(),
            items_view: upstream::TurnItemsView::Full,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        };
        apply_pagination_merge(Some(&existing), &mut target, &[upstream_turn]);
        // Legacy path: keep target's upstream-hydrated items, clear older
        // cursor, mark loaded.
        assert_eq!(target.items.len(), 1);
        assert!(target.initial_turns_loaded);
        assert!(target.older_turns_cursor.is_none());
    }

    #[test]
    fn apply_pagination_merge_no_existing_marks_initial_false() {
        let mut target = test_thread_snapshot();
        apply_pagination_merge(None, &mut target, &[]);
        assert!(!target.initial_turns_loaded);
        assert!(target.older_turns_cursor.is_none());
    }

    /// A freshly-started thread has no turns to page. The reducer must mark
    /// `initial_turns_loaded = true` immediately so the iOS conversation
    /// view does not auto-fire `thread/turns/list` (which the server
    /// rejects with "thread not materialized" until the first user turn
    /// lands).
    #[tokio::test]
    async fn apply_thread_start_response_marks_initial_turns_loaded() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        let response = upstream::ThreadStartResponse {
            thread: test_upstream_thread("thread-1"),
            model: "gpt-5".to_string(),
            model_provider: "openai".to_string(),
            service_tier: None,
            cwd: test_abs_path("/tmp"),
            runtime_workspace_roots: Vec::new(),
            instruction_sources: Vec::new(),
            approval_policy: upstream::AskForApproval::Never,
            approvals_reviewer: upstream::ApprovalsReviewer::User,
            sandbox: upstream::SandboxPolicy::DangerFullAccess,
            active_permission_profile: None,
            reasoning_effort: None,
        };
        let key = client
            .apply_thread_start_response("srv", &response)
            .expect("thread/start reconciliation");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(
            snapshot.initial_turns_loaded,
            "new thread must be marked initial_turns_loaded"
        );
        assert!(snapshot.older_turns_cursor.is_none());
    }

    #[tokio::test]
    async fn apply_thread_start_response_for_runtime_projects_session_summary() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        let response = upstream::ThreadStartResponse {
            thread: test_upstream_thread("thread-opencode"),
            model: "opencode/default".to_string(),
            model_provider: "opencode".to_string(),
            service_tier: None,
            cwd: test_abs_path("/tmp"),
            runtime_workspace_roots: Vec::new(),
            instruction_sources: Vec::new(),
            approval_policy: upstream::AskForApproval::Never,
            approvals_reviewer: upstream::ApprovalsReviewer::User,
            sandbox: upstream::SandboxPolicy::DangerFullAccess,
            active_permission_profile: None,
            reasoning_effort: None,
        };

        let key = client
            .apply_thread_start_response_for_runtime("srv", "opencode".to_string(), &response)
            .expect("thread/start reconciliation");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert_eq!(snapshot.agent_runtime_kind, "opencode");

        let record = crate::store::AppSnapshotRecord::try_from(client.app_snapshot())
            .expect("snapshot record");
        assert!(record.threads.iter().any(|thread| thread.key == key));
        let summary = record
            .session_summaries
            .iter()
            .find(|summary| summary.key == key)
            .expect("new session summary");
        assert_eq!(summary.agent_runtime_kind, "opencode");

        let default_response = upstream::ThreadStartResponse {
            thread: test_upstream_thread("thread-codex"),
            model: "gpt-5.5".to_string(),
            model_provider: "openai".to_string(),
            service_tier: None,
            cwd: test_abs_path("/tmp"),
            runtime_workspace_roots: Vec::new(),
            instruction_sources: Vec::new(),
            approval_policy: upstream::AskForApproval::Never,
            approvals_reviewer: upstream::ApprovalsReviewer::User,
            sandbox: upstream::SandboxPolicy::DangerFullAccess,
            active_permission_profile: None,
            reasoning_effort: None,
        };
        let default_key = client
            .apply_thread_start_response("srv", &default_response)
            .expect("default thread/start reconciliation");
        let default_snapshot = client
            .app_store
            .thread_snapshot(&default_key)
            .expect("default snapshot");
        assert_eq!(default_snapshot.agent_runtime_kind, "codex");
    }

    /// `thread/read` carries embedded turns and is authoritative — the
    /// reducer must mark `initial_turns_loaded = true` so the spinner
    /// clears and `older_turns_cursor` gets cleared.
    #[tokio::test]
    async fn apply_thread_read_response_marks_initial_turns_loaded() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        let response = upstream::ThreadReadResponse {
            thread: test_upstream_thread("thread-1"),
            approval_policy: None,
            sandbox: None,
        };
        let key = client
            .apply_thread_read_response("srv", &response)
            .expect("thread/read reconciliation");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(
            snapshot.initial_turns_loaded,
            "thread/read response must mark initial_turns_loaded"
        );
        assert!(snapshot.older_turns_cursor.is_none());
    }

    /// Regression for task #12. A `thread/read` response with embedded
    /// turns is authoritative: it should clear `older_turns_cursor` and
    /// mark `initial_turns_loaded`.
    #[tokio::test]
    async fn apply_thread_read_with_embedded_turns_clears_cursor() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        // Prime the snapshot with a stale cursor to confirm the embedded
        // path clears it.
        let info = crate::types::ThreadInfo {
            id: "thread-1".to_string(),
            title: None,
            model: None,
            status: crate::types::ThreadSummaryStatus::Idle,
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
        let mut primed = ThreadSnapshot::from_info("srv", info);
        primed.older_turns_cursor = Some("stale-cursor".to_string());
        primed.initial_turns_loaded = false;
        client.app_store.upsert_thread_snapshot(primed);

        let mut embedded_thread = test_upstream_thread("thread-1");
        embedded_thread.turns = vec![upstream::Turn {
            id: "turn-1".to_string(),
            status: upstream::TurnStatus::Completed,
            items: vec![upstream::ThreadItem::UserMessage {
                id: "server-user-item".to_string(),
                content: vec![upstream::UserInput::Text {
                    text: "hi".to_string(),
                    text_elements: Vec::new(),
                }],
            }],
            items_view: upstream::TurnItemsView::Full,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        }];
        let response = upstream::ThreadReadResponse {
            thread: embedded_thread,
            approval_policy: None,
            sandbox: None,
        };
        let key = client
            .apply_thread_read_response("srv", &response)
            .expect("thread/read");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(snapshot.initial_turns_loaded);
        assert!(
            snapshot.older_turns_cursor.is_none(),
            "embedded-turns path must clear cursor"
        );
    }

    /// Regression for task #12. A `thread/read` response with NO embedded
    /// turns (paginated server reply) must preserve the existing
    /// `older_turns_cursor` so the cursor stored by
    /// `apply_thread_turns_page` survives subsequent refreshes. Without
    /// this preservation, "Load earlier messages" never shows up on
    /// Android after `load_thread_turns_page` returned `has_more=true`.
    #[tokio::test]
    async fn apply_thread_read_with_empty_turns_preserves_pagination_state() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        // Prime the snapshot as if load_thread_turns_page had just
        // applied a page: items populated, cursor stored, flag set.
        let info = crate::types::ThreadInfo {
            id: "thread-1".to_string(),
            title: None,
            model: None,
            status: crate::types::ThreadSummaryStatus::Idle,
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
        let mut primed = ThreadSnapshot::from_info("srv", info);
        primed.items = vec![item_with_turn("turn-5", "i5")];
        primed.older_turns_cursor = Some("older-cursor".to_string());
        primed.initial_turns_loaded = true;
        client.app_store.upsert_thread_snapshot(primed);

        // thread/read arrives with no embedded turns (paginated server).
        let mut empty_thread = test_upstream_thread("thread-1");
        empty_thread.turns = Vec::new();
        let response = upstream::ThreadReadResponse {
            thread: empty_thread,
            approval_policy: None,
            sandbox: None,
        };
        let key = client
            .apply_thread_read_response("srv", &response)
            .expect("thread/read");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(
            snapshot.initial_turns_loaded,
            "initial_turns_loaded must remain true"
        );
        assert_eq!(
            snapshot.older_turns_cursor.as_deref(),
            Some("older-cursor"),
            "empty-turns thread/read must preserve existing pagination cursor"
        );
        assert_eq!(
            snapshot.items.len(),
            1,
            "existing paged items must be preserved when embedded turns are empty"
        );
    }
}
