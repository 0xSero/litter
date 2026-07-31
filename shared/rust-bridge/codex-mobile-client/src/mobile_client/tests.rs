#[cfg(test)]
mod mobile_client_tests {
    use super::super::*;
    use crate::session::connection::TestRequestHandler;
    use crate::types::ThreadSummaryStatus;
    use crate::types::{PendingUserInputOption, PendingUserInputQuestion};
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex as StdMutex};

    #[test]
    fn account_sync_warmup_only_runs_when_codex_runtime_is_present() {
        assert!(runtime_kinds_support_account_sync(&["codex".to_string()]));
        assert!(runtime_kinds_support_account_sync(&[
            "pi".to_string(),
            "codex".to_string(),
        ]));
        assert!(!runtime_kinds_support_account_sync(&["pi".to_string()]));
        assert!(!runtime_kinds_support_account_sync(&[
            "pi".to_string(),
            "opencode".to_string(),
        ]));
        assert!(!runtime_kinds_support_account_sync(&[]));
    }

    fn make_thread_info(id: &str) -> ThreadInfo {
        ThreadInfo {
            id: id.to_string(),
            title: Some("Thread".to_string()),
            model: None,
            status: ThreadSummaryStatus::Active,
            preview: Some("preview".to_string()),
            cwd: Some("/tmp".to_string()),
            path: Some("/tmp".to_string()),
            model_provider: Some("openai".to_string()),
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            forked_from_id: None,
            agent_status: None,
            created_at: Some(1),
            updated_at: Some(2),
        }
    }

    fn make_user_input_request(question: PendingUserInputQuestion) -> PendingUserInputRequest {
        PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
            turn_id: "turn-1".to_string(),
            item_id: "item-1".to_string(),
            questions: vec![question],
            requester_agent_nickname: None,
            requester_agent_role: None,
        }
    }

    fn make_server_config(server_id: &str) -> ServerConfig {
        ServerConfig {
            server_id: server_id.to_string(),
            display_name: server_id.to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            websocket_url: Some("ws://127.0.0.1:0".to_string()),
            is_local: false,
            tls: false,
        }
    }

    fn make_model_info(
        id: &str,
        model: &str,
        runtime_kind: AgentRuntimeKind,
    ) -> crate::types::ModelInfo {
        crate::types::ModelInfo {
            id: id.to_string(),
            model: model.to_string(),
            upgrade: None,
            upgrade_model: None,
            upgrade_copy: None,
            model_link: None,
            migration_markdown: None,
            availability_nux_message: None,
            display_name: id.to_string(),
            description: String::new(),
            hidden: false,
            supported_reasoning_efforts: Vec::new(),
            default_reasoning_effort: crate::types::ReasoningEffort::Medium,
            input_modalities: Vec::new(),
            supports_personality: false,
            is_default: false,
            agent_runtime_kind: runtime_kind,
            provider_id: None,
        }
    }

    fn thread_snapshot_with_active_turn(
        server_id: &str,
        thread_id: &str,
        active_turn_id: &str,
    ) -> ThreadSnapshot {
        let mut thread = ThreadSnapshot::from_info(server_id, make_thread_info(thread_id));
        thread.active_turn_id = Some(active_turn_id.to_string());
        thread
    }

    #[test]
    fn reasoning_effort_parsing_accepts_known_values() {
        assert_eq!(
            reasoning_effort_from_string("low"),
            Some(crate::types::ReasoningEffort::Low)
        );
        assert_eq!(
            reasoning_effort_from_string("MEDIUM"),
            Some(crate::types::ReasoningEffort::Medium)
        );
        assert_eq!(
            reasoning_effort_from_string(" high "),
            Some(crate::types::ReasoningEffort::High)
        );
        for (value, expected) in [
            ("max", crate::types::ReasoningEffort::Max),
            ("ULTRA", crate::types::ReasoningEffort::Ultra),
        ] {
            assert_eq!(reasoning_effort_from_string(value), Some(expected));
        }
        assert_eq!(reasoning_effort_from_string(""), None);
    }

    #[test]
    fn detects_slingshot_initialize_timeout_for_retry() {
        let error = TransportError::ConnectionFailed(
            "slingshot app-server handshake failed: timed out waiting for initialize response from `slingshot://env_123`"
                .to_string(),
        );
        assert!(is_slingshot_initialize_timeout(&error));

        let other = TransportError::ConnectionFailed("remote websocket closed".to_string());
        assert!(!is_slingshot_initialize_timeout(&other));
    }

    #[test]
    fn normalize_pending_user_input_wraps_freeform_answers_as_notes() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Explain the choice".to_string(),
            is_other_allowed: true,
            is_secret: false,
            options: Vec::new(),
        });

        let normalized = normalize_pending_user_input_answers(
            &request,
            &[PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["Need to update the reducer".to_string()],
            }],
        );

        assert_eq!(
            normalized,
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["user_note: Need to update the reducer".to_string()],
            }]
        );
    }

    #[test]
    fn normalize_pending_user_input_injects_other_option_for_custom_answers() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Choose one".to_string(),
            is_other_allowed: true,
            is_secret: false,
            options: vec![PendingUserInputOption {
                label: "Option A".to_string(),
                description: None,
            }],
        });

        let normalized = normalize_pending_user_input_answers(
            &request,
            &[PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["My custom answer".to_string()],
            }],
        );

        assert_eq!(
            normalized,
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec![
                    "None of the above".to_string(),
                    "user_note: My custom answer".to_string(),
                ],
            }]
        );
    }

    #[test]
    fn copy_thread_runtime_fields_preserves_existing_runtime_state() {
        let source = ThreadSnapshot {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            },
            info: {
                let mut info = make_thread_info("thread-1");
                info.status = ThreadSummaryStatus::Active;
                info
            },
            agent_runtime_kind: "codex".to_string(),
            collaboration_mode: AppModeKind::Plan,
            model: Some("gpt-5".to_string()),
            reasoning_effort: Some("high".to_string()),
            effective_approval_policy: None,
            effective_sandbox_policy: None,
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: vec![AppQueuedFollowUpPreview {
                id: "queued-1".to_string(),
                kind: AppQueuedFollowUpKind::Message,
                text: "follow-up".to_string(),
            }],
            queued_follow_up_drafts: Vec::new(),
            active_turn_id: Some("turn-1".to_string()),
            context_tokens_used: Some(12_345),
            model_context_window: Some(200_000),
            rate_limits: Some(crate::types::RateLimits {
                requests_remaining: Some(10),
                tokens_remaining: Some(20_000),
                reset_at: Some("2026-03-25T12:00:00Z".to_string()),
            }),
            realtime_session_id: Some("rt-1".to_string()),
            goal: None,
            active_plan_progress: Some(crate::types::AppPlanProgressSnapshot {
                turn_id: "turn-1".to_string(),
                explanation: Some("Ship plan mode".to_string()),
                plan: vec![crate::types::AppPlanStep {
                    step: "Build parser".to_string(),
                    status: crate::types::AppPlanStepStatus::InProgress,
                }],
            }),
            pending_plan_implementation_turn_id: Some("turn-1".to_string()),
            older_turns_cursor: None,
            initial_turns_loaded: false,
            is_resumed: true,
        };
        let mut target = ThreadSnapshot::from_info("srv", {
            // The default `make_thread_info` returns `status: Active`,
            // but this test verifies that `copy_thread_runtime_fields`
            // does NOT propagate `active_turn_id` / `info.status` from
            // `source` into a target whose own state says Idle.
            let mut info = make_thread_info("thread-1");
            info.status = ThreadSummaryStatus::Idle;
            info
        });

        copy_thread_runtime_fields(&source, &mut target);

        assert_eq!(target.model.as_deref(), Some("gpt-5"));
        assert_eq!(target.collaboration_mode, AppModeKind::Plan);
        assert_eq!(target.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(target.queued_follow_ups, source.queued_follow_ups);
        assert_eq!(target.active_turn_id, None);
        assert_eq!(target.info.status, ThreadSummaryStatus::Idle);
        assert_eq!(target.context_tokens_used, Some(12_345));
        assert_eq!(target.model_context_window, Some(200_000));
        assert_eq!(
            target
                .rate_limits
                .as_ref()
                .and_then(|limits| limits.tokens_remaining),
            Some(20_000)
        );
        assert_eq!(target.realtime_session_id.as_deref(), Some("rt-1"));
        assert_eq!(target.active_plan_progress, source.active_plan_progress);
        assert_eq!(
            target.pending_plan_implementation_turn_id,
            source.pending_plan_implementation_turn_id
        );
        assert!(target.is_resumed);
    }

    #[test]
    fn copy_thread_runtime_fields_does_not_preserve_effective_permissions() {
        let source = ThreadSnapshot {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            },
            info: make_thread_info("thread-1"),
            agent_runtime_kind: "codex".to_string(),
            collaboration_mode: AppModeKind::Default,
            model: None,
            reasoning_effort: None,
            effective_approval_policy: Some(crate::types::AppAskForApproval::Never),
            effective_sandbox_policy: Some(crate::types::AppSandboxPolicy::DangerFullAccess),
            items: Vec::new(),
            local_overlay_items: Vec::new(),
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
        };
        let mut target = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));

        copy_thread_runtime_fields(&source, &mut target);

        assert_eq!(target.effective_approval_policy, None);
        assert_eq!(target.effective_sandbox_policy, None);
    }

    #[test]
    fn thread_start_runtime_uses_selected_model_runtime() {
        let client = MobileClient::new();
        client
            .app_store
            .upsert_server(&make_server_config("srv"), ServerHealthSnapshot::Connected);
        client.app_store.update_server_models(
            "srv",
            Some(vec![make_model_info(
                "claude-sonnet-4.5",
                "claude-sonnet-4.5",
                "claude".to_string(),
            )]),
        );

        assert_eq!(
            client.runtime_for_thread_start("srv", None, Some("claude-sonnet-4.5")),
            "claude".to_string()
        );
    }

    #[test]
    fn thread_start_runtime_explicit_agent_wins_over_duplicate_model() {
        let client = MobileClient::new();
        client
            .app_store
            .upsert_server(&make_server_config("srv"), ServerHealthSnapshot::Connected);
        client.app_store.update_server_models(
            "srv",
            Some(vec![
                make_model_info("claude-sonnet-4.6", "claude-sonnet-4.6", "pi".to_string()),
                make_model_info(
                    "claude-sonnet-4.6",
                    "claude-sonnet-4.6",
                    "claude".to_string(),
                ),
            ]),
        );

        assert_eq!(
            client.runtime_for_thread_start(
                "srv",
                Some("pi".to_string()),
                Some("claude-sonnet-4.6"),
            ),
            "pi".to_string()
        );
    }

    #[test]
    fn normalizes_selected_model_to_runtime_advertised_id() {
        let client = MobileClient::new();
        client
            .app_store
            .upsert_server(&make_server_config("srv"), ServerHealthSnapshot::Connected);
        client.app_store.update_server_models(
            "srv",
            Some(vec![make_model_info(
                "anthropic/claude-sonnet-4.6",
                "claude-sonnet-4.6",
                "pi".to_string(),
            )]),
        );

        let mut model = Some("claude-sonnet-4.6".to_string());
        client.normalize_thread_model_for_runtime("srv", "pi".to_string(), &mut model);

        assert_eq!(model.as_deref(), Some("anthropic/claude-sonnet-4.6"));
    }

    #[test]
    fn thread_start_runtime_explicit_override_wins_over_selected_model() {
        let client = MobileClient::new();
        client
            .app_store
            .upsert_server(&make_server_config("srv"), ServerHealthSnapshot::Connected);
        client.app_store.update_server_models(
            "srv",
            Some(vec![make_model_info(
                "claude-sonnet-4.5",
                "claude-sonnet-4.5",
                "claude".to_string(),
            )]),
        );

        assert_eq!(
            client.runtime_for_thread_start(
                "srv",
                Some("opencode".to_string()),
                Some("claude-sonnet-4.5"),
            ),
            "opencode".to_string()
        );
    }

    #[test]
    fn alleycat_short_circuit_detects_missing_selected_runtime() {
        let requested = vec![
            (
                "codex".to_string(),
                AlleycatAgentInfo {
                    name: "codex".to_string(),
                    display_name: "Codex".to_string(),
                    wire: AlleycatAgentWire::Websocket,
                    available: true,
                    presentation: None,
                    capabilities: None,
                },
            ),
            (
                "droid".to_string(),
                AlleycatAgentInfo {
                    name: "droid".to_string(),
                    display_name: "Droid".to_string(),
                    wire: AlleycatAgentWire::Jsonl,
                    available: true,
                    presentation: None,
                    capabilities: None,
                },
            ),
            (
                "amp".to_string(),
                AlleycatAgentInfo {
                    name: "amp".to_string(),
                    display_name: "Amp".to_string(),
                    wire: AlleycatAgentWire::Jsonl,
                    available: true,
                    presentation: None,
                    capabilities: None,
                },
            ),
        ];
        let requested_kinds = alleycat_requested_runtime_kinds(&requested);

        assert_eq!(alleycat_runtime_agent_names(&requested), "codex,droid,amp");
        assert_eq!(
            missing_runtime_kinds(&["codex".to_string()], &requested_kinds),
            vec!["amp".to_string(), "droid".to_string()]
        );
        assert!(
            missing_runtime_kinds(
                &["codex".to_string(), "droid".to_string(), "amp".to_string()],
                &requested_kinds
            )
            .is_empty()
        );
    }

    #[test]
    fn pi_runtimes_always_start_full_access() {
        let client = MobileClient::new();
        for (runtime, approval_policy, sandbox) in [
            ("pi", None, None),
            (
                "pi",
                Some(upstream::AskForApproval::OnRequest),
                Some(upstream::SandboxMode::WorkspaceWrite),
            ),
            ("local-studio", None, None),
        ] {
            let mut request = upstream::ClientRequest::ThreadStart {
                request_id: upstream::RequestId::Integer(1),
                params: upstream::ThreadStartParams {
                    approval_policy,
                    sandbox,
                    ..Default::default()
                },
            };
            client.normalize_model_selection_for_request("srv", runtime.into(), &mut request);
            let upstream::ClientRequest::ThreadStart { params, .. } = request else {
                panic!("expected thread/start");
            };
            assert_eq!(
                params.approval_policy,
                Some(upstream::AskForApproval::Never)
            );
            assert_eq!(
                params.sandbox,
                Some(upstream::SandboxMode::DangerFullAccess)
            );
        }
    }

    #[test]
    fn thread_runtime_infers_claude_from_existing_thread_model() {
        let client = MobileClient::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-claude".to_string(),
        };
        let mut info = make_thread_info(&key.thread_id);
        info.model = Some("anthropic/claude-opus-4-7".to_string());
        info.model_provider = Some("openai".to_string());
        client
            .app_store
            .upsert_thread_snapshot(ThreadSnapshot::from_info(&key.server_id, info));
        client.note_thread_runtime(key.clone(), "codex".to_string());

        assert_eq!(client.runtime_for_thread(&key), "claude".to_string());
    }

    #[test]
    fn thread_runtime_infers_claude_from_existing_thread_model_provider() {
        let client = MobileClient::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-anthropic".to_string(),
        };
        let mut info = make_thread_info(&key.thread_id);
        info.model_provider = Some("anthropic".to_string());
        client
            .app_store
            .upsert_thread_snapshot(ThreadSnapshot::from_info(&key.server_id, info));

        assert_eq!(client.runtime_for_thread(&key), "claude".to_string());
    }

    #[test]
    fn thread_runtime_infers_non_codex_from_existing_thread_model_provider() {
        for (provider, expected_runtime) in [
            ("opencode", "opencode".to_string()),
            ("open code", "opencode".to_string()),
            ("amp", "amp".to_string()),
            ("amp code", "amp".to_string()),
            ("pi", "pi".to_string()),
            ("pi.dev", "pi".to_string()),
            ("factory", "droid".to_string()),
            ("factory droid", "droid".to_string()),
        ] {
            let client = MobileClient::new();
            let key = ThreadKey {
                server_id: "srv".to_string(),
                thread_id: format!("thread-{provider}"),
            };
            let mut info = make_thread_info(&key.thread_id);
            info.model_provider = Some(provider.to_string());
            client
                .app_store
                .upsert_thread_snapshot(ThreadSnapshot::from_info(&key.server_id, info));
            client.note_thread_runtime(key.clone(), "codex".to_string());

            assert_eq!(client.runtime_for_thread(&key), expected_runtime);
        }
    }

    #[test]
    fn thread_runtime_infers_non_codex_from_existing_thread_model_prefix() {
        for (model, expected_runtime) in [
            ("opencode/qwen3-coder", "opencode".to_string()),
            ("amp/smart", "amp".to_string()),
            ("pi.dev/default", "pi".to_string()),
            ("factory/droid", "droid".to_string()),
        ] {
            let client = MobileClient::new();
            let key = ThreadKey {
                server_id: "srv".to_string(),
                thread_id: format!("thread-{model}"),
            };
            let mut info = make_thread_info(&key.thread_id);
            info.model = Some(model.to_string());
            info.model_provider = Some("openai".to_string());
            client
                .app_store
                .upsert_thread_snapshot(ThreadSnapshot::from_info(&key.server_id, info));
            client.note_thread_runtime(key.clone(), "codex".to_string());

            assert_eq!(client.runtime_for_thread(&key), expected_runtime);
        }
    }

    #[test]
    fn upsert_thread_snapshot_from_thread_read_response_leaves_effective_permissions_unset() {
        // Upstream `thread/read` no longer carries approvalPolicy / sandbox;
        // those fields only ride on `thread/resume`. Confirm the read path
        // leaves `effective_*_policy` as `None` so a later resume populates
        // them authoritatively instead of inheriting stale values.
        let reducer = AppStoreReducer::new();
        let response: upstream::ThreadReadResponse = serde_json::from_value(serde_json::json!({
            "thread": {
                "id": "thread-1",
                "sessionId": "session-1",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": { "type": "idle" },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": "cli",
                "agentNickname": null,
                "agentRole": null,
                "gitInfo": null,
                "name": "thread",
                "turns": []
            }
        }))
        .expect("thread/read response should deserialize");

        upsert_thread_snapshot_from_app_server_read_response(&reducer, "srv", response)
            .expect("upsert should succeed");

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let snapshot = reducer
            .snapshot()
            .threads
            .into_iter()
            .find_map(|(thread_key, thread)| (thread_key == key).then_some(thread))
            .expect("thread snapshot should exist");

        assert!(snapshot.effective_approval_policy.is_none());
        assert!(snapshot.effective_sandbox_policy.is_none());
    }

    #[test]
    fn upsert_thread_snapshot_from_thread_read_response_clears_completed_active_turn() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let mut existing = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));
        existing.active_turn_id = Some("turn-1".to_string());
        existing.info.status = ThreadSummaryStatus::Active;
        reducer.upsert_thread_snapshot(existing);

        let response: upstream::ThreadReadResponse = serde_json::from_value(serde_json::json!({
            "thread": {
                "id": "thread-1",
                "sessionId": "session-1",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": { "type": "idle" },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": "cli",
                "agentNickname": null,
                "agentRole": null,
                "gitInfo": null,
                "name": "thread",
                "turns": [
                    {
                        "id": "turn-1",
                        "items": [],
                        "itemsView": "full",
                        "status": "completed",
                        "error": null,
                        "startedAt": null,
                        "completedAt": null,
                        "durationMs": null
                    }
                ]
            }
        }))
        .expect("thread/read response should deserialize");

        upsert_thread_snapshot_from_app_server_read_response(&reducer, "srv", response)
            .expect("upsert should succeed");

        let snapshot = reducer
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("thread snapshot should exist");

        assert_eq!(snapshot.active_turn_id, None);
        assert_eq!(snapshot.info.status, ThreadSummaryStatus::Idle);
    }

    #[test]
    fn authoritative_completed_turn_clears_stale_active_status_and_id() {
        let existing = thread_snapshot_with_active_turn("srv", "thread-1", "turn-1");
        let mut target = existing.clone();
        target.active_turn_id = None;
        let turns: Vec<upstream::Turn> = serde_json::from_value(json!([{
            "id": "turn-1",
            "items": [],
            "itemsView": "notLoaded",
            "status": "completed",
            "error": null,
            "startedAt": 1,
            "completedAt": 2,
            "durationMs": 1
        }]))
        .expect("completed turn skeleton should deserialize");

        reconcile_active_turn(Some(&existing), &mut target, &turns);

        assert_eq!(target.active_turn_id, None);
        assert_eq!(target.info.status, ThreadSummaryStatus::Idle);
    }

    #[test]
    fn force_authoritative_waiter_does_not_reuse_normal_resume_marker() {
        assert!(!can_reuse_waited_resume(true, true, true));
        assert!(can_reuse_waited_resume(true, false, true));
    }

    #[tokio::test]
    async fn external_resume_thread_falls_back_to_metadata_read_after_worker_channel_closes() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let request_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| {
                requests
                    .lock()
                    .expect("request log lock should not be poisoned")
                    .push(request.method().to_string());
                match request {
                    upstream::ClientRequest::ThreadResume { .. } => {
                        Err(RpcError::Transport(TransportError::SendFailed(
                            "remote app-server worker channel is closed".to_string(),
                        )))
                    }
                    upstream::ClientRequest::ThreadRead { params, .. } => {
                        assert!(
                            !params.include_turns,
                            "metadata fallback should avoid loading turns"
                        );
                        serde_json::to_value(serde_json::json!({
                            "thread": {
                                "id": thread_id,
                                "preview": "hi",
                                "ephemeral": false,
                                "modelProvider": "openai",
                                "createdAt": 1,
                                "updatedAt": 2,
                                "status": { "type": "idle" },
                                "path": "/tmp/thread",
                                "cwd": "/tmp/thread",
                                "cliVersion": "1.0.0",
                                "source": "cli",
                                "agentNickname": null,
                                "agentRole": null,
                                "gitInfo": null,
                                "name": "thread",
                                "turns": []
                            },
                            "approvalPolicy": "never",
                            "sandbox": {
                                "type": "dangerFullAccess"
                            }
                        }))
                        .map_err(|error| RpcError::Deserialization(error.to_string()))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("resume should fall back to metadata read");

        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(
            requests.as_slice(),
            ["thread/resume", "thread/read"],
            "resume should retry with metadata-only thread/read"
        );
        drop(requests);

        let snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&ThreadKey {
                server_id: server_id.to_string(),
                thread_id: thread_id.to_string(),
            })
            .cloned()
            .expect("thread snapshot should exist after fallback");
        assert!(snapshot.items.is_empty());
        assert_eq!(
            snapshot.effective_approval_policy,
            Some(crate::types::AppAskForApproval::Never)
        );
        assert_eq!(
            snapshot.effective_sandbox_policy,
            Some(crate::types::AppSandboxPolicy::DangerFullAccess)
        );
    }

    #[tokio::test]
    async fn external_resume_thread_tries_registered_runtimes_for_unknown_pinned_thread() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let codex_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| {
                requests
                    .lock()
                    .expect("request log lock should not be poisoned")
                    .push(format!("codex:{}", request.method()));
                Err(RpcError::Deserialization(
                    "no rollout found for thread id thread-1".to_string(),
                ))
            })
        };
        let claude_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| {
                requests
                    .lock()
                    .expect("request log lock should not be poisoned")
                    .push(format!("claude:{}", request.method()));
                match request {
                    upstream::ClientRequest::ThreadResume { .. } => {
                        serde_json::to_value(serde_json::json!({
                            "thread": {
                                "id": thread_id,
                                "preview": "hi",
                                "ephemeral": false,
                                "modelProvider": "anthropic",
                                "createdAt": 1,
                                "updatedAt": 2,
                                "status": { "type": "idle" },
                                "path": "/tmp/thread",
                                "cwd": "/tmp/thread",
                                "cliVersion": "1.0.0",
                                "source": "cli",
                                "agentNickname": null,
                                "agentRole": null,
                                "gitInfo": null,
                                "name": "thread",
                                "turns": []
                            },
                            "model": "claude-sonnet-4.5",
                            "modelProvider": "anthropic",
                            "cwd": "/tmp/thread",
                            "approvalPolicy": "never",
                            "approvalsReviewer": "user",
                            "sandbox": {
                                "type": "dangerFullAccess"
                            },
                            "reasoningEffort": "medium"
                        }))
                        .map_err(|error| RpcError::Deserialization(error.to_string()))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_runtime_handlers(
            config,
            vec![
                ("codex".to_string(), codex_handler),
                ("claude".to_string(), claude_handler),
            ],
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("resume should try the registered non-Codex runtime");

        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(
            requests.as_slice(),
            ["codex:thread/resume", "claude:thread/resume"],
            "resume should try the default route, then the registered runtime"
        );
        drop(requests);

        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("thread snapshot should exist after runtime fallback");
        assert!(snapshot.is_resumed);
        assert_eq!(snapshot.agent_runtime_kind, "claude".to_string());
        assert_eq!(client.runtime_for_thread(&key), "claude".to_string());
    }

    #[tokio::test]
    async fn external_resume_thread_skips_duplicate_direct_resume_for_current_session() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let request_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| {
                requests
                    .lock()
                    .expect("request log lock should not be poisoned")
                    .push(request.method().to_string());
                match request {
                    upstream::ClientRequest::ThreadResume { .. } => {
                        serde_json::to_value(serde_json::json!({
                            "thread": {
                                "id": thread_id,
                                "preview": "hi",
                                "ephemeral": false,
                                "modelProvider": "openai",
                                "createdAt": 1,
                                "updatedAt": 2,
                                "status": { "type": "idle" },
                                "path": "/tmp/thread",
                                "cwd": "/tmp/thread",
                                "cliVersion": "1.0.0",
                                "source": "cli",
                                "agentNickname": null,
                                "agentRole": null,
                                "gitInfo": null,
                                "name": "thread",
                                "turns": []
                            },
                            "model": "gpt-5",
                            "modelProvider": "openai",
                            "cwd": "/tmp/thread",
                            "approvalPolicy": "never",
                            "approvalsReviewer": "user",
                            "sandbox": {
                                "type": "dangerFullAccess"
                            },
                            "reasoningEffort": "medium"
                        }))
                        .map_err(|error| RpcError::Deserialization(error.to_string()))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("first resume should attach direct listener");
        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("second resume should be skipped");

        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(
            requests.as_slice(),
            ["thread/resume"],
            "duplicate direct resume should not call app-server again"
        );
    }

    #[tokio::test]
    async fn load_thread_turns_page_falls_back_to_embedded_resume_when_method_missing() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let request_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| {
                match &request {
                    upstream::ClientRequest::ThreadResume { params, .. } => {
                        requests
                            .lock()
                            .expect("request log lock should not be poisoned")
                            .push(format!("thread/resume:{}", params.exclude_turns));
                    }
                    other => {
                        requests
                            .lock()
                            .expect("request log lock should not be poisoned")
                            .push(other.method().to_string());
                    }
                }
                match request {
                    upstream::ClientRequest::ThreadResume { params, .. } => {
                        let turns = if params.exclude_turns {
                            json!([])
                        } else {
                            json!([{
                                "id": "turn-1",
                                "items": [{
                                    "id": "item-1",
                                    "type": "userMessage",
                                    "content": [{
                                        "type": "text",
                                        "text": "hello",
                                        "textElements": []
                                    }]
                                }],
                                "status": "completed",
                                "error": null,
                                "startedAt": null,
                                "completedAt": 2,
                                "durationMs": 1
                            }])
                        };
                        serde_json::to_value(json!({
                            "thread": {
                                "id": thread_id,
                                "preview": "hello",
                                "ephemeral": false,
                                "modelProvider": "openai",
                                "createdAt": 1,
                                "updatedAt": 2,
                                "status": { "type": "idle" },
                                "path": "/tmp/thread",
                                "cwd": "/tmp/thread",
                                "cliVersion": "1.0.0",
                                "source": "cli",
                                "agentNickname": null,
                                "agentRole": null,
                                "gitInfo": null,
                                "name": "thread",
                                "turns": turns
                            },
                            "model": "gpt-5",
                            "modelProvider": "openai",
                            "cwd": "/tmp/thread",
                            "approvalPolicy": "never",
                            "approvalsReviewer": "user",
                            "sandbox": { "type": "dangerFullAccess" },
                            "reasoningEffort": "medium"
                        }))
                        .map_err(|error| RpcError::Deserialization(error.to_string()))
                    }
                    upstream::ClientRequest::ThreadTurnsList { .. } => {
                        Err(RpcError::Deserialization(
                            "server error -32601: method `thread/turns/list` is not implemented"
                                .to_string(),
                        ))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("initial resume should succeed");

        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let initial_snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("snapshot after initial resume");
        assert!(initial_snapshot.items.is_empty());
        assert!(!initial_snapshot.initial_turns_loaded);

        let outcome = client
            .load_thread_turns_page(server_id, thread_id, None, Some(5))
            .await
            .expect("turn load should fall back to embedded resume");
        assert!(outcome.loaded);
        assert!(!outcome.has_more);

        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(
            requests.as_slice(),
            [
                "thread/resume:true",
                "thread/turns/list",
                "thread/resume:false"
            ]
        );
        drop(requests);

        let snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("snapshot after fallback resume");
        assert_eq!(snapshot.items.len(), 1);
        assert!(snapshot.initial_turns_loaded);
        assert!(!client.app_store.server_supports_turn_pagination(server_id));
    }

    #[tokio::test]
    async fn force_refresh_thread_authoritative_falls_back_to_embedded_resume_for_amp_probe_miss() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-amp";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);

        let mut thread = thread_snapshot_with_active_turn(server_id, thread_id, "turn-active");
        thread.agent_runtime_kind = "amp".to_string();
        thread.model = Some("amp/smart".to_string());
        thread.info.model_provider = Some("amp".to_string());
        client.app_store.upsert_thread_snapshot(thread);
        client.note_thread_runtime(key.clone(), "amp".to_string());

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let amp_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| match request {
                upstream::ClientRequest::ThreadResume { params, .. } => {
                    requests
                        .lock()
                        .expect("request log lock should not be poisoned")
                        .push(format!("amp:thread/resume:{}", params.exclude_turns));
                    let turns = if params.exclude_turns {
                        json!([])
                    } else {
                        json!([{
                            "id": "turn-active",
                            "items": [],
                            "itemsView": "full",
                            "status": "completed",
                            "error": null,
                            "startedAt": null,
                            "completedAt": 2,
                            "durationMs": 1
                        }])
                    };
                    serde_json::to_value(json!({
                        "thread": {
                            "id": thread_id,
                            "preview": "Amp reasoning",
                            "ephemeral": false,
                            "modelProvider": "amp",
                            "createdAt": 1,
                            "updatedAt": 2,
                            "status": { "type": "idle" },
                            "path": "/tmp/thread",
                            "cwd": "/tmp/thread",
                            "cliVersion": "1.0.0",
                            "source": "cli",
                            "agentNickname": null,
                            "agentRole": null,
                            "gitInfo": null,
                            "name": "thread",
                            "turns": turns
                        },
                        "model": "amp/smart",
                        "modelProvider": "amp",
                        "cwd": "/tmp/thread",
                        "approvalPolicy": "never",
                        "approvalsReviewer": "user",
                        "sandbox": { "type": "dangerFullAccess" },
                        "reasoningEffort": null
                    }))
                    .map_err(|error| RpcError::Deserialization(error.to_string()))
                }
                upstream::ClientRequest::ThreadTurnsList { .. } => {
                    requests
                        .lock()
                        .expect("request log lock should not be poisoned")
                        .push("amp:thread/turns/list".to_string());
                    Err(RpcError::Deserialization(
                        "server error -32601: method `thread/turns/list` is not implemented"
                            .to_string(),
                    ))
                }
                other => Err(RpcError::Deserialization(format!(
                    "unexpected request in test: {}",
                    other.method()
                ))),
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_runtime_handlers(
            config,
            vec![("amp".to_string(), amp_handler)],
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .force_refresh_thread_authoritative(server_id, thread_id)
            .await
            .expect("force refresh should fall back through embedded resume");

        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(
            requests.as_slice(),
            [
                "amp:thread/resume:true",
                "amp:thread/turns/list",
                "amp:thread/resume:false"
            ]
        );
        drop(requests);

        let snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("thread snapshot after force refresh");
        assert_eq!(snapshot.active_turn_id, None);
        assert_eq!(snapshot.info.status, ThreadSummaryStatus::Idle);
        assert!(client.app_store.server_supports_turn_pagination(server_id));
    }

    #[tokio::test]
    async fn reopening_active_thread_repairs_items_missed_while_away() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-running";
        let turn_id = "turn-active";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);
        client
            .app_store
            .upsert_thread_snapshot(thread_snapshot_with_active_turn(
                server_id, thread_id, turn_id,
            ));

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let request_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| match request {
                upstream::ClientRequest::ThreadResume { params, .. } => {
                    requests
                        .lock()
                        .expect("request log lock should not be poisoned")
                        .push(format!("thread/resume:{}", params.exclude_turns));
                    Ok(json!({
                        "thread": {
                            "id": thread_id,
                            "preview": "Running",
                            "ephemeral": false,
                            "modelProvider": "pi",
                            "createdAt": 1,
                            "updatedAt": 2,
                            "status": { "type": "active", "activeFlags": [] },
                            "path": "/tmp/thread",
                            "cwd": "/tmp/thread",
                            "cliVersion": "1.0.0",
                            "source": "appServer",
                            "agentNickname": null,
                            "agentRole": null,
                            "gitInfo": null,
                            "name": "thread",
                            "turns": []
                        },
                        "model": "GLM-5.2",
                        "modelProvider": "pi",
                        "cwd": "/tmp/thread",
                        "approvalPolicy": "never",
                        "approvalsReviewer": "user",
                        "sandbox": { "type": "dangerFullAccess" },
                        "reasoningEffort": "high"
                    }))
                }
                upstream::ClientRequest::ThreadTurnsList { params, .. } => {
                    let skeleton_only =
                        matches!(params.items_view, Some(upstream::TurnItemsView::NotLoaded));
                    requests
                        .lock()
                        .expect("request log lock should not be poisoned")
                        .push(format!("thread/turns/list:{skeleton_only}"));
                    let items = if skeleton_only {
                        json!([])
                    } else {
                        json!([{
                            "id": "tool-running",
                            "type": "commandExecution",
                            "command": "sleep 30",
                            "cwd": "/tmp/thread",
                            "processId": null,
                            "source": "agent",
                            "status": "inProgress",
                            "commandActions": [],
                            "aggregatedOutput": null,
                            "exitCode": null,
                            "durationMs": null
                        }])
                    };
                    Ok(json!({
                        "data": [{
                            "id": turn_id,
                            "items": items,
                            "itemsView": if skeleton_only { "notLoaded" } else { "full" },
                            "status": "inProgress",
                            "error": null,
                            "startedAt": 1,
                            "completedAt": null,
                            "durationMs": null
                        }],
                        "nextCursor": null,
                        "backwardsCursor": null
                    }))
                }
                other => Err(RpcError::Deserialization(format!(
                    "unexpected request in test: {}",
                    other.method()
                ))),
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client.mark_direct_resumed_thread(key.clone());
        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("reopening should repair the active turn");

        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(
            requests.as_slice(),
            [
                "thread/resume:true",
                "thread/turns/list:true",
                "thread/turns/list:false"
            ]
        );
        drop(requests);

        let snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("thread snapshot after force refresh");
        assert_eq!(snapshot.active_turn_id.as_deref(), Some(turn_id));
        assert_eq!(snapshot.info.status, ThreadSummaryStatus::Active);
        assert!(
            snapshot.items.iter().any(|item| {
                item.id == "tool-running"
                    && matches!(
                        item.content,
                        crate::conversation_uniffi::HydratedConversationItemContent::CommandExecution(_)
                    )
            }),
            "the full repair page should restore the missed command item"
        );
    }

    #[tokio::test]
    async fn external_resume_refreshes_direct_marker_when_thread_is_empty_and_unloaded() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let request_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| match request {
                upstream::ClientRequest::ThreadResume { params, .. } => {
                    requests
                        .lock()
                        .expect("request log lock should not be poisoned")
                        .push(format!("thread/resume:{}", params.exclude_turns));
                    let turns = if params.exclude_turns {
                        json!([])
                    } else {
                        json!([{
                            "id": "turn-1",
                            "items": [{
                                "id": "item-1",
                                "type": "userMessage",
                                "content": [{
                                    "type": "text",
                                    "text": "hello",
                                    "textElements": []
                                }]
                            }],
                            "status": "completed",
                            "error": null,
                            "startedAt": null,
                            "completedAt": 2,
                            "durationMs": 1
                        }])
                    };
                    serde_json::to_value(json!({
                        "thread": {
                            "id": thread_id,
                            "preview": "hello",
                            "ephemeral": false,
                            "modelProvider": "openai",
                            "createdAt": 1,
                            "updatedAt": 2,
                            "status": { "type": "idle" },
                            "path": "/tmp/thread",
                            "cwd": "/tmp/thread",
                            "cliVersion": "1.0.0",
                            "source": "cli",
                            "agentNickname": null,
                            "agentRole": null,
                            "gitInfo": null,
                            "name": "thread",
                            "turns": turns
                        },
                        "model": "gpt-5",
                        "modelProvider": "openai",
                        "cwd": "/tmp/thread",
                        "approvalPolicy": "never",
                        "approvalsReviewer": "user",
                        "sandbox": { "type": "dangerFullAccess" },
                        "reasoningEffort": "medium"
                    }))
                    .map_err(|error| RpcError::Deserialization(error.to_string()))
                }
                other => Err(RpcError::Deserialization(format!(
                    "unexpected request in test: {}",
                    other.method()
                ))),
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("initial resume should succeed");
        client
            .app_store
            .set_server_supports_turn_pagination(server_id, false);
        client
            .external_resume_thread(server_id, thread_id, None)
            .await
            .expect("second resume should refresh embedded turns");

        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(
            requests.as_slice(),
            ["thread/resume:true", "thread/resume:false"]
        );
        drop(requests);

        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("snapshot after fallback resume");
        assert_eq!(snapshot.items.len(), 1);
        assert!(snapshot.initial_turns_loaded);
    }

    #[tokio::test]
    async fn load_thread_turns_page_uses_embedded_resume_when_pagination_is_disabled() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);
        client
            .app_store
            .set_server_supports_turn_pagination(server_id, false);

        let requests = Arc::new(StdMutex::new(Vec::<String>::new()));
        let request_handler: TestRequestHandler = {
            let requests = Arc::clone(&requests);
            Arc::new(move |request| match request {
                upstream::ClientRequest::ThreadResume { params, .. } => {
                    requests
                        .lock()
                        .expect("request log lock should not be poisoned")
                        .push(format!("thread/resume:{}", params.exclude_turns));
                    assert!(!params.exclude_turns);
                    serde_json::to_value(json!({
                        "thread": {
                            "id": thread_id,
                            "preview": "hello",
                            "ephemeral": false,
                            "modelProvider": "openai",
                            "createdAt": 1,
                            "updatedAt": 2,
                            "status": { "type": "idle" },
                            "path": "/tmp/thread",
                            "cwd": "/tmp/thread",
                            "cliVersion": "1.0.0",
                            "source": "cli",
                            "agentNickname": null,
                            "agentRole": null,
                            "gitInfo": null,
                            "name": "thread",
                            "turns": [{
                                "id": "turn-1",
                                "items": [{
                                    "id": "item-1",
                                    "type": "userMessage",
                                    "content": [{
                                        "type": "text",
                                        "text": "hello",
                                        "textElements": []
                                    }]
                                }],
                                "status": "completed",
                                "error": null,
                                "startedAt": null,
                                "completedAt": 2,
                                "durationMs": 1
                            }]
                        },
                        "model": "gpt-5",
                        "modelProvider": "openai",
                        "cwd": "/tmp/thread",
                        "approvalPolicy": "never",
                        "approvalsReviewer": "user",
                        "sandbox": { "type": "dangerFullAccess" },
                        "reasoningEffort": "medium"
                    }))
                    .map_err(|error| RpcError::Deserialization(error.to_string()))
                }
                other => Err(RpcError::Deserialization(format!(
                    "unexpected request in test: {}",
                    other.method()
                ))),
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        let outcome = client
            .load_thread_turns_page(server_id, thread_id, None, Some(5))
            .await
            .expect("turn load should use embedded resume");

        assert!(outcome.loaded);
        assert!(!outcome.has_more);
        let requests = requests
            .lock()
            .expect("request log lock should not be poisoned");
        assert_eq!(requests.as_slice(), ["thread/resume:false"]);
        drop(requests);

        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let snapshot = client
            .app_store
            .snapshot()
            .threads
            .get(&key)
            .cloned()
            .expect("snapshot after embedded resume");
        assert_eq!(snapshot.items.len(), 1);
        assert!(snapshot.initial_turns_loaded);
    }

    #[test]
    fn remote_oauth_callback_port_reads_localhost_redirect() {
        let auth_url = "https://auth.openai.com/oauth/authorize?response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc";
        assert_eq!(remote_oauth_callback_port(auth_url).unwrap(), 1455);
    }

    #[test]
    fn approval_request_id_prefers_seed_type_for_local_responses() {
        let approval = PendingApproval {
            id: "42".to_string(),
            server_id: "srv".to_string(),
            kind: crate::types::ApprovalKind::Permissions,
            thread_id: Some("thread-1".to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        };
        let seed = PendingApprovalSeed {
            request_id: upstream::RequestId::Integer(42),
            raw_params: json!({}),
        };

        assert_eq!(
            server_request_id_json(approval_request_id(&approval, Some(&seed))),
            json!(42)
        );
    }

    #[test]
    fn approval_request_id_falls_back_to_string_for_non_numeric_ids() {
        let approval = PendingApproval {
            id: "req-42".to_string(),
            server_id: "srv".to_string(),
            kind: crate::types::ApprovalKind::Permissions,
            thread_id: Some("thread-1".to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        };

        assert_eq!(
            server_request_id_json(approval_request_id(&approval, None)),
            json!("req-42")
        );
    }

    #[tokio::test]
    async fn duplicate_steer_queued_follow_up_taps_drop_after_first() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);

        let mut thread = thread_snapshot_with_active_turn(server_id, thread_id, "turn-active");
        let draft = queued_follow_up_draft_from_inputs(
            &[upstream::UserInput::Text {
                text: "follow up".to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::Message,
        )
        .expect("draft");
        let preview_id = draft.preview.id.clone();
        thread.queued_follow_up_drafts.push(draft);
        client.app_store.upsert_thread_snapshot(thread);

        let steer_calls = Arc::new(StdMutex::new(Vec::<upstream::ClientRequest>::new()));
        let request_handler: TestRequestHandler = {
            let steer_calls = Arc::clone(&steer_calls);
            Arc::new(move |request| {
                let request_for_log = request.clone();
                steer_calls
                    .lock()
                    .expect("steer calls lock should not be poisoned")
                    .push(request_for_log);
                match request {
                    upstream::ClientRequest::TurnSteer { .. } => {
                        Ok(json!({ "turnId": "turn-next" }))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));

        // First tap: succeeds and sends one TurnSteer.
        client
            .steer_queued_follow_up(&key, &preview_id)
            .await
            .expect("first steer should succeed");

        // Second tap (e.g. user double-tapped Steer before the UI re-rendered).
        // Should be dropped without firing another TurnSteer.
        client
            .steer_queued_follow_up(&key, &preview_id)
            .await
            .expect("duplicate steer should noop");

        // Third tap, just to be thorough.
        client
            .steer_queued_follow_up(&key, &preview_id)
            .await
            .expect("third steer should noop");

        let captured = steer_calls
            .lock()
            .expect("steer calls lock should not be poisoned");
        assert_eq!(
            captured.len(),
            1,
            "duplicate steer taps should not fan out to multiple TurnSteer calls"
        );
    }

    #[test]
    fn queued_follow_up_message_json_round_trips_skill_inputs() {
        let inputs = vec![
            upstream::UserInput::Text {
                text: "Use the repo skill here.".to_string(),
                text_elements: Vec::new(),
            },
            upstream::UserInput::Skill {
                name: "repo-helper".to_string(),
                path: PathBuf::from("/tmp/repo-helper/SKILL.md"),
            },
        ];

        let message_json = queued_follow_up_message_json_from_inputs(&inputs)
            .expect("queued message json should serialize");
        let round_trip_inputs = queued_follow_up_inputs_from_json_value(&message_json);

        assert_eq!(round_trip_inputs, inputs);
    }

    #[test]
    fn queued_follow_up_preview_from_inputs_can_mark_pending_steers() {
        let preview = queued_follow_up_preview_from_inputs(
            &[upstream::UserInput::Text {
                text: "Please try the same search again.".to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::PendingSteer,
        )
        .expect("preview should be generated");

        assert_eq!(preview.kind, AppQueuedFollowUpKind::PendingSteer);
        assert_eq!(preview.text, "Please try the same search again.");
    }
}
