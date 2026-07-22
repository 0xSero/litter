use super::*;

pub fn thread_info_from_upstream_thread(thread: upstream::Thread) -> Option<ThreadInfo> {
    thread_info_from_upstream_thread_list_item(thread, None, None)
}

pub(super) fn thread_info_from_upstream_thread_list_item(
    thread: upstream::Thread,
    model: Option<String>,
    _reasoning_effort: Option<String>,
) -> Option<ThreadInfo> {
    let mut info = ThreadInfo::from(thread);
    info.model = model;
    Some(info)
}

pub fn thread_snapshot_from_upstream_thread_with_overrides(
    server_id: &str,
    thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
    effective_approval_policy: Option<crate::types::AppAskForApproval>,
    effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
) -> Result<ThreadSnapshot, String> {
    Ok(thread_snapshot_from_upstream_thread_state(
        server_id,
        thread,
        model,
        reasoning_effort,
        effective_approval_policy,
        effective_sandbox_policy,
        None,
    ))
}

pub fn copy_thread_runtime_fields(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    target.collaboration_mode = source.collaboration_mode;
    if target.model.is_none() {
        target.model = source.model.clone();
    }
    if target.reasoning_effort.is_none() {
        target.reasoning_effort = source.reasoning_effort.clone();
    }
    if target.queued_follow_ups.is_empty() {
        target.queued_follow_ups = source.queued_follow_ups.clone();
    }
    if target.queued_follow_up_drafts.is_empty() {
        target.queued_follow_up_drafts = source.queued_follow_up_drafts.clone();
    }
    target.context_tokens_used = source.context_tokens_used;
    target.model_context_window = source.model_context_window;
    target.rate_limits = source.rate_limits.clone();
    target.realtime_session_id = source.realtime_session_id.clone();
    if target.goal.is_none() {
        target.goal = source.goal.clone();
    }
    if target.active_plan_progress.is_none() {
        target.active_plan_progress = source.active_plan_progress.clone();
    }
    if target.pending_plan_implementation_turn_id.is_none() {
        target.pending_plan_implementation_turn_id =
            source.pending_plan_implementation_turn_id.clone();
    }
    target.is_resumed = target.is_resumed || source.is_resumed;
}

#[cfg(test)]
pub(super) fn queued_follow_up_preview_from_inputs(
    inputs: &[upstream::UserInput],
    kind: AppQueuedFollowUpKind,
) -> Option<AppQueuedFollowUpPreview> {
    queued_follow_up_draft_from_inputs(inputs, kind).map(|draft| draft.preview)
}

pub(super) fn queued_follow_up_draft_from_inputs(
    inputs: &[upstream::UserInput],
    kind: AppQueuedFollowUpKind,
) -> Option<crate::store::QueuedFollowUpDraft> {
    let text = queued_follow_up_text_from_inputs(inputs)?;

    Some(crate::store::QueuedFollowUpDraft {
        preview: AppQueuedFollowUpPreview {
            id: uuid::Uuid::new_v4().to_string(),
            kind,
            text,
        },
        inputs: inputs.to_vec(),
        source_message_json: queued_follow_up_message_json_from_inputs(inputs),
    })
}

pub(super) fn queued_follow_up_text_from_inputs(inputs: &[upstream::UserInput]) -> Option<String> {
    let mut text_parts: Vec<String> = Vec::new();
    let mut attachment_count = 0usize;

    for input in inputs {
        match input {
            upstream::UserInput::Text { text, .. } => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    text_parts.push(trimmed.to_string());
                }
            }
            upstream::UserInput::Image { .. } | upstream::UserInput::LocalImage { .. } => {
                attachment_count += 1;
            }
            upstream::UserInput::Skill { .. } | upstream::UserInput::Mention { .. } => {}
        }
    }

    if !text_parts.is_empty() {
        Some(text_parts.join("\n"))
    } else {
        attachment_summary(attachment_count)
    }
}

