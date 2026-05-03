use super::*;
use codex_ipc::{BridgeEvent, BridgeOutput, IpcBridge};
use codex_utils_absolute_path::{AbsolutePathBuf, AbsolutePathBufGuard};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

enum IpcStreamProcessorMessage {
    StreamEvent(ThreadStreamStateChangedParams),
    Recovery(PendingIpcStreamRecovery),
    StaleTurnCheck,
}

const IPC_STREAM_BATCH_COLLECT_WINDOW: Duration = Duration::from_millis(50);
const IPC_STALE_TURN_CHECK_INTERVAL: Duration = Duration::from_secs(5);
const IPC_STALE_TURN_QUIET_THRESHOLD: Duration = Duration::from_secs(5);
const PATH_FIELD_KEYS: &[&str] = &[
    "agentPath",
    "cwd",
    "destinationPath",
    "instructionSources",
    "marketplacePath",
    "movePath",
    "path",
    "readableRoots",
    "savedPath",
    "sourcePath",
    "writableRoots",
];

struct IpcStreamProcessorState {
    bridge: IpcBridge,
    pending_thread_events: HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    recovering_threads: HashSet<String>,
}

impl Default for IpcStreamProcessorState {
    fn default() -> Self {
        Self {
            bridge: IpcBridge::new(),
            pending_thread_events: HashMap::new(),
            recovering_threads: HashSet::new(),
        }
    }
}

fn session_is_current(
    sessions: &Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
    session: &Arc<ServerSession>,
) -> bool {
    sessions
        .read()
        .ok()
        .and_then(|guard| guard.get(server_id).cloned())
        .is_some_and(|current| Arc::ptr_eq(&current, session))
}

impl MobileClient {
    pub(super) fn spawn_event_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let mut events = session.events();
        let processor = Arc::clone(&self.event_processor);
        let recorder = Arc::clone(&self.recorder);
        let oauth_callback_tunnels = Arc::clone(&self.oauth_callback_tunnels);
        let oauth_session = Arc::clone(&session);
        let sessions = Arc::clone(&self.sessions);
        let app_store = Arc::clone(&self.app_store);
        let widget_waiters = Arc::clone(&self.widget_waiters);
        let saved_apps_directory = Arc::clone(&self.saved_apps_directory);
        Self::spawn_detached(async move {
            loop {
                let event = events.recv().await;
                if !session_is_current(&sessions, &server_id, &oauth_session) {
                    info!("event reader exiting for stale server session {server_id}");
                    break;
                }
                match event {
                    Ok(ServerEvent::Notification {
                        runtime_kind,
                        notification,
                    }) => {
                        note_notification_runtime(
                            &app_store,
                            &server_id,
                            runtime_kind,
                            &notification,
                        );
                        if let upstream::ServerNotification::AccountLoginCompleted(payload) =
                            &notification
                        {
                            let maybe_tunnel = {
                                let mut tunnels = oauth_callback_tunnels.lock().await;
                                match payload.login_id.as_deref() {
                                    Some(login_id)
                                        if tunnels
                                            .get(&server_id)
                                            .map(|existing| existing.login_id.as_str())
                                            == Some(login_id) =>
                                    {
                                        tunnels.remove(&server_id)
                                    }
                                    _ => None,
                                }
                            };
                            if let Some(tunnel) = maybe_tunnel
                                && let Some(ssh_client) = oauth_session.ssh_client()
                            {
                                ssh_client.abort_forward_port(tunnel.local_port).await;
                            }
                        }
                        debug!(
                            "event reader server_id={} notification={:?}",
                            server_id, notification
                        );
                        recorder.record_notification(&server_id, &notification);
                        processor.process_notification(&server_id, &notification);
                        note_notification_runtime(
                            &app_store,
                            &server_id,
                            runtime_kind,
                            &notification,
                        );
                    }
                    Ok(ServerEvent::LegacyNotification {
                        runtime_kind: _,
                        method,
                        params,
                    }) => {
                        debug!(
                            "event reader server_id={} legacy_method={} params={}",
                            server_id, method, params
                        );
                        processor.process_legacy_notification(&server_id, &method, &params);
                    }
                    Ok(ServerEvent::Request {
                        runtime_kind,
                        request,
                    }) => {
                        debug!("event reader server_id={} request={:?}", server_id, request);
                        let dynamic_tool_request = match &request {
                            upstream::ServerRequest::DynamicToolCall { request_id, params } => {
                                Some((request_id.clone(), params.clone()))
                            }
                            _ => None,
                        };
                        processor.process_server_request(&server_id, &request);
                        if let Some((request_id, params)) = dynamic_tool_request {
                            let server_id = server_id.clone();
                            let session = Arc::clone(&oauth_session);
                            let sessions = Arc::clone(&sessions);
                            let app_store = Arc::clone(&app_store);
                            let widget_waiters = Arc::clone(&widget_waiters);
                            let saved_apps_directory = Arc::clone(&saved_apps_directory);
                            MobileClient::spawn_detached(async move {
                                if let Err(error) = handle_dynamic_tool_call_request(
                                    session,
                                    sessions,
                                    app_store,
                                    widget_waiters,
                                    saved_apps_directory,
                                    request_id,
                                    params,
                                    runtime_kind,
                                )
                                .await
                                {
                                    warn!(
                                        "MobileClient: failed to handle dynamic tool call on {}: {}",
                                        server_id, error
                                    );
                                }
                            });
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        info!("event stream closed for {server_id}");
                        break;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(
                            "event reader lagged server_id={} skipped={}",
                            server_id, skipped
                        );
                    }
                }
            }
        });
    }

