use super::*;

const SUBAGENT_METADATA_HYDRATE_DELAYS_MS: [u64; 3] = [150, 800, 2500];
const IDLE_THREAD_RECONCILE_DELAYS_MS: [u64; 3] = [100, 500, 1_500];

pub(super) fn spawn_store_listener(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    mobile_preferences_directory: Arc<StdMutex<Option<String>>>,
    mut rx: broadcast::Receiver<UiEvent>,
) {
    MobileClient::spawn_detached(async move {
        loop {
            match rx.recv().await {
                Ok(event) => {
                    app_store.apply_ui_event(&event);
                    maybe_reconcile_idle_thread(
                        Arc::clone(&app_store),
                        Arc::clone(&sessions),
                        &event,
                    );
                    maybe_persist_thread_mode_from_event(&mobile_preferences_directory, &event);
                    maybe_hydrate_collab_agent_metadata(
                        Arc::clone(&app_store),
                        Arc::clone(&sessions),
                        &event,
                    );
                    if let UiEvent::TurnCompleted { key, .. } = &event {
                        maybe_send_next_local_queued_follow_up(
                            Arc::clone(&app_store),
                            Arc::clone(&sessions),
                            key.clone(),
                        )
                        .await;
                    }
                }
                Err(broadcast::error::RecvError::Closed) => break,
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    warn!("MobileClient: lagged {skipped} UI events");
                }
            }
        }
    });
}

fn maybe_reconcile_idle_thread(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    event: &UiEvent,
) {
    let Some(key) = idle_thread_key(event).cloned() else {
        return;
    };

    MobileClient::spawn_detached(async move {
        for delay_ms in IDLE_THREAD_RECONCILE_DELAYS_MS {
            // Some app-server transports publish idle just before their
            // durable turn record becomes readable. Keep this repair off the
            // event loop and retry only while that record is empty/active.
            tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;

            let session = match sessions.read() {
                Ok(guard) => guard.get(&key.server_id).cloned(),
                Err(error) => {
                    warn!("MobileClient: recovering poisoned sessions read lock");
                    error.into_inner().get(&key.server_id).cloned()
                }
            };
            let Some(session) = session else {
                return;
            };
            if !session_is_current(&sessions, &key.server_id, &session) {
                return;
            }

            let Some(before) = app_store.thread_snapshot(&key) else {
                return;
            };
            if before.active_turn_id.is_some() || before.info.status != ThreadSummaryStatus::Idle {
                return;
            }
            let items_revision = before.items.revision();
            let overlays_revision = before.local_overlay_items.revision();
            let latest_turn_id = before
                .items
                .iter()
                .rev()
                .find_map(|item| item.source_turn_id.clone());
            let runtime_kind = before.agent_runtime_kind.clone();
            drop(before);
            match read_thread_response_from_app_server_runtime(
                Arc::clone(&session),
                runtime_kind,
                &key.thread_id,
                true,
            )
            .await
            {
                Ok(response) => {
                    if !session_is_current(&sessions, &key.server_id, &session) {
                        return;
                    }
                    let durable_turn_is_complete = !response.thread.turns.is_empty()
                        && response
                            .thread
                            .turns
                            .iter()
                            .all(|turn| !matches!(turn.status, upstream::TurnStatus::InProgress))
                        && latest_turn_id.as_ref().is_none_or(|id| {
                            response.thread.turns.iter().any(|turn| {
                                &turn.id == id && turn.items_view == upstream::TurnItemsView::Full
                            })
                        });
                    // The idle event can precede the durable write. Applying
                    // that older InProgress snapshot would resurrect a
                    // finished turn and cancel the next repair attempt. A
                    // reply omitting the most recently observed turn is
                    // also stale even when all older turns are completed.
                    if !durable_turn_is_complete {
                        continue;
                    }
                    let repaired = match thread_snapshot_from_app_server_read_response(
                        &app_store,
                        &key.server_id,
                        response,
                        true,
                    ) {
                        Ok(repaired) => repaired,
                        Err(error) => {
                            warn!(
                                "MobileClient: failed to reconcile idle thread for server={} thread={}: {}",
                                key.server_id, key.thread_id, error
                            );
                            continue;
                        }
                    };
                    app_store.upsert_idle_thread_snapshot_if_unchanged(
                        repaired,
                        items_revision,
                        overlays_revision,
                    );
                    return;
                }
                Err(error) => {
                    warn!(
                        "MobileClient: failed to refresh idle thread for server={} thread={}: {}",
                        key.server_id, key.thread_id, error
                    );
                }
            }
        }
    });
}