pub(super) fn queued_follow_up_kind_from_json_value(
    value: &serde_json::Value,
) -> Option<AppQueuedFollowUpKind> {
    let object = value.as_object()?;
    let raw_kind = object
        .get("kind")
        .or_else(|| object.get("category"))
        .or_else(|| object.get("queueKind"))
        .or_else(|| object.get("queue_kind"))
        .and_then(serde_json::Value::as_str)?
        .trim()
        .to_ascii_lowercase();

    match raw_kind.as_str() {
        "pending_steer" | "pending-steer" | "pendingsteer" | "steer" => {
            Some(AppQueuedFollowUpKind::PendingSteer)
        }
        "rejected_steer" | "rejected-steer" | "rejectedsteer" | "retrying_steer"
        | "retrying-steer" | "retryingsteer" => Some(AppQueuedFollowUpKind::RetryingSteer),
        "queued" | "queued_follow_up" | "queued-follow-up" | "queuedfollowup" => {
            Some(AppQueuedFollowUpKind::Message)
        }
        _ => None,
    }
}

pub(super) fn queued_follow_up_text_from_json_value(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(text) => {
            let trimmed = text.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        }
        serde_json::Value::Object(object) => {
            if let Some(nested) = object
                .get("userMessage")
                .or_else(|| object.get("user_message"))
            {
                return queued_follow_up_text_from_json_value(nested);
            }

            if let Some(text) = string_field(object, &["text", "message", "summary"]) {
                return Some(text);
            }

            let attachment_count = array_field_len(object, &["localImages", "local_images"])
                + array_field_len(object, &["remoteImageUrls", "remote_image_urls"])
                + array_field_len(object, &["images", "imageUrls", "image_urls"]);

            attachment_summary(attachment_count)
        }
        _ => None,
    }
}