    pub(super) fn spawn_health_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let mut health_rx = session.health();
        let processor = Arc::clone(&self.event_processor);
        let sessions = Arc::clone(&self.sessions);
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            if !session_is_current(&sessions, &server_id, &session) {
                info!("health reader exiting for stale server session {server_id}");
                return;
            }
            processor.emit_connection_state(&server_id, "connecting");
            // Initialize as if previously Connected so the first observation —
            // which after a successful connect_* call is normally Connected —
            // does not double-fire alongside spawn_post_connect_warmup. A real
            // disconnect/reconnect cycle still triggers the transition below.
            let mut prev_connected: bool = true;
            loop {
                if !session_is_current(&sessions, &server_id, &session) {
                    info!("health reader exiting for stale server session {server_id}");
                    break;
                }
                let health = health_rx.borrow().clone();
                let is_connected = matches!(
                    health,
                    crate::session::connection::ConnectionHealth::Connected
                );
                let health_wire = match health {
                    crate::session::connection::ConnectionHealth::Disconnected => "disconnected",
                    crate::session::connection::ConnectionHealth::Connecting { .. } => "connecting",
                    crate::session::connection::ConnectionHealth::Connected => "connected",
                    crate::session::connection::ConnectionHealth::Unresponsive { .. } => {
                        "unresponsive"
                    }
                };
                processor.emit_connection_state(&server_id, health_wire);

                if !prev_connected && is_connected {
                    let session = sessions
                        .read()
                        .ok()
                        .and_then(|guard| guard.get(&server_id).cloned());
                    if let Some(session) = session {
                        run_connect_warmup(
                            Arc::clone(&sessions),
                            Arc::clone(&app_store),
                            server_id.clone(),
                            session,
                            "reconnect",
                        );
                    }
                }
                prev_connected = is_connected;

                if health_rx.changed().await.is_err() {
                    break;
                }
            }
        });
    }

    pub(super) fn spawn_ipc_connection_state_reader(
        &self,
        server_id: String,
        session: Arc<ServerSession>,
    ) {
        let Some(mut ipc_state_rx) = session.ipc_connection_state() else {
            return;
        };
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            loop {
                let has_ipc = *ipc_state_rx.borrow();
                app_store.update_server_ipc_state(&server_id, has_ipc);
                if ipc_state_rx.changed().await.is_err() {
                    break;
                }
            }
        });
    }

    pub(super) fn spawn_ipc_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let Some(mut broadcasts) = session.ipc_broadcasts() else {
            return;
        };
        let app_store = Arc::clone(&self.app_store);
        let loop_server_id = server_id.clone();
        let processor_state = Arc::new(StdMutex::new(IpcStreamProcessorState::default()));
        let (stream_processor_tx, mut stream_processor_rx) =
            mpsc::unbounded_channel::<IpcStreamProcessorMessage>();
        Self::spawn_detached(async move {
            let (recovery_tx, mut recovery_rx) =
                mpsc::unbounded_channel::<PendingIpcStreamRecovery>();
            {
                let processor_state = Arc::clone(&processor_state);
                let processor_session = Arc::clone(&session);
                let processor_app_store = Arc::clone(&app_store);
                let processor_server_id = loop_server_id.clone();
                let processor_recovery_tx = recovery_tx.clone();
                MobileClient::spawn_detached(async move {
                    let mut stale_turn_interval =
                        tokio::time::interval(IPC_STALE_TURN_CHECK_INTERVAL);
                    stale_turn_interval
                        .set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                    // Skip the first immediate tick.
                    stale_turn_interval.tick().await;
                    loop {
                        let first_message = tokio::select! {
                            maybe_message = stream_processor_rx.recv() => {
                                let Some(message) = maybe_message else {
                                    break;
                                };
                                message
                            }
                            maybe_recovery = recovery_rx.recv() => {
                                let Some(recovery) = maybe_recovery else {
                                    continue;
                                };
                                IpcStreamProcessorMessage::Recovery(recovery)
                            }
                            _ = stale_turn_interval.tick() => {
                                IpcStreamProcessorMessage::StaleTurnCheck
                            }
                        };
                        let mut messages = vec![first_message];
                        let batch_deadline = Instant::now() + IPC_STREAM_BATCH_COLLECT_WINDOW;
                        loop {
                            while let Ok(message) = stream_processor_rx.try_recv() {
                                messages.push(message);
                            }
                            while let Ok(recovery) = recovery_rx.try_recv() {
                                messages.push(IpcStreamProcessorMessage::Recovery(recovery));
                            }

                            let now = Instant::now();
                            if now >= batch_deadline {
                                break;
                            }

                            let remaining = batch_deadline.saturating_duration_since(now);
                            let next_message = tokio::time::timeout(remaining, async {
                                tokio::select! {
                                    maybe_message = stream_processor_rx.recv() => maybe_message,
                                    maybe_recovery = recovery_rx.recv() => {
                                        maybe_recovery.map(IpcStreamProcessorMessage::Recovery)
                                    }
                                }
                            })
                            .await
                            .ok()
                            .flatten();

                            let Some(message) = next_message else {
                                break;
                            };
                            messages.push(message);
                        }

                        let processor_state = Arc::clone(&processor_state);
                        let processor_session = Arc::clone(&processor_session);
                        let processor_app_store = Arc::clone(&processor_app_store);
                        let processor_server_id = processor_server_id.clone();
                        let processor_server_id_for_log = processor_server_id.clone();
                        let processor_recovery_tx = processor_recovery_tx.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            let mut state = processor_state
                                .lock()
                                .expect("ipc stream processor state poisoned");
                            process_ipc_stream_processor_messages(
                                &mut state,
                                messages,
                                processor_session,
                                processor_app_store,
                                &processor_server_id,
                                &processor_recovery_tx,
                            );
                        })
                        .await;

                        if let Err(error) = result {
                            warn!(
                                "MobileClient: IPC stream processor task failed on {}: {}",
                                processor_server_id_for_log, error
                            );
                        }
                    }
                });
            }
            loop {
                tokio::select! {
                    broadcast = broadcasts.recv() => match broadcast {
                        Ok(TypedBroadcast::ThreadStreamStateChanged(params)) => {
                            app_store.note_server_ipc_broadcast(&loop_server_id);

                            if !app_store.is_server_ipc_primary(&loop_server_id) {
                                debug!(
                                    "IPC in: ignoring ThreadStreamStateChanged for server={} thread={} because authority is not IPC-primary",
                                    loop_server_id, params.conversation_id
                                );
                                continue;
                            }
                            let change_type = match &params.change {
                                StreamChange::Snapshot { .. } => "snapshot",
                                StreamChange::Patches { .. } => "patches",
                            };
                            debug!(
                                "IPC in: ThreadStreamStateChanged server={} thread={} protocol_version={} change={}",
                                loop_server_id, params.conversation_id, params.version, change_type
                            );
                            if stream_processor_tx
                                .send(IpcStreamProcessorMessage::StreamEvent(params))
                                .is_err()
                            {
                                warn!(
                                    "MobileClient: IPC stream processor channel closed for {}",
                                    loop_server_id
                                );
                                break;
                            }
                        }
                        Ok(TypedBroadcast::ThreadArchived(ref params)) => {
                            if let Ok(mut state) = processor_state.lock() {
                                state.bridge.remove_thread(&params.conversation_id);
                                state.pending_thread_events.remove(&params.conversation_id);
                                state.recovering_threads.remove(&params.conversation_id);
                            }
                            debug!(
                                "IPC in: ThreadArchived server={} thread={}",
                                loop_server_id, params.conversation_id
                            );
                            if let Err(error) = refresh_thread_list_from_app_server(
                                Arc::clone(&session),
                                Arc::clone(&app_store),
                                &loop_server_id,
                            )
                            .await
                            {
                                warn!(
                                    "MobileClient: failed to refresh IPC thread list on {}: {}",
                                    loop_server_id, error
                                );
                            }
                        }
                        Ok(TypedBroadcast::ThreadUnarchived(_))
                        | Ok(TypedBroadcast::QueryCacheInvalidate(_)) => {
                            debug!(
                                "IPC in: thread list change broadcast server={}",
                                loop_server_id
                            );
                            if let Err(error) = refresh_thread_list_from_app_server(
                                Arc::clone(&session),
                                Arc::clone(&app_store),
                                &loop_server_id,
                            )
                            .await
                            {
                                warn!(
                                    "MobileClient: failed to refresh IPC thread list on {}: {}",
                                    loop_server_id, error
                                );
                            }
                        }
                        Ok(TypedBroadcast::ThreadQueuedFollowupsChanged(params)) => {
                            app_store.note_server_ipc_broadcast(&loop_server_id);
                            if !app_store.is_server_ipc_primary(&loop_server_id) {
                                debug!(
                                    "IPC in: ignoring ThreadQueuedFollowupsChanged for server={} thread={} because authority is not IPC-primary",
                                    loop_server_id, params.conversation_id
                                );
                                continue;
                            }
                            let drafts = queued_follow_up_drafts_from_message_values(&params.messages);
                            debug!(
                                "IPC in: ThreadQueuedFollowupsChanged server={} thread={} previews={}",
                                loop_server_id,
                                params.conversation_id,
                                drafts.len()
                            );
                            let key = ThreadKey {
                                server_id: loop_server_id.clone(),
                                thread_id: params.conversation_id,
                            };
                            let keep_local_drafts = drafts.is_empty()
                                && app_store.server_pending_mutation_kind(&loop_server_id)
                                    == Some(ServerMutatingCommandKind::SetQueuedFollowUpsState)
                                && app_store.thread_snapshot(&key).is_some_and(|thread| {
                                    thread.active_turn_id.is_some()
                                        && !thread.queued_follow_up_drafts.is_empty()
                                });
                            if keep_local_drafts {
                                debug!(
                                    "IPC in: ignoring empty ThreadQueuedFollowupsChanged for server={} thread={} while local queued follow-up mutation is still pending",
                                    loop_server_id, key.thread_id
                                );
                                continue;
                            }
                            app_store.set_thread_follow_up_drafts(&key, drafts);
                        }
                        Ok(TypedBroadcast::ClientStatusChanged(params)) => {
                            debug!(
                                "IPC in: ClientStatusChanged server={} client_type={} status={:?}",
                                loop_server_id, params.client_type, params.status
                            );
                            if params.client_type != "mobile" {
                                match params.status {
                                    ClientStatus::Connected => {
                                        app_store.update_server_ipc_state(&loop_server_id, true);
                                    }
                                    ClientStatus::Disconnected => {
                                        app_store.update_server_ipc_state(&loop_server_id, false);
                                    }
                                }
                            }
                        }
                        Ok(TypedBroadcast::Unknown { method, .. }) => {
                            debug!(
                                "MobileClient: ignoring unknown IPC broadcast for {} method={}",
                                loop_server_id, method
                            );
                        }
                        Err(broadcast::error::RecvError::Closed) => {
                            info!("IPC in: broadcast stream closed server={}", loop_server_id);
                            app_store.update_server_ipc_state(&loop_server_id, false);
                            break;
                        }
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            warn!("MobileClient: lagged {skipped} IPC events for {loop_server_id}");
                            if let Ok(mut state) = processor_state.lock() {
                                state.bridge.reset();
                                state.pending_thread_events.clear();
                                state.recovering_threads.clear();
                            }
                        }
                    }
                }
            }
        });
    }

    pub(super) fn mark_server_transport_disconnected(&self, server_id: &str) {
        self.clear_direct_resume_markers_for_server(server_id);
        self.app_store
            .update_server_health(server_id, ServerHealthSnapshot::Disconnected);
        self.app_store.update_server_ipc_state(server_id, false);
        self.app_store.fail_server_over_to_direct_only(
            server_id,
            IpcFailureClassification::IpcConnectionLost,
        );
    }

    pub(super) fn reconcile_transport_error(&self, server_id: &str, error: &RpcError) {
        if matches!(error, RpcError::Transport(_)) {
            self.mark_server_transport_disconnected(server_id);
        }
    }

    pub(crate) fn get_session(&self, server_id: &str) -> Result<Arc<ServerSession>, RpcError> {
        self.sessions_read().get(server_id).cloned().ok_or_else(|| {
            self.mark_server_transport_disconnected(server_id);
            RpcError::Transport(TransportError::Disconnected)
        })
    }

    /// Send a raw `ClientRequest` and return the JSON response value.
    /// Used by tooling (e.g. fixture export) that needs raw upstream data.
    pub async fn request_raw_for_server(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<serde_json::Value, String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session.request_client(request).await.map_err(|error| {
            self.reconcile_transport_error(server_id, &error);
            error.to_string()
        })
    }

    /// Return the configs of all currently connected servers (public for tooling).
    pub fn connected_server_configs(&self) -> Vec<ServerConfig> {
        self.sessions_read()
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    pub(crate) fn snapshot_thread(&self, key: &ThreadKey) -> Result<ThreadSnapshot, RpcError> {
        self.app_store
            .snapshot()
            .threads
            .get(key)
            .cloned()
            .ok_or_else(|| RpcError::Deserialization(format!("unknown thread {}", key.thread_id)))
    }

    pub async fn request_typed_for_server<R>(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<R, String>
    where
        R: serde::de::DeserializeOwned,
    {
        let runtime_kind = self.runtime_for_request(server_id, &request);
        self.request_typed_for_server_runtime(server_id, runtime_kind, request)
            .await
    }

    pub async fn request_typed_for_server_runtime<R>(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        request: upstream::ClientRequest,
    ) -> Result<R, String>
    where
        R: serde::de::DeserializeOwned,
    {
        let mut request = request;
        self.normalize_model_selection_for_request(server_id, runtime_kind, &mut request);
        self.recorder.record_request(server_id, &request);
        let wire_method = client_request_wire_method(&request);
        let started_at = Instant::now();
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        info!(
            "server request start server_id={} runtime={:?} method={}",
            server_id, runtime_kind, wire_method
        );
        let value = session
            .request_client_for_runtime(runtime_kind, request)
            .await
            .map_err(|error| {
                self.reconcile_transport_error(server_id, &error);
                warn!(
                    "server request failed server_id={} runtime={:?} method={} duration_ms={} error={}",
                    server_id,
                    runtime_kind,
                    wire_method,
                    started_at.elapsed().as_millis(),
                    error
                );
                error.to_string()
            })?;
        info!(
            "server request ok server_id={} runtime={:?} method={} duration_ms={}",
            server_id,
            runtime_kind,
            wire_method,
            started_at.elapsed().as_millis()
        );
        self.app_store.note_server_direct_request_success(server_id);
        let (parsed, legacy_permission_profile) =
            deserialize_typed_response_with_legacy_flag(&value);
        if legacy_permission_profile {
            // v0.124 remotes never support turn pagination — mark the
            // capability off as soon as we recognise the legacy shape so
            // downstream code paths (load_thread_turns_page) short-circuit
            // instead of waiting for the runtime -32601 probe.
            self.app_store
                .set_server_supports_turn_pagination(server_id, false);
        }
        parsed.map_err(|e| {
            let error = format_typed_rpc_deserialization_error(wire_method, &e, &value);
            warn!("{error}\nraw payload: {value}");
            error
        })
    }

    fn runtime_for_request(
        &self,
        server_id: &str,
        request: &upstream::ClientRequest,
    ) -> AgentRuntimeKind {
        if let upstream::ClientRequest::ThreadStart { params, .. } = request {
            return self.runtime_for_thread_start(server_id, None, params.model.as_deref());
        }

        let thread_id = match request {
            upstream::ClientRequest::ThreadRead { params, .. } => Some(params.thread_id.as_str()),
            upstream::ClientRequest::ThreadResume { params, .. } => Some(params.thread_id.as_str()),
            upstream::ClientRequest::ThreadFork { params, .. } => Some(params.thread_id.as_str()),
            upstream::ClientRequest::ThreadRollback { params, .. } => {
                Some(params.thread_id.as_str())
            }
            upstream::ClientRequest::ThreadUnsubscribe { params, .. } => {
                Some(params.thread_id.as_str())
            }
            upstream::ClientRequest::ThreadArchive { params, .. } => {
                Some(params.thread_id.as_str())
            }
            upstream::ClientRequest::ThreadSetName { params, .. } => {
                Some(params.thread_id.as_str())
            }
            upstream::ClientRequest::ThreadTurnsList { params, .. } => {
                Some(params.thread_id.as_str())
            }
            upstream::ClientRequest::TurnStart { params, .. } => Some(params.thread_id.as_str()),
            upstream::ClientRequest::TurnSteer { params, .. } => Some(params.thread_id.as_str()),
            _ => None,
        };
        thread_id
            .map(|thread_id| {
                self.runtime_for_thread(&ThreadKey {
                    server_id: server_id.to_string(),
                    thread_id: thread_id.to_string(),
                })
            })
            .unwrap_or(AgentRuntimeKind::Codex)
    }

    pub(super) fn pending_approval(&self, request_id: &str) -> Result<PendingApproval, RpcError> {
        self.app_store
            .snapshot()
            .pending_approvals
            .into_iter()
            .find(|approval| approval.id == request_id)
            .ok_or_else(|| {
                RpcError::Deserialization(format!("unknown approval request {request_id}"))
            })
    }

    pub(super) fn pending_user_input(
        &self,
        request_id: &str,
    ) -> Result<PendingUserInputRequest, RpcError> {
        self.app_store
            .snapshot()
            .pending_user_inputs
            .into_iter()
            .find(|request| request.id == request_id)
            .ok_or_else(|| {
                RpcError::Deserialization(format!("unknown user input request {request_id}"))
            })
    }

    pub(crate) fn spawn_detached<F>(future: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(future);
        } else {
            // Route detached mobile work onto the shared runtime instead of
            // creating ad-hoc current-thread runtimes with tiny iOS stacks.
            crate::ffi::shared::shared_runtime().spawn(future);
        }
    }
}