fn idle_thread_key(event: &UiEvent) -> Option<&ThreadKey> {
    match event {
        UiEvent::ThreadStatusChanged { key, notification }
            if matches!(notification.status, upstream::ThreadStatus::Idle) =>
        {
            Some(key)
        }
        _ => None,
    }
}

fn maybe_persist_thread_mode_from_event(
    mobile_preferences_directory: &Arc<StdMutex<Option<String>>>,
    event: &UiEvent,
) {
    let UiEvent::ItemCompleted { key, notification } = event else {
        return;
    };
    if !matches!(notification.item, upstream::ThreadItem::Plan { .. }) {
        return;
    }
    let directory = {
        let guard = mobile_preferences_directory
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.clone()
    };
    let Some(directory) = directory else {
        return;
    };
    crate::thread_modes::set_mode(&directory, key, AppModeKind::Plan);
}

fn maybe_hydrate_collab_agent_metadata(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    event: &UiEvent,
) {
    let Some((server_id, receiver_thread_ids)) = collab_receiver_thread_ids(event) else {
        return;
    };
    if receiver_thread_ids.is_empty() {
        return;
    }

    for thread_id in receiver_thread_ids {
        if !subagent_label_missing(&app_store, &server_id, &thread_id) {
            continue;
        }
        let app_store = Arc::clone(&app_store);
        let sessions = Arc::clone(&sessions);
        let server_id = server_id.clone();
        MobileClient::spawn_detached(async move {
            for delay_ms in std::iter::once(0_u64).chain(SUBAGENT_METADATA_HYDRATE_DELAYS_MS) {
                if !subagent_label_missing(&app_store, &server_id, &thread_id) {
                    return;
                }
                if delay_ms > 0 {
                    tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
                    if !subagent_label_missing(&app_store, &server_id, &thread_id) {
                        return;
                    }
                }

                let session = match sessions.read() {
                    Ok(guard) => guard.get(&server_id).cloned(),
                    Err(error) => {
                        warn!("MobileClient: recovering poisoned sessions read lock");
                        error.into_inner().get(&server_id).cloned()
                    }
                };
                let Some(session) = session else {
                    return;
                };
                if !session_is_current(&sessions, &server_id, &session) {
                    return;
                }

                match read_thread_response_from_app_server(Arc::clone(&session), &thread_id, false)
                    .await
                {
                    Ok(response) => {
                        if !session_is_current(&sessions, &server_id, &session) {
                            return;
                        }
                        if let Err(error) = upsert_thread_snapshot_from_app_server_read_response(
                            &app_store, &server_id, response, false,
                        ) {
                            warn!(
                                "MobileClient: failed to hydrate collab receiver metadata for server={} thread={}: {}",
                                server_id, thread_id, error
                            );
                            continue;
                        }
                    }
                    Err(error) => {
                        warn!(
                            "MobileClient: failed to read collab receiver metadata for server={} thread={}: {}",
                            server_id, thread_id, error
                        );
                    }
                }
            }
        });
    }
}

fn collab_receiver_thread_ids(event: &UiEvent) -> Option<(String, Vec<String>)> {
    match event {
        UiEvent::ItemStarted { key, notification } => match &notification.item {
            upstream::ThreadItem::CollabAgentToolCall {
                receiver_thread_ids,
                ..
            } if !receiver_thread_ids.is_empty() => Some((
                key.server_id.clone(),
                normalized_thread_ids(receiver_thread_ids.iter().map(String::as_str)),
            )),
            _ => None,
        },
        UiEvent::ItemCompleted { key, notification } => match &notification.item {
            upstream::ThreadItem::CollabAgentToolCall {
                receiver_thread_ids,
                ..
            } if !receiver_thread_ids.is_empty() => Some((
                key.server_id.clone(),
                normalized_thread_ids(receiver_thread_ids.iter().map(String::as_str)),
            )),
            _ => None,
        },
        UiEvent::RawNotification {
            server_id,
            method,
            params,
        } if method.contains("collab") => {
            let ids = params
                .get("receiver_agents")
                .and_then(serde_json::Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|value| value.get("thread_id"))
                .filter_map(serde_json::Value::as_str);
            let ids = normalized_thread_ids(ids);
            (!ids.is_empty()).then(|| (server_id.clone(), ids))
        }
        _ => None,
    }
}

