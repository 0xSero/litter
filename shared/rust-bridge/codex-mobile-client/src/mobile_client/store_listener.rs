use super::*;

const SUBAGENT_METADATA_HYDRATE_DELAYS_MS: [u64; 3] = [150, 800, 2500];
const IDLE_THREAD_RECONCILE_DELAYS_MS: [u64; 3] = [100, 500, 1_500];

pub(super) fn spawn_store_listener(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
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

            let runtime_kind = app_store
                .snapshot()
                .threads
                .get(&key)
                .map(|thread| thread.agent_runtime_kind.clone())
                .unwrap_or_else(|| "codex".to_string());
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
                    let durable_turn_is_complete =
                        !response.thread.turns.is_empty()
                            && response.thread.turns.iter().all(|turn| {
                                !matches!(turn.status, upstream::TurnStatus::InProgress)
                            });
                    if let Err(error) = upsert_thread_snapshot_from_app_server_read_response(
                        &app_store,
                        &key.server_id,
                        response,
                    ) {
                        warn!(
                            "MobileClient: failed to reconcile idle thread for server={} thread={}: {}",
                            key.server_id, key.thread_id, error
                        );
                        continue;
                    }
                    if durable_turn_is_complete {
                        return;
                    }
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
                            &app_store, &server_id, response,
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