fn deserialize_typed_response<R>(value: &serde_json::Value) -> Result<R, serde_json::Error>
where
    R: serde::de::DeserializeOwned,
{
    let (result, _legacy) = deserialize_typed_response_with_legacy_flag(value);
    result
}

/// Returns the deserialized response and a flag indicating whether the
/// legacy pre-v0.125 `PermissionProfile` struct shape was detected anywhere
/// in the payload. Callers can use the flag to flip server capability
/// bookkeeping (e.g. `supports_turn_pagination = false`) before further
/// processing.
fn deserialize_typed_response_with_legacy_flag<R>(
    value: &serde_json::Value,
) -> (Result<R, serde_json::Error>, bool)
where
    R: serde::de::DeserializeOwned,
{
    let mut normalized = value.clone();
    let legacy_permission_profile = normalize_legacy_permission_profile_fields(&mut normalized);
    normalize_empty_cwd_fields(&mut normalized, None);
    normalize_default_service_tier(&mut normalized);
    normalize_dynamic_tool_content_item_aliases(&mut normalized);
    normalize_command_action_aliases(&mut normalized);
    normalize_relative_absolute_path_fields(&mut normalized, None);
    let parsed = if let Some(base_path) = response_deserialization_base(&normalized) {
        let _guard = AbsolutePathBufGuard::new(base_path.as_path());
        serde_json::from_value(normalized)
    } else {
        serde_json::from_value(normalized)
    };
    (parsed, legacy_permission_profile)
}