fn normalized_thread_ids<'a>(thread_ids: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut normalized = Vec::new();
    for thread_id in thread_ids {
        let trimmed = thread_id.trim();
        if trimmed.is_empty() || !seen.insert(trimmed.to_string()) {
            continue;
        }
        normalized.push(trimmed.to_string());
    }
    normalized
}

fn subagent_label_missing(app_store: &AppStoreReducer, server_id: &str, thread_id: &str) -> bool {
    let snapshot = app_store.snapshot();
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: thread_id.to_string(),
    };
    snapshot.threads.get(&key).is_none_or(|thread| {
        thread
            .info
            .agent_nickname
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .is_none()
            && thread
                .info
                .agent_role
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .is_none()
    })
}

pub(super) async fn maybe_send_next_local_queued_follow_up(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    key: ThreadKey,
) {
    let snapshot = app_store.snapshot();
    let Some(thread) = snapshot.threads.get(&key).cloned() else {
        return;
    };
    if thread.active_turn_id.is_some() || thread.queued_follow_up_drafts.is_empty() {
        return;
    }

    let session = match sessions.read() {
        Ok(guard) => guard.get(&key.server_id).cloned(),
        Err(error) => {
            warn!("MobileClient: recovering poisoned sessions read lock");
            error.into_inner().get(&key.server_id).cloned()
        }
    };
    let Some(session) = session else {
        return;
    };

    let Some(draft) = app_store.claim_first_queued_follow_up_draft(&key) else {
        return;
    };
    let response = session.request(
        "turn/start",
        serde_json::json!({
            "threadId": key.thread_id,
            "input": draft.inputs.clone(),
        }),
    );
    if let Err(error) = response.await {
        app_store.restore_queued_follow_up_draft_front(&key, draft);
        warn!(
            "MobileClient: failed to autosend queued follow-up for {} thread {}: {}",
            key.server_id, key.thread_id, error
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::connection::TestRequestHandler;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tempfile::tempdir;

    fn idle_repair_response(status: &str) -> serde_json::Value {
        serde_json::json!({
            "thread": {
                "id": "thread", "sessionId": "session", "preview": "history",
                "ephemeral": false, "modelProvider": "openai",
                "createdAt": 1, "updatedAt": 2, "status": { "type": "idle" },
                "path": "/tmp/thread", "cwd": "/tmp", "cliVersion": "1.0.0",
                "source": "cli", "agentNickname": null, "agentRole": null,
                "gitInfo": null, "name": "thread",
                "turns": [{
                    "id": "turn-1", "status": status, "itemsView": "full",
                    "items": [{ "type": "agentMessage", "id": "answer-1", "text": "durable answer" }],
                    "error": null, "startedAt": 1, "completedAt": 2, "durationMs": 1
                }]
            }
        })
    }

    fn start_idle_repair_test(
        app_store: Arc<AppStoreReducer>,
        handler: TestRequestHandler,
        initial_turns: Vec<upstream::Turn>,
    ) {
        let mut response: upstream::ThreadReadResponse =
            serde_json::from_value(idle_repair_response("completed")).unwrap();
        response.thread.turns = initial_turns;
        let snapshot = thread_snapshot_from_upstream_thread_with_overrides(
            "srv",
            response.thread,
            None,
            None,
            None,
            None,
        )
        .unwrap();
        let key = snapshot.key.clone();
        app_store.upsert_thread_snapshot(snapshot);
        let config = ServerConfig {
            server_id: "srv".into(),
            display_name: "srv".into(),
            host: "127.0.0.1".into(),
            port: 0,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(handler),
            None,
            None,
        ));
        let sessions = Arc::new(RwLock::new(HashMap::from([("srv".into(), session)])));
        maybe_reconcile_idle_thread(
            app_store,
            sessions,
            &UiEvent::ThreadStatusChanged {
                key,
                notification: upstream::ThreadStatusChangedNotification {
                    thread_id: "thread".into(),
                    status: upstream::ThreadStatus::Idle,
                },
            },
        );
    }

    #[tokio::test]
    async fn idle_repair_retries_in_progress_read_without_resurrecting_turn() {
        let store = Arc::new(AppStoreReducer::new());
        let reads = Arc::new(AtomicUsize::new(0));
        let handler: TestRequestHandler = {
            let store = Arc::clone(&store);
            let reads = Arc::clone(&reads);
            Arc::new(move |request| {
                let upstream::ClientRequest::ThreadRead { params, .. } = request else {
                    panic!("idle repair must only read the thread");
                };
                assert!(params.include_turns);
                let current = store
                    .thread_snapshot(&ThreadKey {
                        server_id: "srv".into(),
                        thread_id: "thread".into(),
                    })
                    .unwrap();
                assert_eq!(current.active_turn_id, None);
                assert_eq!(current.info.status, ThreadSummaryStatus::Idle);
                let read = reads.fetch_add(1, Ordering::SeqCst);
                Ok(idle_repair_response(if read == 0 {
                    "inProgress"
                } else {
                    "completed"
                }))
            })
        };
        start_idle_repair_test(Arc::clone(&store), handler, vec![]);
        let mut updates = store.subscribe();
        tokio::time::timeout(std::time::Duration::from_secs(3), updates.recv())
            .await
            .expect("completed repair must publish within retry window")
            .expect("store update channel must remain open");
        assert_eq!(reads.load(Ordering::SeqCst), 2);
        let current = store
            .thread_snapshot(&ThreadKey {
                server_id: "srv".into(),
                thread_id: "thread".into(),
            })
            .unwrap();
        assert_eq!(current.active_turn_id, None);
        assert_eq!(current.info.status, ThreadSummaryStatus::Idle);
        assert_eq!(current.items.len(), 1);
        assert_eq!(current.items[0].id, "answer-1");
    }

    #[tokio::test]
    async fn idle_repair_rejects_read_when_follow_up_starts_before_reply() {
        let store = Arc::new(AppStoreReducer::new());
        let key = ThreadKey {
            server_id: "srv".into(),
            thread_id: "thread".into(),
        };
        let handler: TestRequestHandler = {
            let store = Arc::clone(&store);
            let key = key.clone();
            Arc::new(move |request| {
                assert!(matches!(
                    request,
                    upstream::ClientRequest::ThreadRead { .. }
                ));
                // The request has captured idle revisions; deliver a new turn
                // before returning its now-stale durable response.
                store.apply_ui_event(&UiEvent::TurnStarted {
                    key: key.clone(),
                    turn_id: "turn-2".into(),
                });
                Ok(idle_repair_response("completed"))
            })
        };
        start_idle_repair_test(Arc::clone(&store), handler, vec![]);
        let mut updates = store.subscribe();
        tokio::time::timeout(std::time::Duration::from_secs(3), updates.recv())
            .await
            .expect("follow-up must start")
            .expect("store update channel must remain open");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(250), updates.recv())
                .await
                .is_err(),
            "rejected stale read must not publish a replacement"
        );
        let current = store.thread_snapshot(&key).unwrap();
        assert_eq!(current.active_turn_id.as_deref(), Some("turn-2"));
        assert_eq!(current.info.status, ThreadSummaryStatus::Active);
        assert!(
            current.items.is_empty(),
            "stale answer must not replace live state"
        );
    }

    #[tokio::test]
    async fn idle_repair_retries_when_latest_completed_turn_is_not_durable_yet() {
        let store = Arc::new(AppStoreReducer::new());
        let reads = Arc::new(AtomicUsize::new(0));
        let key = ThreadKey {
            server_id: "srv".into(),
            thread_id: "thread".into(),
        };
        let mut complete_response = idle_repair_response("completed");
        let mut second_turn = complete_response["thread"]["turns"][0].clone();
        second_turn["id"] = serde_json::json!("turn-2");
        second_turn["items"][0]["id"] = serde_json::json!("answer-2");
        complete_response["thread"]["turns"]
            .as_array_mut()
            .unwrap()
            .push(second_turn);
        let initial: upstream::ThreadReadResponse =
            serde_json::from_value(complete_response.clone()).unwrap();
        let handler: TestRequestHandler = {
            let store = Arc::clone(&store);
            let reads = Arc::clone(&reads);
            let key = key.clone();
            Arc::new(move |request| {
                assert!(matches!(
                    request,
                    upstream::ClientRequest::ThreadRead { .. }
                ));
                let current = store.thread_snapshot(&key).unwrap();
                assert_eq!(current.info.status, ThreadSummaryStatus::Idle);
                assert_eq!(
                    current.items.len(),
                    2,
                    "older durable reply must not erase completed follow-up"
                );
                assert_eq!(current.items[1].source_turn_id.as_deref(), Some("turn-2"));
                let read = reads.fetch_add(1, Ordering::SeqCst);
                Ok(if read == 0 {
                    idle_repair_response("completed")
                } else {
                    complete_response.clone()
                })
            })
        };
        start_idle_repair_test(Arc::clone(&store), handler, initial.thread.turns);
        let mut updates = store.subscribe();
        tokio::time::timeout(std::time::Duration::from_secs(3), updates.recv())
            .await
            .expect("repair must retry until latest turn is durable")
            .expect("store update channel must remain open");
        assert_eq!(reads.load(Ordering::SeqCst), 2);
        let current = store.thread_snapshot(&key).unwrap();
        assert_eq!(current.active_turn_id, None);
        assert_eq!(
            current
                .items
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec!["answer-1", "answer-2"]
        );
    }

    #[test]
    fn item_completed_plan_persists_plan_mode() {
        let tempdir = tempdir().expect("tempdir");
        let directory = tempdir.path().to_string_lossy().to_string();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let event = UiEvent::ItemCompleted {
            key: key.clone(),
            notification: upstream::ItemCompletedNotification {
                item: upstream::ThreadItem::Plan {
                    id: "plan".to_string(),
                    text: "plan text".to_string(),
                },
                thread_id: key.thread_id.clone(),
                turn_id: "turn-plan".to_string(),
                completed_at_ms: 0,
            },
        };

        maybe_persist_thread_mode_from_event(
            &Arc::new(StdMutex::new(Some(directory.clone()))),
            &event,
        );

        assert_eq!(
            crate::thread_modes::read_mode(&directory, &key),
            Some(AppModeKind::Plan)
        );
    }

    #[test]
    fn only_idle_status_changes_request_authoritative_reconciliation() {
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        };
        let idle = UiEvent::ThreadStatusChanged {
            key: key.clone(),
            notification: upstream::ThreadStatusChangedNotification {
                thread_id: key.thread_id.clone(),
                status: upstream::ThreadStatus::Idle,
            },
        };
        let active = UiEvent::ThreadStatusChanged {
            key,
            notification: upstream::ThreadStatusChangedNotification {
                thread_id: "thread".to_string(),
                status: upstream::ThreadStatus::Active {
                    active_flags: Vec::new(),
                },
            },
        };

        assert_eq!(
            idle_thread_key(&idle),
            Some(&ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread".to_string(),
            })
        );
        assert_eq!(idle_thread_key(&active), None);
    }

    #[test]
    fn collab_receiver_thread_ids_extracts_spawn_agent_targets() {
        let event = UiEvent::ItemCompleted {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "parent".to_string(),
            },
            notification: upstream::ItemCompletedNotification {
                item: upstream::ThreadItem::CollabAgentToolCall {
                    id: "call-1".to_string(),
                    tool: upstream::CollabAgentTool::SpawnAgent,
                    status: upstream::CollabAgentToolCallStatus::Completed,
                    sender_thread_id: "parent".to_string(),
                    receiver_thread_ids: vec![
                        " child-1 ".to_string(),
                        "child-2".to_string(),
                        "child-1".to_string(),
                    ],
                    prompt: None,
                    model: None,
                    reasoning_effort: None,
                    agents_states: HashMap::new(),
                },
                thread_id: "parent".to_string(),
                turn_id: "turn-1".to_string(),
                completed_at_ms: 0,
            },
        };

        assert_eq!(
            collab_receiver_thread_ids(&event),
            Some((
                "srv".to_string(),
                vec!["child-1".to_string(), "child-2".to_string()],
            ))
        );
    }

    #[test]
    fn collab_receiver_thread_ids_extracts_legacy_receiver_agents() {
        let event = UiEvent::RawNotification {
            server_id: "srv".to_string(),
            method: "codex/event/collab_wait_end".to_string(),
            params: serde_json::json!({
                "receiver_agents": [
                    { "thread_id": "child-1" },
                    { "thread_id": " child-2 " },
                    { "thread_id": "child-1" }
                ]
            }),
        };

        assert_eq!(
            collab_receiver_thread_ids(&event),
            Some((
                "srv".to_string(),
                vec!["child-1".to_string(), "child-2".to_string()],
            ))
        );
    }
}
