use super::*;
use super::{WidgetFinalizedPayload, WidgetWaiter};

#[derive(Clone)]
pub(super) struct DynamicToolSessionTarget {
    server_id: String,
    session: Arc<ServerSession>,
    config: ServerConfig,
}

fn local_studio_only_runtime(runtime_kinds: &[AgentRuntimeKind]) -> Option<AgentRuntimeKind> {
    (runtime_kinds == ["local-studio".to_string()]).then(|| "local-studio".to_string())
}

fn reconcile_list_sessions_page(
    app_store: &AppStoreReducer,
    server_id: &str,
    runtime_kinds: &[AgentRuntimeKind],
    threads: &[ThreadInfo],
) {
    if local_studio_only_runtime(runtime_kinds).is_some() {
        // list_sessions is intentionally capped to a single page. Local Studio
        // session inventory is durable and additive here: a partial tool result
        // must neither delete older sessions nor relabel the visible page as
        // Codex. Explicit thread/archive remains the removal signal.
        app_store.upsert_thread_list_page_for_runtime(
            server_id,
            "local-studio".to_string(),
            threads,
        );
    } else {
        app_store.sync_thread_list(server_id, threads);
    }
}

pub(super) async fn handle_dynamic_tool_call_request(
    session: Arc<ServerSession>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    app_store: Arc<AppStoreReducer>,
    widget_waiters: Arc<StdMutex<HashMap<String, WidgetWaiter>>>,
    saved_apps_directory: Arc<StdMutex<Option<String>>>,
    request_id: upstream::RequestId,
    params: upstream::DynamicToolCallParams,
    runtime_kind: AgentRuntimeKind,
) -> Result<(), RpcError> {
    // `show_widget` routing: if a `widget_waiter` is registered for the
    // thread (the Update-overlay path), fulfill it and skip auto-save —
    // the waiter owns this call. Otherwise, run the auto-save upsert so
    // every finalized generative widget persists as a saved app.
    if params.tool.eq_ignore_ascii_case("show_widget") {
        let fulfilled = try_fulfill_widget_waiter(&widget_waiters, &params);
        if !fulfilled {
            auto_upsert_saved_app(&saved_apps_directory, &params);
        }
    }
    let response = match execute_dynamic_tool_call(sessions, Arc::clone(&app_store), &params).await
    {
        Ok(text) => upstream::DynamicToolCallResponse {
            content_items: vec![upstream::DynamicToolCallOutputContentItem::InputText { text }],
            success: true,
        },
        Err(message) => upstream::DynamicToolCallResponse {
            content_items: vec![upstream::DynamicToolCallOutputContentItem::InputText {
                text: message,
            }],
            success: false,
        },
    };

    let request_id = match request_id {
        upstream::RequestId::Integer(value) => serde_json::Value::Number(value.into()),
        upstream::RequestId::String(value) => serde_json::Value::String(value),
    };
    let result = serde_json::to_value(response).map_err(|error| {
        RpcError::Deserialization(format!("serialize dynamic tool response: {error}"))
    })?;
    session
        .respond_for_runtime(runtime_kind, request_id, result)
        .await
}

pub(super) async fn execute_dynamic_tool_call(
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    app_store: Arc<AppStoreReducer>,
    params: &upstream::DynamicToolCallParams,
) -> Result<String, String> {
    let targets = snapshot_dynamic_tool_sessions(&sessions);

    match params.tool.as_str() {
        "list_servers" => Ok(list_servers_tool_output(&targets)),
        "list_sessions" => list_sessions_tool_output(&targets, app_store, &params.arguments).await,
        "visualize_read_me" => {
            crate::widget_guidelines::handle_visualize_read_me(&params.arguments)
        }
        "show_widget" => crate::widget_guidelines::handle_show_widget(&params.arguments),
        tool => Err(format!("Unknown dynamic tool: {tool}")),
    }
}

pub(super) fn snapshot_dynamic_tool_sessions(
    sessions: &Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
) -> Vec<DynamicToolSessionTarget> {
    let guard = match sessions.read() {
        Ok(guard) => guard,
        Err(error) => {
            warn!("MobileClient: recovering poisoned sessions read lock");
            error.into_inner()
        }
    };

    let mut targets = guard
        .iter()
        .map(|(server_id, session)| DynamicToolSessionTarget {
            server_id: server_id.clone(),
            session: Arc::clone(session),
            config: session.config().clone(),
        })
        .collect::<Vec<_>>();
    targets.sort_by_key(dynamic_tool_server_name);
    targets
}

pub(super) fn dynamic_tool_server_name(target: &DynamicToolSessionTarget) -> String {
    if target.config.is_local {
        "local".to_string()
    } else {
        target.config.display_name.clone()
    }
}