fn normalize_empty_cwd_fields(value: &mut serde_json::Value, inherited_base: Option<&Path>) {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(serde_json::Value::String(cwd)) = map.get_mut("cwd")
                && cwd.is_empty()
            {
                *cwd = inherited_base
                    .map(|base| base.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "/".to_string());
            }
            let local_base = absolute_path_from_value(map.get("cwd"))
                .or_else(|| inherited_base.map(Path::to_path_buf));
            let next_base = local_base.as_deref();
            for child in map.values_mut() {
                normalize_empty_cwd_fields(child, next_base);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                normalize_empty_cwd_fields(child, inherited_base);
            }
        }
        _ => {}
    }
}

fn normalize_default_service_tier(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(service_tier) = map.get_mut("serviceTier")
                && service_tier.as_str() == Some("default")
            {
                *service_tier = serde_json::Value::Null;
            }
            for child in map.values_mut() {
                normalize_default_service_tier(child);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                normalize_default_service_tier(child);
            }
        }
        _ => {}
    }
}

fn normalize_dynamic_tool_content_item_aliases(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(serde_json::Value::Array(items)) = map.get_mut("contentItems") {
                for item in items {
                    if let Some(item_map) = item.as_object_mut() {
                        let kind = item_map
                            .get("type")
                            .and_then(|value| value.as_str())
                            .map(str::to_string);
                        if kind.is_none() {
                            let text = item_map
                                .get("text")
                                .and_then(|text| text.as_str())
                                .map(str::to_string)
                                .or_else(|| {
                                    item_map
                                        .get("file")
                                        .and_then(|file| file.get("content"))
                                        .and_then(|content| content.as_str())
                                        .map(str::to_string)
                                })
                                .unwrap_or_else(|| {
                                    serde_json::to_string(&serde_json::Value::Object(
                                        item_map.clone(),
                                    ))
                                    .unwrap_or_default()
                                });
                            item_map.insert(
                                "type".to_string(),
                                serde_json::Value::String("inputText".to_string()),
                            );
                            item_map.insert("text".to_string(), serde_json::Value::String(text));
                        }
                        if matches!(kind.as_deref(), Some("text" | "inputText"))
                            && !item_map.contains_key("text")
                            && let Some(text) = item_map
                                .get("file")
                                .and_then(|file| file.get("content"))
                                .and_then(|content| content.as_str())
                                .map(str::to_string)
                        {
                            item_map.insert("text".to_string(), serde_json::Value::String(text));
                        }
                        if let Some(serde_json::Value::String(kind)) = item_map.get_mut("type") {
                            match kind.as_str() {
                                "text" => *kind = "inputText".to_string(),
                                "image" => *kind = "inputImage".to_string(),
                                _ => {}
                            }
                        }
                    }
                }
            }

            for child in map.values_mut() {
                normalize_dynamic_tool_content_item_aliases(child);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                normalize_dynamic_tool_content_item_aliases(child);
            }
        }
        _ => {}
    }
}

fn normalize_command_action_aliases(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            if object_type(map) == Some("commandExecution") {
                let parent_command = map
                    .get("command")
                    .and_then(|value| value.as_str())
                    .unwrap_or_default()
                    .to_string();
                if let Some(serde_json::Value::Array(actions)) = map.get_mut("commandActions") {
                    for action in actions {
                        normalize_command_action(action, &parent_command);
                    }
                }
            }

            for child in map.values_mut() {
                normalize_command_action_aliases(child);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                normalize_command_action_aliases(child);
            }
        }
        _ => {}
    }
}

fn normalize_command_action(action: &mut serde_json::Value, parent_command: &str) {
    let Some(map) = action.as_object_mut() else {
        return;
    };
    if let Some(serde_json::Value::String(kind)) = map.get_mut("type")
        && kind == "list_files"
    {
        *kind = "listFiles".to_string();
    }

    let command = map
        .get("command")
        .and_then(|value| value.as_str())
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| infer_command_action_command(map, parent_command));
    if !matches!(
        map.get("command"),
        Some(serde_json::Value::String(value)) if !value.is_empty()
    ) {
        map.insert(
            "command".to_string(),
            serde_json::Value::String(command.clone()),
        );
    }

    if object_type(map) == Some("read") && !map.contains_key("name") {
        map.insert(
            "name".to_string(),
            serde_json::Value::String(infer_command_action_name(map)),
        );
    }
}

fn infer_command_action_command(
    map: &serde_json::Map<String, serde_json::Value>,
    parent_command: &str,
) -> String {
    if !parent_command.is_empty() {
        return parent_command.to_string();
    }
    match object_type(map) {
        Some("read") => map
            .get("path")
            .and_then(|value| value.as_str())
            .map(|path| format!("read {path}"))
            .unwrap_or_else(|| "read".to_string()),
        Some("search") => map
            .get("query")
            .and_then(|value| value.as_str())
            .map(|query| format!("grep {query}"))
            .unwrap_or_else(|| "search".to_string()),
        Some("listFiles") => map
            .get("path")
            .and_then(|value| value.as_str())
            .map(|path| format!("ls {path}"))
            .unwrap_or_else(|| "ls".to_string()),
        _ => "unknown".to_string(),
    }
}

fn infer_command_action_name(map: &serde_json::Map<String, serde_json::Value>) -> String {
    map.get("name")
        .and_then(|value| value.as_str())
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .or_else(|| {
            map.get("path")
                .and_then(|value| value.as_str())
                .and_then(|path| {
                    path.rsplit(['/', '\\'])
                        .find(|part| !part.is_empty())
                        .map(str::to_string)
                })
        })
        .unwrap_or_else(|| "file".to_string())
}

/// Walk the JSON tree and upgrade any legacy v0.124 `PermissionProfile`
/// struct shape into the v0.125 tagged-enum shape. Legacy payloads omit the
/// `type` discriminator entirely; the only legacy shape encountered in the
/// wild is equivalent to the new `Managed { network, fileSystem }` variant.
///
/// Also upgrades the inner `PermissionProfileFileSystemPermissions` (the
/// value under `fileSystem`) which was similarly refactored into a tagged
/// enum — legacy servers always sent the equivalent of `Restricted`.
///
/// Returns `true` if any legacy shape was patched, so the caller can mark
/// the server as pre-pagination (belt-and-suspenders alongside the
/// runtime `-32601` probe).
fn normalize_legacy_permission_profile_fields(value: &mut serde_json::Value) -> bool {
    let mut found_legacy = false;
    visit_permission_profile_fields(value, &mut found_legacy);
    found_legacy
}

fn visit_permission_profile_fields(value: &mut serde_json::Value, found_legacy: &mut bool) {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(profile) = map.get_mut("permissionProfile")
                && upgrade_legacy_permission_profile(profile)
            {
                *found_legacy = true;
            }
            for child in map.values_mut() {
                visit_permission_profile_fields(child, found_legacy);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                visit_permission_profile_fields(child, found_legacy);
            }
        }
        _ => {}
    }
}

/// If `profile` looks like the legacy v0.124 `PermissionProfile` struct
/// shape (object with no `type` discriminator), upgrade it in-place to the
/// v0.125 `Managed` variant. Returns true when an upgrade occurred.
fn upgrade_legacy_permission_profile(profile: &mut serde_json::Value) -> bool {
    let Some(map) = profile.as_object_mut() else {
        return false;
    };
    if map.contains_key("type") {
        return false;
    }
    // Legacy shape: `{ "fileSystem": {...}, "network": {...} }`.
    // v0.125 equivalent is `Managed { network, fileSystem }`.
    if let Some(file_system) = map.get_mut("fileSystem") {
        upgrade_legacy_file_system_permissions(file_system);
    }
    // `PermissionProfileNetworkPermissions.enabled` tightened from
    // Option<bool> to bool in v0.125. Defensive: if a legacy server ever
    // sent an explicit `null`, coerce to `false`.
    if let Some(network) = map.get_mut("network")
        && let Some(network_map) = network.as_object_mut()
        && network_map.get("enabled").is_some_and(|v| v.is_null())
    {
        network_map.insert("enabled".to_string(), serde_json::Value::Bool(false));
    }
    map.insert(
        "type".to_string(),
        serde_json::Value::String("managed".to_string()),
    );
    true
}