pub(super) fn queued_follow_up_inputs_from_json_value(
    value: &serde_json::Value,
) -> Vec<upstream::UserInput> {
    let Some(object) = value.as_object() else {
        return Vec::new();
    };

    let message = object
        .get("userMessage")
        .or_else(|| object.get("user_message"))
        .and_then(serde_json::Value::as_object)
        .unwrap_or(object);

    let mut inputs = Vec::new();

    let text_elements = message
        .get("textElements")
        .or_else(|| message.get("text_elements"))
        .cloned()
        .and_then(|value| serde_json::from_value::<Vec<upstream::TextElement>>(value).ok())
        .unwrap_or_default();

    if let Some(text) = string_field(message, &["text", "message", "summary"]) {
        inputs.push(upstream::UserInput::Text {
            text,
            text_elements,
        });
    }

    let remote_images = message
        .get("remoteImageUrls")
        .or_else(|| message.get("remote_image_urls"))
        .or_else(|| message.get("images"))
        .or_else(|| message.get("imageUrls"))
        .or_else(|| message.get("image_urls"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .map(|url| upstream::UserInput::Image {
            url: url.to_string(),
            detail: None,
        });
    inputs.extend(remote_images);

    let local_images = message
        .get("localImages")
        .or_else(|| message.get("local_images"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|image| {
            image
                .get("path")
                .and_then(serde_json::Value::as_str)
                .map(std::path::PathBuf::from)
        })
        .map(|path| upstream::UserInput::LocalImage { path, detail: None });
    inputs.extend(local_images);

    let mentions = message
        .get("mentionBindings")
        .or_else(|| message.get("mention_bindings"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|binding| {
            let name = binding
                .get("mention")
                .or_else(|| binding.get("name"))
                .and_then(serde_json::Value::as_str)?;
            let path = binding.get("path").and_then(serde_json::Value::as_str)?;
            Some(upstream::UserInput::Mention {
                name: name.to_string(),
                path: path.to_string(),
            })
        });
    inputs.extend(mentions);

    let skills = message
        .get("skillBindings")
        .or_else(|| message.get("skill_bindings"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|binding| {
            let name = binding
                .get("name")
                .or_else(|| binding.get("skill"))
                .and_then(serde_json::Value::as_str)?;
            let path = binding.get("path").and_then(serde_json::Value::as_str)?;
            Some(upstream::UserInput::Skill {
                name: name.to_string(),
                path: std::path::PathBuf::from(path),
            })
        });
    inputs.extend(skills);

    inputs
}

pub(super) fn queued_follow_up_message_json_from_inputs(
    inputs: &[upstream::UserInput],
) -> Option<serde_json::Value> {
    let mut text = None;
    let mut text_elements = Vec::new();
    let mut remote_image_urls = Vec::new();
    let mut local_images = Vec::new();
    let mut mention_bindings = Vec::new();
    let mut skill_bindings = Vec::new();

    for input in inputs {
        match input {
            upstream::UserInput::Text {
                text: current_text,
                text_elements: current_elements,
            } => {
                let trimmed = current_text.trim();
                if !trimmed.is_empty() {
                    text = Some(trimmed.to_string());
                }
                text_elements = current_elements.clone();
            }
            upstream::UserInput::Image { url, .. } => {
                remote_image_urls.push(url.clone());
            }
            upstream::UserInput::LocalImage { path, .. } => {
                let placeholder = format!("[Image #{}]", local_images.len() + 1);
                local_images.push(serde_json::json!({
                    "placeholder": placeholder,
                    "path": path,
                }));
            }
            upstream::UserInput::Mention { name, path } => {
                mention_bindings.push(serde_json::json!({
                    "mention": name,
                    "path": path,
                }));
            }
            upstream::UserInput::Skill { name, path } => {
                skill_bindings.push(serde_json::json!({
                    "name": name,
                    "path": path,
                }));
            }
        }
    }

    if text.is_none()
        && text_elements.is_empty()
        && remote_image_urls.is_empty()
        && local_images.is_empty()
        && mention_bindings.is_empty()
        && skill_bindings.is_empty()
    {
        return None;
    }

    Some(serde_json::json!({
        "text": text.unwrap_or_default(),
        "textElements": text_elements,
        "remoteImageUrls": remote_image_urls,
        "localImages": local_images,
        "mentionBindings": mention_bindings,
        "skillBindings": skill_bindings,
    }))
}

pub(super) fn string_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter()
        .filter_map(|key| object.get(*key))
        .find_map(|value| match value {
            serde_json::Value::String(text) => {
                let trimmed = text.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_string())
            }
            serde_json::Value::Array(values) => {
                let joined = values
                    .iter()
                    .filter_map(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n");
                (!joined.is_empty()).then_some(joined)
            }
            _ => None,
        })
}

pub(super) fn array_field_len(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> usize {
    keys.iter()
        .filter_map(|key| object.get(*key))
        .find_map(|value| value.as_array().map(Vec::len))
        .unwrap_or(0)
}

pub(super) fn attachment_summary(attachment_count: usize) -> Option<String> {
    match attachment_count {
        0 => None,
        1 => Some("1 image attachment".to_string()),
        count => Some(format!("{count} image attachments")),
    }
}

pub(super) fn stable_follow_up_preview_id(scope: &str, index: usize, text: &str) -> String {
    let mut hasher = DefaultHasher::new();
    scope.hash(&mut hasher);
    index.hash(&mut hasher);
    text.hash(&mut hasher);
    format!("{scope}-{index}-{:016x}", hasher.finish())
}

pub(super) fn remote_oauth_callback_port(auth_url: &str) -> Result<u16, RpcError> {
    let parsed = Url::parse(auth_url).map_err(|error| {
        RpcError::Deserialization(format!("invalid auth URL for remote OAuth: {error}"))
    })?;
    let redirect_uri = parsed
        .query_pairs()
        .find(|(key, _)| key == "redirect_uri")
        .map(|(_, value)| value.into_owned())
        .ok_or_else(|| {
            RpcError::Deserialization("missing redirect_uri in remote OAuth auth URL".to_string())
        })?;
    let redirect = Url::parse(&redirect_uri).map_err(|error| {
        RpcError::Deserialization(format!(
            "invalid redirect_uri in remote OAuth auth URL: {error}"
        ))
    })?;
    let host = redirect.host_str().unwrap_or_default();
    if host != "localhost" && host != "127.0.0.1" {
        return Err(RpcError::Deserialization(format!(
            "unsupported remote OAuth callback host: {host}"
        )));
    }
    redirect.port_or_known_default().ok_or_else(|| {
        RpcError::Deserialization("missing callback port in remote OAuth redirect_uri".to_string())
    })
}

pub(super) fn ensure_thread_is_editable(snapshot: &ThreadSnapshot) -> Result<(), RpcError> {
    if snapshot.items.is_empty() {
        return Err(RpcError::Deserialization(
            "thread has no conversation items".to_string(),
        ));
    }
    Ok(())
}

pub(super) fn rollback_depth_for_turn(
    snapshot: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<u32, RpcError> {
    let user_turn_indices = snapshot
        .items
        .iter()
        .enumerate()
        .filter_map(|(idx, item)| {
            matches!(
                item.content,
                crate::conversation_uniffi::HydratedConversationItemContent::User(_)
            )
            .then_some(idx)
        })
        .collect::<Vec<_>>();
    let item_index = *user_turn_indices.get(selected_turn_index).ok_or_else(|| {
        RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
    })?;
    let turns_after = snapshot.items.len().saturating_sub(item_index + 1);
    u32::try_from(turns_after)
        .map_err(|_| RpcError::Deserialization("rollback depth overflow".to_string()))
}

pub(super) fn user_boundary_text_for_turn(
    snapshot: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<String, RpcError> {
    let item = snapshot
        .items
        .iter()
        .filter(|item| {
            matches!(
                item.content,
                crate::conversation_uniffi::HydratedConversationItemContent::User(_)
            )
        })
        .nth(selected_turn_index)
        .ok_or_else(|| {
            RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
        })?;
    match &item.content {
        crate::conversation_uniffi::HydratedConversationItemContent::User(data) => {
            Ok(data.text.clone())
        }
        _ => Err(RpcError::Deserialization(
            "selected turn has no editable text".to_string(),
        )),
    }
}

pub fn reasoning_effort_string(value: crate::types::ReasoningEffort) -> String {
    match value {
        crate::types::ReasoningEffort::None => "none".to_string(),
        crate::types::ReasoningEffort::Minimal => "minimal".to_string(),
        crate::types::ReasoningEffort::Low => "low".to_string(),
        crate::types::ReasoningEffort::Medium => "medium".to_string(),
        crate::types::ReasoningEffort::High => "high".to_string(),
        crate::types::ReasoningEffort::XHigh => "xhigh".to_string(),
        crate::types::ReasoningEffort::Max => "max".to_string(),
        crate::types::ReasoningEffort::Ultra => "ultra".to_string(),
    }
}

pub fn reasoning_effort_from_string(value: &str) -> Option<crate::types::ReasoningEffort> {
    match value.trim().to_ascii_lowercase().as_str() {
        "none" => Some(crate::types::ReasoningEffort::None),
        "minimal" => Some(crate::types::ReasoningEffort::Minimal),
        "low" => Some(crate::types::ReasoningEffort::Low),
        "medium" => Some(crate::types::ReasoningEffort::Medium),
        "high" => Some(crate::types::ReasoningEffort::High),
        "xhigh" => Some(crate::types::ReasoningEffort::XHigh),
        "max" => Some(crate::types::ReasoningEffort::Max),
        "ultra" => Some(crate::types::ReasoningEffort::Ultra),
        _ => None,
    }
}

pub(super) fn core_reasoning_effort_from_mobile(
    value: crate::types::ReasoningEffort,
) -> codex_protocol::openai_models::ReasoningEffort {
    match value {
        crate::types::ReasoningEffort::None => codex_protocol::openai_models::ReasoningEffort::None,
        crate::types::ReasoningEffort::Minimal => {
            codex_protocol::openai_models::ReasoningEffort::Minimal
        }
        crate::types::ReasoningEffort::Low => codex_protocol::openai_models::ReasoningEffort::Low,
        crate::types::ReasoningEffort::Medium => {
            codex_protocol::openai_models::ReasoningEffort::Medium
        }
        crate::types::ReasoningEffort::High => codex_protocol::openai_models::ReasoningEffort::High,
        crate::types::ReasoningEffort::XHigh => {
            codex_protocol::openai_models::ReasoningEffort::XHigh
        }
        crate::types::ReasoningEffort::Max => codex_protocol::openai_models::ReasoningEffort::Max,
        crate::types::ReasoningEffort::Ultra => codex_protocol::openai_models::ReasoningEffort::Ultra,
    }
}

pub(super) fn collaboration_mode_from_thread(
    thread: &ThreadSnapshot,
    mode: AppModeKind,
    model_override: Option<String>,
    effort_override: Option<codex_protocol::openai_models::ReasoningEffort>,
) -> Option<codex_protocol::config_types::CollaborationMode> {
    let model = model_override
        .or_else(|| thread.model.clone())
        .or_else(|| thread.info.model.clone())?;
    let reasoning_effort = effort_override.or_else(|| {
        thread
            .reasoning_effort
            .as_deref()
            .and_then(reasoning_effort_from_string)
            .map(core_reasoning_effort_from_mobile)
    });
    Some(codex_protocol::config_types::CollaborationMode {
        mode: match mode {
            AppModeKind::Default => codex_protocol::config_types::ModeKind::Default,
            AppModeKind::Plan => codex_protocol::config_types::ModeKind::Plan,
        },
        settings: codex_protocol::config_types::Settings {
            model,
            reasoning_effort,
            developer_instructions: None,
        },
    })
}

pub(super) fn map_rpc_client_error(error: crate::RpcClientError) -> RpcError {
    match error {
        crate::RpcClientError::Rpc(message) | crate::RpcClientError::Serialization(message) => {
            RpcError::Deserialization(message)
        }
    }
}

pub(super) fn map_ssh_transport_error(error: crate::ssh::SshError) -> TransportError {
    TransportError::ConnectionFailed(error.to_string())
}

pub(super) async fn refresh_thread_list_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
) -> Result<(), RpcError> {
    // Multiplexed sessions (Alleycat) carry a separate command channel per
    // agent runtime. `thread/list` is not thread-scoped, so the default
    // dispatcher routes it to Codex only — pi and opencode threads would
    // never appear in the UI. Fan the request out across every runtime the
    // session knows about and merge the pages, so the user sees their pi /
    // opencode threads alongside codex's. `runtime_kinds()` returns
    // `[Codex]` for non-multiplexed sessions, preserving the previous
    // single-runtime behavior.
    let runtime_kinds = session.runtime_kinds();

    let mut incoming_ids = HashSet::new();
    for runtime_kind in runtime_kinds {
        let mut cursor = None;
        loop {
            let response =
                match request_thread_list_page_for_runtime(&session, runtime_kind.clone(), cursor)
                    .await
                {
                    Ok(response) => response,
                    Err(error) => {
                        warn!(
                            "thread/list failed for runtime {:?} on server {}: {}",
                            runtime_kind, server_id, error
                        );
                        break;
                    }
                };
            let page = thread_list_page_to_thread_infos(response.data, &mut incoming_ids);
            app_store.upsert_thread_list_page_for_runtime(server_id, runtime_kind.clone(), &page);

            let Some(next_cursor) = response.next_cursor else {
                break;
            };
            cursor = Some(next_cursor);
        }
    }

    app_store.finalize_thread_list_sync(server_id, &incoming_ids);
    Ok(())
}

pub(super) async fn refresh_account_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
) -> Result<(), RpcError> {
    let response = session
        .request("account/read", serde_json::json!({ "refreshToken": false }))
        .await?;
    if !session_is_current(&sessions, server_id, &session) {
        return Ok(());
    }
    let response =
        serde_json::from_value::<upstream::GetAccountResponse>(response).map_err(|error| {
            RpcError::Deserialization(format!("deserialize account/read response: {error}"))
        })?;
    app_store.update_server_account(
        server_id,
        response.account.map(Into::into),
        response.requires_openai_auth,
    );
    Ok(())
}

async fn request_thread_list_page_for_runtime(
    session: &ServerSession,
    runtime_kind: AgentRuntimeKind,
    cursor: Option<String>,
) -> Result<upstream::ThreadListResponse, RpcError> {
    let params = match cursor {
        Some(cursor) => serde_json::json!({ "cursor": cursor }),
        None => serde_json::json!({}),
    };
    let response = session
        .request_for_runtime(runtime_kind, "thread/list", params)
        .await?;
    let mut response = response;
    normalize_empty_thread_list_cwds(&mut response);
    serde_json::from_value::<upstream::ThreadListResponse>(response)
        .map_err(|error| RpcError::Deserialization(format!("deserialize thread/list: {error}")))
}

fn normalize_empty_thread_list_cwds(value: &mut serde_json::Value) {
    let Some(data) = value
        .get_mut("data")
        .and_then(serde_json::Value::as_array_mut)
    else {
        return;
    };
    for item in data {
        let Some(map) = item.as_object_mut() else {
            continue;
        };
        if let Some(serde_json::Value::String(cwd)) = map.get_mut("cwd")
            && cwd.is_empty()
        {
            *cwd = "/".to_string();
        }
    }
}

fn thread_list_page_to_thread_infos(
    data: Vec<upstream::Thread>,
    incoming_ids: &mut HashSet<String>,
) -> Vec<ThreadInfo> {
    let mut threads = Vec::new();
    for thread in data {
        let Some(info) = thread_info_from_upstream_thread(thread) else {
            continue;
        };
        incoming_ids.insert(info.id.clone());
        threads.push(info);
    }
    threads
}

pub(super) fn session_is_current(
    sessions: &Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
    session: &Arc<ServerSession>,
) -> bool {
    match sessions.read() {
        Ok(guard) => guard
            .get(server_id)
            .map(|current| Arc::ptr_eq(current, session))
            .unwrap_or(false),
        Err(error) => error
            .into_inner()
            .get(server_id)
            .map(|current| Arc::ptr_eq(current, session))
            .unwrap_or(false),
    }
}

pub(super) async fn read_thread_response_from_app_server(
    session: Arc<ServerSession>,
    thread_id: &str,
    include_turns: bool,
) -> Result<upstream::ThreadReadResponse, RpcError> {
    let response = session
        .request(
            "thread/read",
            serde_json::json!({ "threadId": thread_id, "includeTurns": include_turns }),
        )
        .await?;
    serde_json::from_value::<upstream::ThreadReadResponse>(response).map_err(|error| {
        RpcError::Deserialization(format!("deserialize thread/read response: {error}"))
    })
}

pub(super) fn upsert_thread_snapshot_from_app_server_read_response(
    app_store: &AppStoreReducer,
    server_id: &str,
    response: upstream::ThreadReadResponse,
) -> Result<(), RpcError> {
    let turns = response.thread.turns.clone();
    let thread_id = response.thread.id.clone();
    let existing = app_store
        .snapshot()
        .threads
        .get(&ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        })
        .cloned();
    let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
        server_id,
        response.thread,
        None,
        None,
        response.approval_policy.map(Into::into),
        response.sandbox.map(Into::into),
    )
    .map_err(RpcError::Deserialization)?;
    if let Some(existing) = existing.as_ref() {
        copy_thread_runtime_fields(existing, &mut snapshot);
    }
    reconcile_active_turn(existing.as_ref(), &mut snapshot, &turns);
    app_store.upsert_thread_snapshot(snapshot);
    Ok(())
}

pub(super) fn upstream_thread_status_from_summary_status(
    status: ThreadSummaryStatus,
) -> upstream::ThreadStatus {
    match status {
        ThreadSummaryStatus::NotLoaded | ThreadSummaryStatus::Idle => upstream::ThreadStatus::Idle,
        ThreadSummaryStatus::Active => upstream::ThreadStatus::Active {
            active_flags: Vec::new(),
        },
        ThreadSummaryStatus::SystemError => upstream::ThreadStatus::SystemError,
    }
}

pub(super) fn thread_snapshot_from_upstream_thread(
    server_id: &str,
    thread: upstream::Thread,
) -> ThreadSnapshot {
    thread_snapshot_from_upstream_thread_state(server_id, thread, None, None, None, None, None)
}

pub(super) fn thread_snapshot_from_upstream_thread_state(
    server_id: &str,
    thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
    effective_approval_policy: Option<crate::types::AppAskForApproval>,
    effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    active_turn_id: Option<String>,
) -> ThreadSnapshot {
    let info = ThreadInfo::from(thread.clone());
    let items = crate::conversation::hydrate_turns(&thread.turns, &Default::default());
    let mut snapshot = ThreadSnapshot::from_info(server_id, info);
    snapshot.items = items;
    snapshot.model = model;
    snapshot.reasoning_effort = reasoning_effort;
    snapshot.effective_approval_policy = effective_approval_policy;
    snapshot.effective_sandbox_policy = effective_sandbox_policy;
    snapshot.active_turn_id = active_turn_id.or_else(|| active_turn_id_from_turns(&thread.turns));
    snapshot
}

pub(super) fn active_turn_id_from_turns(turns: &[upstream::Turn]) -> Option<String> {
    turns
        .iter()
        .rev()
        .find(|turn| matches!(turn.status, upstream::TurnStatus::InProgress))
        .map(|turn| turn.id.clone())
}

/// Decide active-turn state for a freshly-rebuilt thread snapshot, given the
/// caller's existing snapshot (if any) and the upstream turn list the rebuild
/// was derived from.
///
/// Rules:
/// - If `target` already shows an InProgress turn, trust it.
/// - Otherwise, if existing has an active turn:
///   - With no turn list available (e.g. include_turns=false), preserve local
///     state — we have no evidence the turn ended.
///   - With a turn list, preserve only if our local id appears as InProgress
///     (defensive); otherwise honor the rebuild and clear.
/// - `info.status` is derived from the resolved `active_turn_id`: Active iff
///   Some, otherwise the upstream-supplied value is left untouched.
pub fn reconcile_active_turn(
    existing: Option<&ThreadSnapshot>,
    target: &mut ThreadSnapshot,
    upstream_turns: &[upstream::Turn],
) {
    if target.active_turn_id.is_some() {
        target.info.status = ThreadSummaryStatus::Active;
        return;
    }
    let Some(local_id) = existing.and_then(|t| t.active_turn_id.clone()) else {
        return;
    };
    let preserve = if upstream_turns.is_empty() {
        true
    } else {
        upstream_turns
            .iter()
            .any(|t| t.id == local_id && matches!(t.status, upstream::TurnStatus::InProgress))
    };
    if preserve {
        target.active_turn_id = Some(local_id);
        target.info.status = ThreadSummaryStatus::Active;
    }
}

pub(super) fn approval_response_json(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
    decision: ApprovalDecisionValue,
) -> Result<serde_json::Value, RpcError> {
    match approval.kind {
        crate::types::ApprovalKind::Command => {
            serde_json::to_value(upstream::CommandExecutionRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => {
                        upstream::CommandExecutionApprovalDecision::Accept
                    }
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::CommandExecutionApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => {
                        upstream::CommandExecutionApprovalDecision::Decline
                    }
                    ApprovalDecisionValue::Cancel => {
                        upstream::CommandExecutionApprovalDecision::Cancel
                    }
                },
            })
        }
        crate::types::ApprovalKind::FileChange => {
            serde_json::to_value(upstream::FileChangeRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => upstream::FileChangeApprovalDecision::Accept,
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::FileChangeApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => upstream::FileChangeApprovalDecision::Decline,
                    ApprovalDecisionValue::Cancel => upstream::FileChangeApprovalDecision::Cancel,
                },
            })
        }
        crate::types::ApprovalKind::Permissions | crate::types::ApprovalKind::McpElicitation => {
            let requested_permissions = seed
                .map(|seed| seed.raw_params.clone())
                .and_then(|value: serde_json::Value| value.get("permissions").cloned())
                .and_then(|value| {
                    serde_json::from_value::<upstream::GrantedPermissionProfile>(value).ok()
                })
                .unwrap_or(upstream::GrantedPermissionProfile {
                    network: None,
                    file_system: None,
                });
            serde_json::to_value(upstream::PermissionsRequestApprovalResponse {
                permissions: match decision {
                    ApprovalDecisionValue::Accept | ApprovalDecisionValue::AcceptForSession => {
                        requested_permissions
                    }
                    ApprovalDecisionValue::Decline | ApprovalDecisionValue::Cancel => {
                        upstream::GrantedPermissionProfile {
                            network: None,
                            file_system: None,
                        }
                    }
                },
                scope: match decision {
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::PermissionGrantScope::Session
                    }
                    _ => upstream::PermissionGrantScope::Turn,
                },
                strict_auto_review: None,
            })
        }
    }
    .map_err(|e| RpcError::Deserialization(format!("serialize approval response: {e}")))
}

pub(super) fn approval_request_id(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
) -> upstream::RequestId {
    seed.map(|seed| seed.request_id.clone())
        .unwrap_or_else(|| fallback_server_request_id(&approval.id))
}

pub(super) fn fallback_server_request_id(id: &str) -> upstream::RequestId {
    id.parse::<i64>()
        .map(upstream::RequestId::Integer)
        .unwrap_or_else(|_| upstream::RequestId::String(id.to_string()))
}

pub(super) fn server_request_id_json(id: upstream::RequestId) -> serde_json::Value {
    match id {
        upstream::RequestId::Integer(value) => serde_json::Value::Number(value.into()),
        upstream::RequestId::String(value) => serde_json::Value::String(value),
    }
}