pub(super) fn dynamic_tool_matches_server(
    target: &DynamicToolSessionTarget,
    requested_server: &str,
) -> bool {
    let requested = requested_server.trim();
    if requested.is_empty() {
        return false;
    }
    target.server_id.eq_ignore_ascii_case(requested)
        || target.config.display_name.eq_ignore_ascii_case(requested)
        || target.config.host.eq_ignore_ascii_case(requested)
        || (target.config.is_local && requested.eq_ignore_ascii_case("local"))
}

pub(super) fn dynamic_tool_sessions_for_request(
    targets: &[DynamicToolSessionTarget],
    requested_server: Option<&str>,
    allow_all_if_missing: bool,
) -> Result<Vec<DynamicToolSessionTarget>, String> {
    match requested_server
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(requested_server) => {
            let matches = targets
                .iter()
                .filter(|target| dynamic_tool_matches_server(target, requested_server))
                .cloned()
                .collect::<Vec<_>>();
            if matches.is_empty() {
                Err(format!("Server '{requested_server}' is not connected."))
            } else {
                Ok(matches)
            }
        }
        None if allow_all_if_missing => Ok(targets.to_vec()),
        None => Err("A server name or ID is required.".to_string()),
    }
}

pub(super) fn dynamic_tool_string(arguments: &serde_json::Value, keys: &[&str]) -> Option<String> {
    let object = arguments.as_object()?;
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    })
}

pub(super) fn dynamic_tool_u32(arguments: &serde_json::Value, keys: &[&str]) -> Option<u32> {
    let object = arguments.as_object()?;
    keys.iter().find_map(|key| match object.get(*key) {
        Some(serde_json::Value::Number(value)) => {
            value.as_u64().and_then(|n| u32::try_from(n).ok())
        }
        Some(serde_json::Value::String(value)) => value.trim().parse::<u32>().ok(),
        _ => None,
    })
}

pub(super) fn truncate_dynamic_tool_text(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    let mut truncated = text[..end].trim_end().to_string();
    truncated.push_str("...");
    truncated
}

pub(super) fn serialize_dynamic_tool_payload(
    payload: serde_json::Value,
    max_bytes: usize,
) -> String {
    let text = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
    truncate_dynamic_tool_text(&text, max_bytes)
}

pub(super) fn list_servers_tool_output(targets: &[DynamicToolSessionTarget]) -> String {
    let items = targets
        .iter()
        .map(|target| {
            serde_json::json!({
                "id": target.server_id,
                "name": dynamic_tool_server_name(target),
                "hostname": truncate_dynamic_tool_text(&target.config.host, 200),
                "isConnected": true,
                "isLocal": target.config.is_local,
            })
        })
        .collect::<Vec<_>>();

    let summary = match items.len() {
        0 => "No connected servers found.".to_string(),
        1 => {
            let name = items[0]
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("the server");
            format!("Found 1 connected server: {name}.")
        }
        count => {
            let names = items
                .iter()
                .take(3)
                .filter_map(|item| item.get("name").and_then(serde_json::Value::as_str))
                .collect::<Vec<_>>();
            let listed = names.join(", ");
            let extra = count.saturating_sub(names.len());
            if extra > 0 {
                format!("Found {count} connected servers: {listed}, and {extra} more.")
            } else {
                format!("Found {count} connected servers: {listed}.")
            }
        }
    };

    serialize_dynamic_tool_payload(
        serde_json::json!({
            "type": "servers",
            "summary": summary,
            "items": items,
        }),
        24_000,
    )
}