/// Legacy `fileSystem` payloads always used the equivalent of the new
/// `Restricted { entries, glob_scan_max_depth? }` variant (no `type`).
fn upgrade_legacy_file_system_permissions(value: &mut serde_json::Value) {
    let Some(map) = value.as_object_mut() else {
        return;
    };
    if map.contains_key("type") {
        return;
    }
    map.insert(
        "type".to_string(),
        serde_json::Value::String("restricted".to_string()),
    );
}

fn response_deserialization_base(value: &serde_json::Value) -> Option<PathBuf> {
    match value {
        serde_json::Value::Object(map) => absolute_path_from_value(map.get("cwd"))
            .or_else(|| map.get("thread").and_then(response_deserialization_base)),
        _ => None,
    }
}

fn normalize_relative_absolute_path_fields(
    value: &mut serde_json::Value,
    inherited_base: Option<&Path>,
) {
    match value {
        serde_json::Value::Object(map) => {
            normalize_relative_string_field(map, "cwd", inherited_base);
            let local_base = absolute_path_from_value(map.get("cwd"))
                .or_else(|| inherited_base.map(Path::to_path_buf));

            if let Some(base_path) = local_base.as_deref() {
                normalize_relative_string_array_field(map, "instructionSources", base_path);
                normalize_relative_string_array_field(map, "readableRoots", base_path);
                normalize_relative_string_array_field(map, "writableRoots", base_path);
                normalize_relative_string_field(map, "agentPath", Some(base_path));
                normalize_relative_string_field(map, "destinationPath", Some(base_path));
                normalize_relative_string_field(map, "marketplacePath", Some(base_path));
                normalize_relative_string_field(map, "movePath", Some(base_path));
                normalize_relative_string_field(map, "savedPath", Some(base_path));
                normalize_relative_string_field(map, "sourcePath", Some(base_path));

                match object_type(map) {
                    Some("imageView") | Some("read") => {
                        normalize_relative_string_field(map, "path", Some(base_path));
                    }
                    _ => {}
                }
            }

            let next_base = local_base.as_deref();
            for child in map.values_mut() {
                normalize_relative_absolute_path_fields(child, next_base);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                normalize_relative_absolute_path_fields(child, inherited_base);
            }
        }
        _ => {}
    }
}

fn normalize_relative_string_field(
    map: &mut serde_json::Map<String, serde_json::Value>,
    key: &str,
    base_path: Option<&Path>,
) {
    let Some(base_path) = base_path else {
        return;
    };
    let Some(serde_json::Value::String(text)) = map.get_mut(key) else {
        return;
    };
    if looks_cross_platform_absolute(text) {
        return;
    }

    *text = absolutize_relative_text(text, base_path);
}

fn normalize_relative_string_array_field(
    map: &mut serde_json::Map<String, serde_json::Value>,
    key: &str,
    base_path: &Path,
) {
    let Some(serde_json::Value::Array(items)) = map.get_mut(key) else {
        return;
    };
    for item in items {
        let serde_json::Value::String(text) = item else {
            continue;
        };
        if looks_cross_platform_absolute(text) {
            continue;
        }

        *text = absolutize_relative_text(text, base_path);
    }
}

fn absolutize_relative_text(text: &str, base_path: &Path) -> String {
    AbsolutePathBuf::resolve_path_against_base(text, base_path)
        .to_string_lossy()
        .into_owned()
}

fn absolute_path_from_value(value: Option<&serde_json::Value>) -> Option<PathBuf> {
    let serde_json::Value::String(text) = value? else {
        return None;
    };
    if looks_cross_platform_absolute(text) {
        Some(PathBuf::from(text))
    } else {
        None
    }
}

fn object_type(map: &serde_json::Map<String, serde_json::Value>) -> Option<&str> {
    match map.get("type") {
        Some(serde_json::Value::String(tag)) => Some(tag.as_str()),
        _ => None,
    }
}

fn format_typed_rpc_deserialization_error(
    wire_method: &str,
    error: &serde_json::Error,
    value: &serde_json::Value,
) -> String {
    let mut message = format!("deserialize typed RPC response: {error}");
    if error
        .to_string()
        .contains("AbsolutePathBuf deserialized without a base path")
    {
        let suspects = suspicious_relative_path_entries(value);
        if !suspects.is_empty() {
            message.push_str("; suspicious relative path fields: ");
            message.push_str(&suspects.join(", "));
        } else {
            message.push_str("; no relative values found in known path fields");
        }
    }
    format!("{message} [method={wire_method}]")
}

fn suspicious_relative_path_entries(value: &serde_json::Value) -> Vec<String> {
    let mut entries = Vec::new();
    collect_relative_path_entries(value, "$", None, &mut entries);
    entries
}

fn collect_relative_path_entries(
    value: &serde_json::Value,
    path: &str,
    active_field: Option<&str>,
    entries: &mut Vec<String>,
) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, child) in map {
                let next_path = format!("{path}.{key}");
                let next_active_field = if is_path_field_key(key) {
                    Some(key.as_str())
                } else {
                    None
                };
                collect_relative_path_entries(child, &next_path, next_active_field, entries);
            }
        }
        serde_json::Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                let next_path = format!("{path}[{index}]");
                collect_relative_path_entries(child, &next_path, active_field, entries);
            }
        }
        serde_json::Value::String(text) => {
            if active_field.is_some() && !looks_cross_platform_absolute(text) {
                entries.push(format!("{path}={text:?}"));
            }
        }
        _ => {}
    }
}

fn is_path_field_key(key: &str) -> bool {
    PATH_FIELD_KEYS.contains(&key)
}

fn looks_cross_platform_absolute(path: &str) -> bool {
    let bytes = path.as_bytes();
    if bytes.starts_with(b"/") || bytes.starts_with(b"\\\\") {
        return true;
    }
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/')
}

fn process_ipc_stream_processor_messages(
    state: &mut IpcStreamProcessorState,
    messages: Vec<IpcStreamProcessorMessage>,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    for message in messages {
        process_ipc_stream_processor_message(
            state,
            message,
            Arc::clone(&session),
            Arc::clone(&app_store),
            server_id,
            recovery_tx,
        );
    }
}

fn process_ipc_stream_processor_message(
    state: &mut IpcStreamProcessorState,
    message: IpcStreamProcessorMessage,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    match message {
        IpcStreamProcessorMessage::StreamEvent(params) => {
            let thread_id = params.conversation_id.clone();

            // If recovering, queue the event
            if state.recovering_threads.contains(&thread_id) {
                state
                    .pending_thread_events
                    .entry(thread_id)
                    .or_default()
                    .push_back(params);
                return;
            }

            let broadcast = TypedBroadcast::ThreadStreamStateChanged(params);
            let output = state.bridge.process_broadcast(&broadcast);

            handle_bridge_output(
                &mut state.bridge,
                &mut state.recovering_threads,
                &mut state.pending_thread_events,
                output,
                &thread_id,
                server_id,
                &app_store,
                &session,
                recovery_tx,
            );
        }
        IpcStreamProcessorMessage::Recovery(recovery) => match recovery {
            PendingIpcStreamRecovery::Recovered {
                thread_id,
                conversation_state,
            } => {
                let queued_events = state
                    .pending_thread_events
                    .get(&thread_id)
                    .map_or(0, VecDeque::len);
                debug!(
                    "IPC: async cache recovery completed server={} thread={} queued_events={}",
                    server_id, thread_id, queued_events
                );
                state.recovering_threads.remove(&thread_id);
                state.bridge.seed_thread(&thread_id, conversation_state);
                // Drain pending events through the bridge
                if let Some(pending) = state.pending_thread_events.remove(&thread_id) {
                    for params in pending {
                        let tid = params.conversation_id.clone();
                        let broadcast = TypedBroadcast::ThreadStreamStateChanged(params);
                        let output = state.bridge.process_broadcast(&broadcast);
                        handle_bridge_output(
                            &mut state.bridge,
                            &mut state.recovering_threads,
                            &mut state.pending_thread_events,
                            output,
                            &tid,
                            server_id,
                            &app_store,
                            &session,
                            recovery_tx,
                        );
                        // If recovery was triggered again, stop draining
                        if state.recovering_threads.contains(&tid) {
                            break;
                        }
                    }
                }
            }
            PendingIpcStreamRecovery::Failed { thread_id, error } => {
                state.recovering_threads.remove(&thread_id);
                state.pending_thread_events.remove(&thread_id);
                warn!(
                    "IPC: async cache recovery failed for thread {}: {}",
                    thread_id, error
                );
            }
        },
        IpcStreamProcessorMessage::StaleTurnCheck => {
            let events = state
                .bridge
                .check_stale_turns(Instant::now(), IPC_STALE_TURN_QUIET_THRESHOLD);
            for event in events {
                apply_bridge_event(&app_store, server_id, event);
            }
        }
    }
}

