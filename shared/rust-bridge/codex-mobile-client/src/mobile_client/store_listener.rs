use super::*;

const SUBAGENT_METADATA_HYDRATE_DELAYS_MS: [u64; 3] = [150, 800, 2500];

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
                    maybe_hydrate_collab_agent_metadata(
                        Arc::clone(&app_store),
                        Arc::clone(&sessions),
                        &event,
                    );
                    if let Some(key) = queued_follow_up_dispatch_key(&event) {
                        let app_store = Arc::clone(&app_store);
                        let sessions = Arc::clone(&sessions);
                        MobileClient::spawn_detached(async move {
                            maybe_send_next_local_queued_follow_up(app_store, sessions, key).await;
                        });
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

fn queued_follow_up_dispatch_key(event: &UiEvent) -> Option<ThreadKey> {
    match event {
        UiEvent::TurnCompleted { key, .. } => Some(key.clone()),
        UiEvent::ThreadStatusChanged { key, notification }
            if matches!(&notification.status, upstream::ThreadStatus::Idle) =>
        {
            Some(key.clone())
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
    if thread.active_turn_id.is_some()
        || matches!(thread.info.status, ThreadSummaryStatus::Active)
        || thread.queued_follow_up_drafts.is_empty()
    {
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

    let runtime_kind = thread.agent_runtime_kind.clone();
    let Some((draft, reservation_turn_id)) =
        app_store.claim_queued_follow_up_for_dispatch(&key)
    else {
        return;
    };
    let optimistic_overlay_id = app_store.stage_local_user_message_overlay(&key, &draft.inputs);
    let mut turn_start_params = draft
        .turn_start_params
        .clone()
        .unwrap_or_else(|| upstream::TurnStartParams {
            thread_id: key.thread_id.clone(),
            input: draft.inputs.clone(),
            ..Default::default()
        });
    // The controller owns permissions for Pi and Local Studio, but their
    // mobile contract is always non-interactive full access. This path sends
    // directly to the selected runtime, so apply the same normalization as
    // MobileClient::request_typed_for_server_runtime.
    if matches!(runtime_kind.as_str(), "pi" | "local-studio") {
        turn_start_params.approval_policy = Some(upstream::AskForApproval::Never);
        turn_start_params.sandbox_policy = Some(upstream::SandboxPolicy::DangerFullAccess);
    }
    turn_start_params.thread_id = key.thread_id.clone();
    turn_start_params.input = draft.inputs.clone();
    let command_id = app_store.begin_server_mutating_command(
        &key.server_id,
        ServerMutatingCommandKind::StartTurn,
        &key.thread_id,
    );
    let response = session
        .request_client_for_runtime(
            runtime_kind,
            upstream::ClientRequest::TurnStart {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: turn_start_params,
            },
        )
        .await
        .and_then(|value| {
            serde_json::from_value::<upstream::TurnStartResponse>(value)
                .map_err(|error| RpcError::Deserialization(error.to_string()))
        });
    match response {
        Ok(response) => {
            app_store.finish_server_mutating_command_success(&key.server_id, &command_id);
            if let Some(overlay_id) = optimistic_overlay_id.as_deref() {
                app_store.bind_local_user_message_overlay_to_turn(
                    &key,
                    overlay_id,
                    &response.turn.id,
                );
            }
            app_store.resolve_local_turn_start(
                &key,
                &reservation_turn_id,
                &response.turn.id,
            );
        }
        Err(error) => {
            app_store.finish_server_mutating_command_failure(&key.server_id, &command_id);
            if app_store.release_local_turn_start(&key, &reservation_turn_id) {
                if let Some(overlay_id) = optimistic_overlay_id.as_deref() {
                    app_store.remove_local_overlay_item(&key, overlay_id);
                }
                app_store.restore_queued_follow_up_draft_front(&key, draft);
            }
            warn!(
                "MobileClient: failed to autosend queued follow-up for {} thread {}: {}",
                key.server_id, key.thread_id, error
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversation_uniffi::HydratedConversationItemContent;
    use crate::session::connection::TestRequestHandler;
    use crate::store::AppQueuedFollowUpKind;
    use std::sync::{Arc, Mutex as StdMutex};

    fn make_thread_info(id: &str) -> ThreadInfo {
        ThreadInfo {
            id: id.to_string(),
            title: Some("Thread".to_string()),
            model: Some("glm-5.2".to_string()),
            status: ThreadSummaryStatus::Idle,
            preview: None,
            cwd: Some("/tmp".to_string()),
            path: Some("/tmp/thread".to_string()),
            model_provider: Some("local-studio".to_string()),
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            forked_from_id: None,
            agent_status: None,
            created_at: Some(1),
            updated_at: Some(2),
        }
    }

    fn make_server_config(server_id: &str) -> ServerConfig {
        ServerConfig {
            server_id: server_id.to_string(),
            display_name: "Local Studio".to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            websocket_url: Some("ws://127.0.0.1:0".to_string()),
            is_local: false,
            tls: false,
        }
    }

    fn queued_draft(text: &str) -> crate::store::QueuedFollowUpDraft {
        queued_follow_up_draft_from_inputs(
            &[upstream::UserInput::Text {
                text: text.to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::Message,
        )
        .expect("queued draft")
    }

    fn turn_start_response(turn_id: &str) -> serde_json::Value {
        serde_json::json!({
            "turn": {
                "id": turn_id,
                "items": [],
                "itemsView": "full",
                "status": "inProgress",
                "error": null,
                "startedAt": 1,
                "completedAt": null,
                "durationMs": null
            }
        })
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

    #[test]
    fn idle_status_update_releases_a_queued_follow_up() {
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let event = UiEvent::ThreadStatusChanged {
            key: key.clone(),
            notification: upstream::ThreadStatusChangedNotification {
                thread_id: key.thread_id.clone(),
                status: upstream::ThreadStatus::Idle,
            },
        };

        assert_eq!(queued_follow_up_dispatch_key(&event), Some(key));
    }

    #[tokio::test]
    async fn queued_follow_up_dispatch_is_exactly_once_and_preserves_next_message() {
        let app_store = Arc::new(AppStoreReducer::new());
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: "thread-1".to_string(),
        };
        let config = make_server_config(server_id);
        app_store.upsert_server(&config, ServerHealthSnapshot::Connected);
        let mut thread = ThreadSnapshot::from_info(server_id, make_thread_info(&key.thread_id));
        thread.agent_runtime_kind = "local-studio".to_string();
        app_store.upsert_thread_snapshot(thread);
        let mut second = queued_draft("second message");
        second.turn_start_params = Some(upstream::TurnStartParams {
            thread_id: key.thread_id.clone(),
            input: second.inputs.clone(),
            model: Some("glm-5.2".to_string()),
            ..Default::default()
        });
        app_store.enqueue_thread_follow_up_draft(&key, second);
        app_store.enqueue_thread_follow_up_draft(&key, queued_draft("third message"));

        let requests = Arc::new(StdMutex::new(Vec::new()));
        let handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| {
                requests.lock().expect("request log").push(request.clone());
                match request {
                    upstream::ClientRequest::TurnStart { params, .. } => {
                        assert_eq!(params.model.as_deref(), Some("glm-5.2"));
                        assert_eq!(params.approval_policy, Some(upstream::AskForApproval::Never));
                        assert_eq!(
                            params.sandbox_policy,
                            Some(upstream::SandboxPolicy::DangerFullAccess)
                        );
                        Ok(turn_start_response("turn-queued"))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request: {}",
                        other.method()
                    ))),
                }
            })
        };
        sessions.write().expect("sessions lock").insert(
            server_id.to_string(),
            Arc::new(ServerSession::test_stub_with_runtime_handlers(
                config,
                vec![("local-studio".to_string(), handler)],
            )),
        );

        tokio::join!(
            maybe_send_next_local_queued_follow_up(
                Arc::clone(&app_store),
                Arc::clone(&sessions),
                key.clone()
            ),
            maybe_send_next_local_queued_follow_up(
                Arc::clone(&app_store),
                Arc::clone(&sessions),
                key.clone()
            )
        );

        assert_eq!(requests.lock().expect("request log").len(), 1);
        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread");
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-queued"));
        assert_eq!(thread.queued_follow_up_drafts.len(), 1);
        assert_eq!(thread.queued_follow_up_drafts[0].preview.text, "third message");
        assert!(thread.local_overlay_items.iter().any(|item| {
            item.source_turn_id.as_deref() == Some("turn-queued")
                && matches!(
                    &item.content,
                    HydratedConversationItemContent::User(data)
                        if data.text == "second message"
                )
        }));
    }

    #[tokio::test]
    async fn failed_queued_follow_up_dispatch_restores_message_without_a_ghost_turn() {
        let app_store = Arc::new(AppStoreReducer::new());
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: "thread-1".to_string(),
        };
        let config = make_server_config(server_id);
        app_store.upsert_server(&config, ServerHealthSnapshot::Connected);
        let mut thread = ThreadSnapshot::from_info(server_id, make_thread_info(&key.thread_id));
        thread.agent_runtime_kind = "local-studio".to_string();
        app_store.upsert_thread_snapshot(thread);
        app_store.enqueue_thread_follow_up_draft(&key, queued_draft("keep me"));

        let handler: TestRequestHandler = Arc::new(|request| match request {
            upstream::ClientRequest::TurnStart { .. } => {
                Err(RpcError::Transport(TransportError::Disconnected))
            }
            other => Err(RpcError::Deserialization(format!(
                "unexpected request: {}",
                other.method()
            ))),
        });
        sessions.write().expect("sessions lock").insert(
            server_id.to_string(),
            Arc::new(ServerSession::test_stub_with_runtime_handlers(
                config,
                vec![("local-studio".to_string(), handler)],
            )),
        );

        maybe_send_next_local_queued_follow_up(app_store.clone(), sessions, key.clone()).await;

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).expect("thread");
        assert_eq!(thread.active_turn_id, None);
        assert_eq!(thread.info.status, ThreadSummaryStatus::Idle);
        assert_eq!(thread.queued_follow_up_drafts.len(), 1);
        assert_eq!(thread.queued_follow_up_drafts[0].preview.text, "keep me");
        assert!(thread.local_overlay_items.is_empty());
    }

    // Controlled dispatch race: prove a stale/duplicate terminal event for
    // the old turn cannot clear a newer local-queued-turn reservation, and a
    // second drain cannot send concurrently while the first turn/start is in
    // flight. Uses a multi-thread runtime so the first handler can park in
    // `block_in_place` without deadlocking the dispatch future.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stale_terminal_event_cannot_clear_newer_local_queued_reservation() {
        use tokio::sync::{oneshot, Notify};

        let app_store = Arc::new(AppStoreReducer::new());
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: "thread-1".to_string(),
        };
        let config = make_server_config(server_id);
        app_store.upsert_server(&config, ServerHealthSnapshot::Connected);
        let mut thread =
            ThreadSnapshot::from_info(server_id, make_thread_info(&key.thread_id));
        thread.agent_runtime_kind = "local-studio".to_string();
        // Simulate a just-completed prior turn so the old TurnCompleted
        // below is plausibly in-flight: start with no active turn, idle.
        app_store.upsert_thread_snapshot(thread);

        app_store.enqueue_thread_follow_up_draft(&key, queued_draft("first queued"));
        app_store.enqueue_thread_follow_up_draft(&key, queued_draft("second queued"));

        let requests = Arc::new(StdMutex::new(Vec::new()));
        let reservation_installed = Arc::new(Notify::new());
        let (release_tx, release_rx) = oneshot::channel::<()>();
        let release_rx = Arc::new(StdMutex::new(Some(release_rx)));

        let handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            let reservation_installed = Arc::clone(&reservation_installed);
            let release_rx = Arc::clone(&release_rx);
            Arc::new(move |request| {
                requests.lock().expect("request log").push(request.clone());
                // Signal that the atomic reservation has been installed and
                // the turn/start request is now in flight.
                reservation_installed.notify_one();
                // Park the worker thread until the test releases the first
                // request. block_in_place is safe on this multi-thread test
                // runtime and does not deadlock the dispatch future, which
                // is suspended at the response oneshot await.
                let rx = release_rx
                    .lock()
                    .expect("release rx")
                    .take()
                    .expect("release rx consumed once");
                tokio::task::block_in_place(|| {
                    tokio::runtime::Handle::current()
                        .block_on(rx)
                        .expect("release channel");
                });
                Ok(turn_start_response("turn-new"))
            })
        };
        sessions.write().expect("sessions lock").insert(
            server_id.to_string(),
            Arc::new(ServerSession::test_stub_with_runtime_handlers(
                config,
                vec![("local-studio".to_string(), handler)],
            )),
        );

        // Start the first drain. It installs the local-queued-turn
        // reservation, then parks inside the handler at the release gate.
        let first_drain = tokio::spawn(maybe_send_next_local_queued_follow_up(
            Arc::clone(&app_store),
            Arc::clone(&sessions),
            key.clone(),
        ));
        reservation_installed.notified().await;

        // While the first turn/start is parked, the reservation must be
        // authoritative and the thread must look active.
        {
            let snapshot = app_store.snapshot();
            let thread = snapshot.threads.get(&key).expect("thread");
            assert!(
                thread
                    .active_turn_id
                    .as_deref()
                    .is_some_and(|id| id.starts_with("local-queued-turn:")),
                "local reservation must be installed, got {:?}",
                thread.active_turn_id
            );
            assert_eq!(
                thread.info.status,
                ThreadSummaryStatus::Active,
                "thread must be Active while reservation is in flight"
            );
            assert_eq!(
                thread.queued_follow_up_drafts.len(),
                1,
                "exactly one later draft must remain queued"
            );
            assert_eq!(
                thread.queued_follow_up_drafts[0].preview.text,
                "second queued"
            );
        }

        // Apply a duplicate/out-of-order TurnCompleted for the OLD turn, a
        // duplicate Idle status, and a stale SystemError status. None of them
        // must clear the newer reservation or downgrade its Active status.
        app_store.apply_ui_event(&UiEvent::TurnCompleted {
            key: key.clone(),
            turn_id: "turn-old".to_string(),
            error: None,
        });
        app_store.apply_ui_event(&UiEvent::ThreadStatusChanged {
            key: key.clone(),
            notification: upstream::ThreadStatusChangedNotification {
                thread_id: key.thread_id.clone(),
                status: upstream::ThreadStatus::Idle,
            },
        });
        app_store.apply_ui_event(&UiEvent::ThreadStatusChanged {
            key: key.clone(),
            notification: upstream::ThreadStatusChangedNotification {
                thread_id: key.thread_id.clone(),
                status: upstream::ThreadStatus::SystemError,
            },
        });

        {
            let snapshot = app_store.snapshot();
            let thread = snapshot.threads.get(&key).expect("thread");
            assert!(
                thread
                    .active_turn_id
                    .as_deref()
                    .is_some_and(|id| id.starts_with("local-queued-turn:")),
                "stale terminal must not clear the newer reservation, got {:?}",
                thread.active_turn_id
            );
            assert_eq!(
                thread.info.status,
                ThreadSummaryStatus::Active,
                "stale Idle/SystemError must not downgrade an active reservation"
            );
            assert_eq!(
                thread.queued_follow_up_drafts.len(),
                1,
                "stale terminal must not release the queued draft"
            );
        }

        // Attempt a second drain while the first is still parked. The
        // reservation guards it: the second drain must observe Active and
        // send no second request.
        maybe_send_next_local_queued_follow_up(
            Arc::clone(&app_store),
            Arc::clone(&sessions),
            key.clone(),
        )
        .await;
        assert_eq!(
            requests.lock().expect("request log").len(),
            1,
            "exactly one turn/start must be in flight"
        );

        // Release the first request. It resolves to the returned turn id
        // without a duplicate send.
        release_tx.send(()).expect("release first request");
        first_drain.await.expect("first drain completes");

        assert_eq!(
            requests.lock().expect("request log").len(),
            1,
            "no duplicate send after release"
        );
        {
            let snapshot = app_store.snapshot();
            let thread = snapshot.threads.get(&key).expect("thread");
            assert_eq!(
                thread.active_turn_id.as_deref(),
                Some("turn-new"),
                "reservation must resolve to the returned turn id"
            );
            assert_eq!(thread.queued_follow_up_drafts.len(), 1);
        }
    }
}