pub(super) async fn list_sessions_tool_output(
    targets: &[DynamicToolSessionTarget],
    app_store: Arc<AppStoreReducer>,
    arguments: &serde_json::Value,
) -> Result<String, String> {
    let limit = dynamic_tool_u32(arguments, &["limit"])
        .unwrap_or(20)
        .clamp(1, 40);
    let requested_server = dynamic_tool_string(arguments, &["server_id", "server"]);
    let targets = dynamic_tool_sessions_for_request(targets, requested_server.as_deref(), true)?;

    let mut items = Vec::new();
    let mut errors = Vec::new();

    for target in targets {
        let runtime_kinds = target.session.runtime_kinds();
        let response = dynamic_tool_request_typed::<upstream::ThreadListResponse, _>(
            &target.session,
            local_studio_only_runtime(&runtime_kinds),
            "thread/list",
            &upstream::ThreadListParams {
                cursor: None,
                limit: Some(limit),
                sort_key: None,
                sort_direction: None,
                model_providers: None,
                source_kinds: None,
                archived: None,
                cwd: None,
                search_term: None,
                use_state_db_only: false,
            },
        )
        .await;

        match response {
            Ok(response) => {
                let threads = response
                    .data
                    .into_iter()
                    .filter_map(thread_info_from_upstream_thread)
                    .collect::<Vec<_>>();
                reconcile_list_sessions_page(
                    app_store.as_ref(),
                    &target.server_id,
                    &runtime_kinds,
                    &threads,
                );
                items.extend(threads.into_iter().map(|thread| {
                    serde_json::json!({
                        "id": thread.id,
                        "preview": thread.preview.map(|value| truncate_dynamic_tool_text(&value, 280)),
                        "modelProvider": thread.model_provider,
                        "updatedAt": thread.updated_at,
                        "cwd": thread.cwd.map(|value| truncate_dynamic_tool_text(&value, 240)),
                        "serverId": target.server_id,
                        "serverName": truncate_dynamic_tool_text(&dynamic_tool_server_name(&target), 160),
                    })
                }));
            }
            Err(error) => {
                errors.push(serde_json::json!({
                    "serverId": target.server_id,
                    "serverName": truncate_dynamic_tool_text(&dynamic_tool_server_name(&target), 160),
                    "message": truncate_dynamic_tool_text(&error, 240),
                }));
            }
        }
    }

    items.sort_by(|lhs, rhs| {
        let lhs_updated = lhs
            .get("updatedAt")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or_default();
        let rhs_updated = rhs
            .get("updatedAt")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or_default();
        rhs_updated.cmp(&lhs_updated)
    });
    if items.len() > limit as usize {
        items.truncate(limit as usize);
    }

    let summary = if items.is_empty() {
        if errors.is_empty() {
            "No sessions found.".to_string()
        } else {
            format!(
                "No sessions found. {} server lookup{} failed.",
                errors.len(),
                if errors.len() == 1 { "" } else { "s" }
            )
        }
    } else {
        let server_count = items
            .iter()
            .filter_map(|item| item.get("serverId").and_then(serde_json::Value::as_str))
            .collect::<std::collections::HashSet<_>>()
            .len();
        let preview = items[0]
            .get("preview")
            .and_then(serde_json::Value::as_str)
            .map(|value| truncate_dynamic_tool_text(value, 80))
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "an untitled session".to_string());
        let server_name = items[0]
            .get("serverName")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown server");
        let mut summary = format!(
            "Found {} session{} across {} server{}. The most recent is {} on {}.",
            items.len(),
            if items.len() == 1 { "" } else { "s" },
            server_count,
            if server_count == 1 { "" } else { "s" },
            preview,
            server_name,
        );
        if !errors.is_empty() {
            summary.push_str(" Some servers could not be queried.");
        }
        summary
    };

    let mut payload = serde_json::json!({
        "type": "sessions",
        "summary": summary,
        "items": items,
    });
    if let serde_json::Value::Object(object) = &mut payload
        && !errors.is_empty()
    {
        object.insert("errors".to_string(), serde_json::Value::Array(errors));
    }
    Ok(serialize_dynamic_tool_payload(payload, 64_000))
}

pub(super) async fn dynamic_tool_request_typed<R, P>(
    session: &Arc<ServerSession>,
    runtime_kind: Option<AgentRuntimeKind>,
    method: &str,
    params: &P,
) -> Result<R, String>
where
    R: serde::de::DeserializeOwned,
    P: serde::Serialize,
{
    let params_json = serde_json::to_value(params)
        .map_err(|error| format!("serialize {method} params: {error}"))?;
    let response = if let Some(runtime_kind) = runtime_kind {
        session
            .request_for_runtime(runtime_kind, method, params_json)
            .await
    } else {
        session.request(method, params_json).await
    }
    .map_err(|error| format!("{method} request failed: {error}"))?;
    serde_json::from_value(response)
        .map_err(|error| format!("deserialize {method} response: {error}"))
}

#[cfg(test)]
mod local_studio_tests {
    use super::*;
    use crate::store::snapshot::ThreadSnapshot;
    use crate::types::ThreadSummaryStatus;