fn handle_bridge_output(
    bridge: &mut IpcBridge,
    recovering_threads: &mut HashSet<String>,
    pending_thread_events: &mut HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    output: BridgeOutput,
    thread_id: &str,
    server_id: &str,
    app_store: &Arc<AppStoreReducer>,
    session: &Arc<ServerSession>,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    match output {
        BridgeOutput::Events(events) => {
            for event in events {
                apply_bridge_event(app_store, server_id, event);
            }
            // Sync pending approvals/user inputs from bridge projection
            if let Some(proj) = bridge.projected_state(thread_id) {
                sync_ipc_thread_requests_from_projection(app_store, server_id, thread_id, proj);
            }
        }
        BridgeOutput::FullReplace {
            thread_id: replace_thread_id,
        } => {
            // Bridge has authoritative state but can't diff granularly
            // (e.g., synthesized turn IDs resolved to real server IDs).
            // Build a full thread snapshot from the bridge's cached raw state
            // and upsert it directly — no network call needed.
            if let Some(proj) = bridge.projected_state(&replace_thread_id) {
                let key = ThreadKey {
                    server_id: server_id.to_string(),
                    thread_id: replace_thread_id.clone(),
                };
                let projection_result = thread_projection_from_conversation_json(
                    server_id,
                    &replace_thread_id,
                    &bridge.raw_state(&replace_thread_id).unwrap_or_default(),
                );
                match projection_result {
                    Ok(projection) => {
                        let mut snapshot = projection.snapshot;
                        if let Some(existing) = app_store.snapshot().threads.get(&key) {
                            copy_thread_runtime_fields(existing, &mut snapshot);
                            reconcile_active_turn(
                                Some(existing),
                                &mut snapshot,
                                &proj.thread.turns,
                            );
                        }
                        app_store.upsert_thread_snapshot(snapshot);
                        sync_ipc_thread_requests_from_projection(
                            app_store,
                            server_id,
                            &replace_thread_id,
                            proj,
                        );
                    }
                    Err(e) => {
                        warn!(
                            "IPC: FullReplace projection failed for thread={}: {}, falling back to recovery",
                            replace_thread_id, e
                        );
                        // Fall through to recovery
                        queue_ipc_thread_stream_recovery(
                            pending_thread_events,
                            recovering_threads,
                            Arc::clone(session),
                            Arc::clone(app_store),
                            server_id,
                            ThreadStreamStateChangedParams {
                                conversation_id: replace_thread_id.clone(),
                                version: 0,
                                change: StreamChange::Patches { patches: vec![] },
                            },
                            "bridge_full_replace_fallback",
                            recovery_tx,
                        );
                    }
                }
            }
        }
        BridgeOutput::NeedsRefresh {
            thread_id: refresh_thread_id,
        } => {
            queue_ipc_thread_stream_recovery(
                pending_thread_events,
                recovering_threads,
                Arc::clone(session),
                Arc::clone(app_store),
                server_id,
                // Create a dummy params for queuing — the recovery will do a full thread/read
                ThreadStreamStateChangedParams {
                    conversation_id: refresh_thread_id.clone(),
                    version: 0,
                    change: StreamChange::Patches { patches: vec![] },
                },
                "bridge_needs_refresh",
                recovery_tx,
            );
        }
        BridgeOutput::ThreadArchived { thread_id } => {
            bridge.remove_thread(&thread_id);
        }
        BridgeOutput::ThreadUnarchived { .. } => {
            // Thread list refresh is handled by the outer broadcast loop
        }
        BridgeOutput::None => {}
    }
}

fn apply_bridge_event(app_store: &AppStoreReducer, server_id: &str, event: BridgeEvent) {
    use codex_app_server_protocol::ServerNotification;
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: event.thread_id.clone(),
    };
    let ui_event = match event.notification {
        ServerNotification::TurnStarted(n) => UiEvent::TurnStarted {
            key,
            turn_id: n.turn.id,
        },
        ServerNotification::TurnCompleted(n) => UiEvent::TurnCompleted {
            key,
            turn_id: n.turn.id,
            error: n.turn.error.map(|e| e.message),
        },
        ServerNotification::ItemStarted(n) => UiEvent::ItemStarted {
            key,
            notification: n,
        },
        ServerNotification::ItemCompleted(n) => UiEvent::ItemCompleted {
            key,
            notification: n,
        },
        ServerNotification::AgentMessageDelta(n) => UiEvent::MessageDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::ReasoningTextDelta(n) => UiEvent::ReasoningDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::ReasoningSummaryTextDelta(n) => UiEvent::ReasoningDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::PlanDelta(n) => UiEvent::PlanDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::CommandExecutionOutputDelta(n) => UiEvent::CommandOutputDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::DynamicToolCallArgumentsDelta(n) => {
            UiEvent::DynamicToolCallArgumentsDelta {
                key,
                item_id: n.item_id,
                call_id: n.call_id,
                delta: n.delta,
            }
        }
        ServerNotification::ThreadStatusChanged(_) => {
            // Thread status is handled by TurnStarted/TurnCompleted
            return;
        }
        ServerNotification::ServerRequestResolved(_) => {
            // Handled via sync_ipc_thread_requests_from_projection
            return;
        }
        _ => return,
    };
    app_store.apply_ui_event(&ui_event);
}

fn note_notification_runtime(
    app_store: &AppStoreReducer,
    server_id: &str,
    runtime_kind: AgentRuntimeKind,
    notification: &upstream::ServerNotification,
) {
    let Some(thread_id) = notification_thread_id(notification) else {
        return;
    };
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id,
    };
    app_store.set_thread_agent_runtime(&key, runtime_kind);
}

fn notification_thread_id(notification: &upstream::ServerNotification) -> Option<String> {
    let value = serde_json::to_value(notification).ok()?;
    find_thread_id_value(&value)
}

fn find_thread_id_value(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            for key in ["threadId", "thread_id"] {
                if let Some(raw) = map.get(key).and_then(serde_json::Value::as_str)
                    && !raw.trim().is_empty()
                {
                    return Some(raw.to_string());
                }
            }
            if let Some(thread) = map.get("thread")
                && let Some(id) = thread.get("id").and_then(serde_json::Value::as_str)
                && !id.trim().is_empty()
            {
                return Some(id.to_string());
            }
            map.values().find_map(find_thread_id_value)
        }
        serde_json::Value::Array(values) => values.iter().find_map(find_thread_id_value),
        _ => None,
    }
}

fn sync_ipc_thread_requests_from_projection(
    app_store: &AppStoreReducer,
    server_id: &str,
    thread_id: &str,
    projection: &codex_ipc::conversation_state::ProjectedConversationState,
) {
    let pending_approvals: Vec<PendingApprovalWithSeed> = projection
        .pending_approvals
        .iter()
        .map(|approval| pending_approval_from_ipc_projection(server_id, approval.clone()))
        .collect();
    let pending_user_inputs: Vec<PendingUserInputRequest> = projection
        .pending_user_inputs
        .iter()
        .map(|request| pending_user_input_from_ipc_projection(server_id, request.clone()))
        .collect();
    sync_ipc_thread_requests(
        app_store,
        server_id,
        thread_id,
        pending_approvals,
        pending_user_inputs,
    );
}