    fn thread(id: &str) -> ThreadInfo {
        ThreadInfo {
            id: id.to_string(),
            title: None,
            status: ThreadSummaryStatus::Idle,
            preview: None,
            cwd: None,
            path: None,
            model: None,
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

    #[test]
    fn local_studio_tool_page_is_additive_and_keeps_runtime_identity() {
        let store = AppStoreReducer::new();
        let mut older = ThreadSnapshot::from_info("local-studio-server", thread("older"));
        older.agent_runtime_kind = "local-studio".to_string();
        store.upsert_thread_snapshot(older);

        reconcile_list_sessions_page(
            &store,
            "local-studio-server",
            &["local-studio".to_string()],
            &[thread("newer")],
        );

        let snapshot = store.snapshot();
        assert_eq!(snapshot.threads.len(), 2);
        assert!(snapshot.threads.values().all(|thread| {
            thread.key.server_id != "local-studio-server"
                || thread.agent_runtime_kind == "local-studio"
        }));
    }

    #[test]
    fn non_local_studio_tool_page_keeps_existing_reconcile_behavior() {
        let store = AppStoreReducer::new();
        store.upsert_thread_snapshot(ThreadSnapshot::from_info("server", thread("older")));

        reconcile_list_sessions_page(&store, "server", &["codex".to_string()], &[thread("newer")]);

        let snapshot = store.snapshot();
        assert_eq!(snapshot.threads.len(), 1);
        assert!(snapshot.threads.keys().any(|key| key.thread_id == "newer"));
    }
}

/// If a waiter is registered for the thread that emitted this
/// `show_widget` call, extract its HTML/title/dimensions and send them
/// over the oneshot. Used by `AppClient::update_saved_app` to block until
/// the model emits a new widget. Returns `true` when a waiter was
/// actually fulfilled — callers use this to skip the auto-save upsert
/// on the overlay update path.
fn try_fulfill_widget_waiter(
    widget_waiters: &Arc<StdMutex<HashMap<String, WidgetWaiter>>>,
    params: &upstream::DynamicToolCallParams,
) -> bool {
    let thread_id = params.thread_id.clone();
    let arguments = &params.arguments;
    let Some(object) = arguments.as_object() else {
        return false;
    };
    let widget_html = object
        .get("widget_code")
        .or_else(|| object.get("widgetCode"))
        .and_then(|v| v.as_str())
        .map(ToString::to_string);
    let Some(widget_html) = widget_html else {
        return false;
    };
    if widget_html.is_empty() {
        return false;
    }
    let title = object
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("Saved App")
        .to_string();
    let width = object
        .get("width")
        .and_then(|v| v.as_f64())
        .unwrap_or(800.0);
    let height = object
        .get("height")
        .and_then(|v| v.as_f64())
        .unwrap_or(600.0);

    let waiter = {
        let mut guard = widget_waiters
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.remove(&thread_id)
    };
    if let Some(waiter) = waiter {
        let _ = waiter.sender.send(WidgetFinalizedPayload {
            widget_html,
            width,
            height,
            title,
        });
        true
    } else {
        false
    }
}

/// Auto-save path: when a `show_widget` call lands on a thread with no
/// active update-overlay waiter, upsert the app under
/// `(thread_id, app_id)`. Requires the platform to have set the saved
/// apps directory via `AppClient::set_saved_apps_directory`; if unset,
/// this is a no-op (pre-R2 environments, tests).
fn auto_upsert_saved_app(
    saved_apps_directory: &Arc<StdMutex<Option<String>>>,
    params: &upstream::DynamicToolCallParams,
) {
    let directory = {
        let guard = saved_apps_directory
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match guard.clone() {
            Some(d) if !d.is_empty() => d,
            _ => return,
        }
    };
    let Some(object) = params.arguments.as_object() else {
        return;
    };
    // Require a non-empty `app_id` slug. Pre-R2 widgets without a slug
    // won't auto-save — they can still be promoted manually.
    let Some(app_id) = object
        .get("app_id")
        .or_else(|| object.get("appId"))
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return;
    };
    let Some(widget_html) = object
        .get("widget_code")
        .or_else(|| object.get("widgetCode"))
        .and_then(|v| v.as_str())
    else {
        return;
    };
    if widget_html.is_empty() {
        return;
    }
    let title = object
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let width = object
        .get("width")
        .and_then(|v| v.as_f64())
        .unwrap_or(800.0);
    let height = object
        .get("height")
        .and_then(|v| v.as_f64())
        .unwrap_or(600.0);
    // The widget's JS owns `schema_version`; we default to 1 when
    // creating because the `show_widget` tool call doesn't carry it.
    // Subsequent `saveAppState` calls will bump it via the standard
    // persistence path.
    let schema_version: u32 = 1;

    match crate::saved_apps::saved_app_upsert(
        directory,
        params.thread_id.clone(),
        app_id.to_string(),
        title,
        widget_html.to_string(),
        width,
        height,
        schema_version,
    ) {
        Ok(app) => {
            debug!(
                "saved_app auto-upsert ok thread={} slug={} uuid={}",
                params.thread_id, app.app_id, app.id
            );
        }
        Err(error) => {
            warn!(
                "saved_app auto-upsert failed thread={} slug={}: {}",
                params.thread_id, app_id, error
            );
        }
    }
}