fn client_request_wire_method(request: &upstream::ClientRequest) -> &'static str {
    match request {
        upstream::ClientRequest::GetAccount { .. } => "account/read",
        upstream::ClientRequest::GetAccountRateLimits { .. } => "account/rateLimits/read",
        upstream::ClientRequest::ModelList { .. } => "model/list",
        upstream::ClientRequest::LoginAccount { .. } => "account/login/start",
        upstream::ClientRequest::CancelLoginAccount { .. } => "account/login/cancel",
        upstream::ClientRequest::LogoutAccount { .. } => "account/logout",
        upstream::ClientRequest::ThreadList { .. } => "thread/list",
        upstream::ClientRequest::ThreadStart { .. } => "thread/start",
        upstream::ClientRequest::ThreadRead { .. } => "thread/read",
        upstream::ClientRequest::ThreadResume { .. } => "thread/resume",
        upstream::ClientRequest::ThreadFork { .. } => "thread/fork",
        upstream::ClientRequest::ThreadRollback { .. } => "thread/rollback",
        upstream::ClientRequest::ThreadTurnsList { .. } => "thread/turns/list",
        upstream::ClientRequest::TurnStart { .. } => "turn/start",
        upstream::ClientRequest::TurnSteer { .. } => "turn/steer",
        upstream::ClientRequest::CollaborationModeList { .. } => "collaboration_mode/list",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_protocol::{
        CommandAction, CommandExecutionSource, CommandExecutionStatus, ThreadItem,
    };
    use serde::Deserialize;
    use serde::de::Error as _;
    use serde_json::json;

    #[test]
    fn suspicious_relative_path_entries_reports_relative_values_in_known_path_fields() {
        let payload = json!({
            "cwd": "/private/var/mobile/home/codex",
            "instructionSources": [
                "AGENTS.md",
                "/private/var/mobile/home/codex/AGENTS.md"
            ],
            "sandbox": {
                "type": "workspaceWrite",
                "writableRoots": ["relative-root", "/private/var/mobile/home/codex"]
            },
            "thread": {
                "cwd": "/private/var/mobile/home/codex",
                "path": "threads/thread-123.json"
            }
        });

        let entries = suspicious_relative_path_entries(&payload);

        assert_eq!(
            entries,
            vec![
                "$.instructionSources[0]=\"AGENTS.md\"",
                "$.sandbox.writableRoots[0]=\"relative-root\"",
                "$.thread.path=\"threads/thread-123.json\"",
            ]
        );
    }

    #[test]
    fn format_typed_rpc_deserialization_error_appends_relative_path_diagnostics() {
        let payload = json!({
            "instructionSources": ["AGENTS.md"]
        });
        let synthetic = serde_json::Error::custom(
            "AbsolutePathBuf deserialized without a base path at line 1 column 2",
        );
        let message = format_typed_rpc_deserialization_error("thread/start", &synthetic, &payload);

        assert!(
            message.contains("$.instructionSources[0]=\"AGENTS.md\""),
            "{message}"
        );
        assert!(message.contains("[method=thread/start]"), "{message}");
    }

    #[derive(Debug, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct InstructionSourcesEnvelope {
        cwd: AbsolutePathBuf,
        instruction_sources: Vec<AbsolutePathBuf>,
    }

    #[test]
    fn deserialize_typed_response_resolves_instruction_sources_against_response_cwd() {
        let payload = json!({
            "cwd": "/private/var/mobile/home/codex",
            "instructionSources": ["AGENTS.md"]
        });

        let parsed: InstructionSourcesEnvelope =
            deserialize_typed_response(&payload).expect("payload should deserialize");

        assert_eq!(
            parsed.cwd.as_path(),
            Path::new("/private/var/mobile/home/codex")
        );
        assert_eq!(
            parsed.instruction_sources[0].as_path(),
            Path::new("/private/var/mobile/home/codex/AGENTS.md")
        );
    }

    #[test]
    fn deserialize_typed_response_accepts_empty_thread_list_cwd() {
        let payload = json!({
            "data": [{
                "id": "thread-1",
                "preview": "hello",
                "ephemeral": false,
                "modelProvider": "anthropic",
                "createdAt": 1_777_345_792,
                "updatedAt": 1_777_345_792,
                "status": { "type": "notLoaded" },
                "path": "/Users/sigkitten/.claude/projects/-tmp/thread-1.jsonl",
                "cwd": "",
                "cliVersion": "alleycat-claude-bridge/0.1.0",
                "source": "appServer",
                "turns": []
            }],
            "nextCursor": null,
            "backwardsCursor": null
        });

        let parsed: upstream::ThreadListResponse =
            deserialize_typed_response(&payload).expect("thread/list should deserialize");

        assert_eq!(parsed.data[0].cwd.as_path(), Path::new("/"));
    }

    #[test]
    fn deserialize_typed_response_accepts_default_service_tier_alias() {
        let payload = json!({
            "model": "",
            "modelProvider": "anthropic",
            "serviceTier": "default",
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "sandbox": { "type": "workspaceWrite" },
            "permissionProfile": { "type": "disabled" },
            "cwd": "/tmp",
            "instructionSources": [],
            "reasoningEffort": "high",
            "thread": {
                "id": "thread-1",
                "preview": "hello",
                "ephemeral": false,
                "modelProvider": "anthropic",
                "createdAt": 1,
                "updatedAt": 2,
                "status": { "type": "notLoaded" },
                "path": "/tmp/thread.jsonl",
                "cwd": "/tmp",
                "cliVersion": "alleycat-claude-bridge/0.1.0",
                "source": "appServer",
                "agentNickname": null,
                "agentRole": null,
                "gitInfo": null,
                "name": null,
                "turns": []
            }
        });

        let parsed: upstream::ThreadResumeResponse =
            deserialize_typed_response(&payload).expect("thread/resume should deserialize");

        assert_eq!(parsed.service_tier, None);
    }

    #[test]
    fn deserialize_typed_response_accepts_claude_dynamic_tool_text_alias() {
        let payload = json!({
            "data": [{
                "id": "turn-1",
                "items": [
                    {
                        "id": "user-1",
                        "type": "userMessage",
                        "content": [{
                            "type": "text",
                            "text": "hello",
                            "textElements": []
                        }]
                    },
                    {
                        "id": "tool-1",
                        "type": "dynamicToolCall",
                        "namespace": "claude",
                        "tool": "Read",
                        "arguments": {},
                        "status": "completed",
                        "contentItems": [{
                            "type": "text",
                            "text": "tool output"
                        }, {
                            "type": "text",
                            "file": {
                                "content": "file output",
                                "filePath": "/tmp/file.txt"
                            }
                        }, {
                            "text": "untagged output"
                        }, {
                            "task": {
                                "id": "1",
                                "subject": "structured output"
                            }
                        }],
                        "success": true,
                        "durationMs": 1
                    }
                ],
                "status": "completed",
                "error": null,
                "startedAt": null,
                "completedAt": 1,
                "durationMs": 1
            }],
            "nextCursor": null,
            "backwardsCursor": null
        });

        let parsed: upstream::ThreadTurnsListResponse =
            deserialize_typed_response(&payload).expect("thread turns should deserialize");

        let upstream::ThreadItem::UserMessage { content, .. } = &parsed.data[0].items[0] else {
            panic!("expected user message");
        };
        assert!(matches!(
            &content[0],
            upstream::UserInput::Text { text, .. } if text == "hello"
        ));

        let upstream::ThreadItem::DynamicToolCall { content_items, .. } = &parsed.data[0].items[1]
        else {
            panic!("expected dynamic tool call");
        };
        let content_items = content_items.as_ref().expect("content items");
        assert!(matches!(
            &content_items[0],
            codex_app_server_protocol::DynamicToolCallOutputContentItem::InputText { text }
                if text == "tool output"
        ));
        assert!(matches!(
            &content_items[1],
            codex_app_server_protocol::DynamicToolCallOutputContentItem::InputText { text }
                if text == "file output"
        ));
        assert!(matches!(
            &content_items[2],
            codex_app_server_protocol::DynamicToolCallOutputContentItem::InputText { text }
                if text == "untagged output"
        ));
        assert!(matches!(
            &content_items[3],
            codex_app_server_protocol::DynamicToolCallOutputContentItem::InputText { text }
                if text.contains("structured output")
        ));
    }

    #[test]
    fn deserialize_typed_response_accepts_compact_bridge_command_actions() {
        let payload = json!({
            "data": [{
                "id": "turn-1",
                "items": [{
                    "id": "tool-1",
                    "type": "commandExecution",
                    "command": "read .pi-tool-demo.txt",
                    "cwd": "/tmp/project",
                    "processId": null,
                    "source": "agent",
                    "status": "completed",
                    "commandActions": [{
                        "type": "read",
                        "path": ".pi-tool-demo.txt"
                    }, {
                        "type": "list_files",
                        "path": "src"
                    }],
                    "aggregatedOutput": "demo line\n",
                    "exitCode": null,
                    "durationMs": null
                }],
                "status": "completed",
                "error": null,
                "startedAt": null,
                "completedAt": 1,
                "durationMs": 1
            }],
            "nextCursor": null,
            "backwardsCursor": null
        });

        let parsed: upstream::ThreadTurnsListResponse =
            deserialize_typed_response(&payload).expect("thread turns should deserialize");
        let upstream::ThreadItem::CommandExecution {
            command_actions, ..
        } = &parsed.data[0].items[0]
        else {
            panic!("expected command execution");
        };

        assert!(matches!(
            &command_actions[0],
            upstream::CommandAction::Read {
                command,
                name,
                path
            } if command == "read .pi-tool-demo.txt"
                && name == ".pi-tool-demo.txt"
                && path.as_path() == Path::new("/tmp/project/.pi-tool-demo.txt")
        ));
        assert!(matches!(
            &command_actions[1],
            upstream::CommandAction::ListFiles { command, path }
                if command == "read .pi-tool-demo.txt" && path.as_deref() == Some("src")
        ));
    }

    #[test]
    fn deserialize_typed_response_resolves_read_action_paths_against_command_cwd() {
        let command_item = ThreadItem::CommandExecution {
            id: "cmd-1".into(),
            command: "cat crates/krusty-cli/src/main.rs".into(),
            cwd: AbsolutePathBuf::from_absolute_path("/repo").expect("absolute cwd"),
            process_id: None,
            source: CommandExecutionSource::Agent,
            status: CommandExecutionStatus::Completed,
            command_actions: vec![CommandAction::Read {
                command: "cat crates/krusty-cli/src/main.rs".into(),
                name: "main.rs".into(),
                path: AbsolutePathBuf::from_absolute_path("/repo/crates/krusty-cli/src/main.rs")
                    .expect("absolute read path"),
            }],
            aggregated_output: None,
            exit_code: Some(0),
            duration_ms: Some(1),
        };
        let mut payload = serde_json::to_value(command_item).expect("serialize command item");
        payload["commandActions"][0]["path"] = json!("crates/krusty-cli/src/main.rs");

        let parsed: ThreadItem =
            deserialize_typed_response(&payload).expect("payload should deserialize");
        let ThreadItem::CommandExecution {
            cwd,
            command_actions,
            ..
        } = parsed
        else {
            panic!("expected command execution item");
        };
        let CommandAction::Read { path, .. } = &command_actions[0] else {
            panic!("expected read command action");
        };

        assert_eq!(cwd.as_path(), Path::new("/repo"));
        assert_eq!(
            path.as_path(),
            Path::new("/repo/crates/krusty-cli/src/main.rs")
        );
    }

    /// A v0.125+ server already emits the tagged-enum shape. Normalization
    /// should be a no-op and the legacy flag must stay false.
    #[test]
    fn permission_profile_v125_tagged_shape_is_no_op() {
        let mut payload = json!({
            "permissionProfile": {
                "type": "managed",
                "network": { "enabled": true },
                "fileSystem": { "type": "restricted", "entries": [] }
            }
        });
        let legacy = normalize_legacy_permission_profile_fields(&mut payload);
        assert!(!legacy);
        assert_eq!(
            payload["permissionProfile"]["type"].as_str(),
            Some("managed")
        );
        assert_eq!(
            payload["permissionProfile"]["fileSystem"]["type"].as_str(),
            Some("restricted")
        );
    }

    /// Exact legacy shape from the v0.124 device-console log — no `type`
    /// discriminator on `permissionProfile` or its inner `fileSystem`.
    /// Normalization should upgrade both to the new tagged shapes and the
    /// legacy flag must be true so the caller can flip
    /// `supports_turn_pagination = false`.
    #[test]
    fn permission_profile_v124_legacy_shape_is_upgraded() {
        let mut payload = json!({
            "permissionProfile": {
                "fileSystem": {
                    "entries": [
                        { "access": "write", "path": { "type": "special", "value": { "kind": "root" } } }
                    ]
                },
                "network": { "enabled": true }
            }
        });
        let legacy = normalize_legacy_permission_profile_fields(&mut payload);
        assert!(legacy);
        assert_eq!(
            payload["permissionProfile"]["type"].as_str(),
            Some("managed")
        );
        assert_eq!(
            payload["permissionProfile"]["fileSystem"]["type"].as_str(),
            Some("restricted")
        );
        // Entries array preserved unchanged.
        assert_eq!(
            payload["permissionProfile"]["fileSystem"]["entries"]
                .as_array()
                .map(Vec::len),
            Some(1)
        );
    }

    /// A legacy-shape `permissionProfile` nested under a response object
    /// (e.g. inside the top level of ThreadResumeResponse) still gets
    /// upgraded — the walker recurses through all nested objects.
    #[test]
    fn permission_profile_legacy_shape_upgraded_in_nested_response() {
        let mut payload = json!({
            "thread": { "cliVersion": "0.124.0" },
            "permissionProfile": {
                "fileSystem": { "entries": [] },
                "network": { "enabled": false }
            }
        });
        assert!(normalize_legacy_permission_profile_fields(&mut payload));
        assert_eq!(
            payload["permissionProfile"]["type"].as_str(),
            Some("managed")
        );
    }

    /// A legacy network.enabled=null must coerce to false so deserialization
    /// into the v0.125 `PermissionProfileNetworkPermissions.enabled: bool`
    /// succeeds.
    #[test]
    fn permission_profile_network_enabled_null_coerces_to_false() {
        let mut payload = json!({
            "permissionProfile": {
                "fileSystem": { "entries": [] },
                "network": { "enabled": null }
            }
        });
        assert!(normalize_legacy_permission_profile_fields(&mut payload));
        assert_eq!(
            payload["permissionProfile"]["network"]["enabled"],
            json!(false)
        );
    }

    /// Payloads without any `permissionProfile` (e.g. thread/list) must
    /// pass through unchanged, legacy flag false.
    #[test]
    fn payload_without_permission_profile_is_untouched() {
        let mut payload = json!({ "data": [{"id": "t1"}], "nextCursor": null });
        let legacy = normalize_legacy_permission_profile_fields(&mut payload);
        assert!(!legacy);
        assert_eq!(payload["data"][0]["id"].as_str(), Some("t1"));
    }

    /// Full end-to-end: a legacy ThreadResumeResponse payload (minimal
    /// fields) deserializes successfully into `upstream::ThreadResumeResponse`
    /// via `deserialize_typed_response_with_legacy_flag`.
    #[test]
    fn legacy_thread_resume_response_deserializes_with_flag() {
        let payload = json!({
            "model": "gpt-5",
            "modelProvider": "openai",
            "serviceTier": "fast",
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandbox": { "type": "dangerFullAccess" },
            "cwd": "/tmp",
            "instructionSources": [],
            "reasoningEffort": "medium",
            "permissionProfile": {
                "fileSystem": { "entries": [] },
                "network": { "enabled": true }
            },
            "thread": {
                "id": "019da728-02a9-74a1-8dc6-ef71c5c111d8",
                "preview": "hello",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": { "type": "idle" },
                "path": "/tmp/thread.jsonl",
                "cwd": "/tmp",
                "cliVersion": "0.124.0",
                "source": "cli",
                "agentNickname": null,
                "agentRole": null,
                "gitInfo": null,
                "name": "Thread",
                "turns": []
            }
        });
        let (parsed, legacy) =
            deserialize_typed_response_with_legacy_flag::<upstream::ThreadResumeResponse>(&payload);
        assert!(legacy, "legacy flag should fire on v0.124 payload");
        let response = parsed.expect("legacy payload should deserialize");
        assert!(response.permission_profile.is_some());
    }
}
