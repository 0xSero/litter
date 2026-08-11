//! UniFFI-exported state surface for the canonical Rust app store.

use crate::MobileClient;
use crate::conversation_uniffi::{HydratedConversationItem, HydratedConversationItemContent};
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::store::{AppSnapshotRecord, AppStoreUpdateRecord, AppThreadSnapshot};
use crate::types::{AppForkThreadFromMessageRequest, AppModeKind, AppStartTurnRequest, ThreadKey};
use std::collections::VecDeque;
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct AppStore {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object)]
pub struct AppStoreSubscription {
    pub(crate) state: std::sync::Mutex<Option<AppStoreSubscriptionState>>,
}

pub(crate) struct AppStoreSubscriptionState {
    pub(crate) rx: tokio::sync::broadcast::Receiver<AppStoreUpdateRecord>,
    pub(crate) buffered: VecDeque<AppStoreUpdateRecord>,
    /// Display-cadence pacing for sustained streaming. `None` means the next
    /// streaming delta is first-after-idle and must be delivered immediately;
    /// `Some` carries the active `(thread key, item id)` and the absolute
    /// deadline until which contiguous deltas for that same identity are
    /// coalesced. A different identity or a non-streaming update clears it.
    pub(crate) pacing: Option<AppStorePacing>,
    /// Set when a `RecvError::Lagged` was observed while an accumulated
    /// streaming update exists. The accumulated text is surfaced first; the
    /// next receive consumes this flag, clears pacing, and returns
    /// `FullResync` so the platform resyncs rather than silently skipping
    /// the lagged messages.
    pub(crate) pending_full_resync: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AppStorePacing {
    pub(crate) key: crate::types::ThreadKey,
    pub(crate) item_id: String,
    pub(crate) next_flush_at: tokio::time::Instant,
}

const MAX_COALESCED_STREAMING_TEXT_BYTES: usize = 8 * 1024;
/// Bound native/FFI streaming publishes to the display cadence. Without a
/// short collection window a fast producer and Swift/Kotlin consumer run in
/// lockstep, so `try_recv` sees only one tiny delta and every token copies the
/// platform snapshot. Sixteen milliseconds keeps first-token latency within a
/// single frame while capping that cross-boundary churn near 60 Hz.
const STREAMING_COALESCE_WINDOW: std::time::Duration = std::time::Duration::from_millis(16);

#[cfg(test)]
mod tests {
    use super::should_preserve_thread_item_update_boundary;
    use super::{AppStorePacing, AppStoreSubscription, AppStoreSubscriptionState, STREAMING_COALESCE_WINDOW};
    use crate::conversation_uniffi::{
        HydratedAssistantMessageData, HydratedConversationItem, HydratedConversationItemContent,
        HydratedFileChangeData, HydratedFileChangeEntryData, HydratedMcpToolCallData,
        HydratedMultiAgentActionData, HydratedMultiAgentStateData,
    };
    use crate::store::{AppStoreReducer, AppStoreUpdateRecord, ThreadStreamingDeltaKind};
    use crate::types::{AppOperationStatus, AppSubagentStatus, ThreadKey};
    use codex_app_server_protocol as upstream;
    use serde_json::json;
    use std::collections::{HashMap, VecDeque};
    use std::sync::Arc;

    fn first_text(update: &AppStoreUpdateRecord) -> String {
        match update {
            AppStoreUpdateRecord::ThreadStreamingDelta { text, .. } => text.clone(),
            other => panic!("expected streaming delta, got {other:?}"),
        }
    }

    #[test]
    fn thread_item_parses_mcp_arguments_json() {
        let item = upstream::ThreadItem::McpToolCall {
            id: "mcp-1".into(),
            server: "filesystem".into(),
            tool: "read_file".into(),
            status: upstream::McpToolCallStatus::Completed,
            arguments: serde_json::from_value(json!({"path": "/tmp/file.txt"}))
                .expect("json value should convert"),
            mcp_app_resource_uri: None,
            result: None,
            error: None,
            duration_ms: Some(42),
        };

        let upstream::ThreadItem::McpToolCall { arguments, .. } = item else {
            panic!("expected mcp tool call");
        };
        assert_eq!(
            arguments.get("path").and_then(|value| value.as_str()),
            Some("/tmp/file.txt")
        );
    }

    #[test]
    fn thread_item_parses_collab_agent_states_json() {
        let item = upstream::ThreadItem::CollabAgentToolCall {
            id: "collab-1".into(),
            tool: upstream::CollabAgentTool::SpawnAgent,
            status: upstream::CollabAgentToolCallStatus::Completed,
            sender_thread_id: "parent-thread".into(),
            receiver_thread_ids: vec!["sub-thread-1".into()],
            prompt: Some("Review the changes".into()),
            model: None,
            reasoning_effort: None,
            agents_states: HashMap::from([(
                "sub-thread-1".into(),
                upstream::CollabAgentState {
                    status: upstream::CollabAgentStatus::Running,
                    message: Some("Working".into()),
                },
            )]),
        };

        let upstream::ThreadItem::CollabAgentToolCall { agents_states, .. } = item else {
            panic!("expected collab agent tool call");
        };
        let state = agents_states
            .get("sub-thread-1")
            .expect("collab state should be present");
        assert_eq!(state.status, upstream::CollabAgentStatus::Running);
        assert_eq!(state.message.as_deref(), Some("Working"));
    }

    #[test]
    fn app_store_subscription_returns_full_resync_when_updates_lag() {
        let reducer = AppStoreReducer::new();
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
                pacing: None,
                pending_full_resync: false,
            })),
        };

        // AppStoreReducer keeps a 1024-event broadcast buffer to absorb normal
        // streaming bursts. Exceed it decisively so this test still exercises
        // the lagged subscriber fallback to FullResync.
        for _ in 0..2048 {
            reducer.set_active_thread(Some(ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            }));
        }

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let update = runtime
            .block_on(subscription.next_update())
            .expect("next update should succeed");
        assert!(matches!(update, AppStoreUpdateRecord::FullResync));
    }

    #[test]
    fn app_store_subscription_coalesces_contiguous_streaming_deltas() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
                pacing: None,
                pending_full_resync: false,
            })),
        };

        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "hel",
        );
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "lo",
        );
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            " world",
        );

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let update = runtime
            .block_on(subscription.next_update())
            .expect("next update should succeed");

        assert!(matches!(
            update,
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key: emitted_key,
                item_id,
                kind: crate::store::ThreadStreamingDeltaKind::AssistantText,
                text,
            } if emitted_key == key && item_id == "assistant-1" && text == "hello world"
        ));
    }

    #[tokio::test]
    async fn app_store_subscription_batches_interleaved_streaming_at_display_cadence() {
        let reducer = Arc::new(AppStoreReducer::new());
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
                pacing: None,
                pending_full_resync: false,
            })),
        };

        const DELTA_COUNT: usize = 48;
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "x",
        );
        let producer = {
            let reducer = Arc::clone(&reducer);
            let key = key.clone();
            tokio::spawn(async move {
                for _ in 1..DELTA_COUNT {
                    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
                    reducer.emit_thread_streaming_delta(
                        &key,
                        "assistant-1",
                        ThreadStreamingDeltaKind::AssistantText,
                        "x",
                    );
                }
            })
        };

        let mut delivered_text = String::new();
        let mut update_count = 0usize;
        while delivered_text.len() < DELTA_COUNT {
            let update = subscription
                .next_update()
                .await
                .expect("streaming update");
            let AppStoreUpdateRecord::ThreadStreamingDelta { text, .. } = update else {
                panic!("expected streaming delta");
            };
            delivered_text.push_str(&text);
            update_count += 1;
        }
        producer.await.expect("producer");

        eprintln!(
            "batched {DELTA_COUNT} streaming deltas into {update_count} native updates"
        );
        assert_eq!(delivered_text, "x".repeat(DELTA_COUNT));
        // With the first-delta-immediate state machine, the first delta flushes
        // at t=0 (instead of t=16ms under the old unconditional wait), and a
        // consumer that falls behind the absolute deadline flushes immediately
        // rather than accumulating further lag. The deterministic proof of
        // display-cadence pacing lives in the pacing helper tests above; this
        // timed test remains integration coverage proving meaningful batching
        // (48 deltas into far fewer native updates) with exact text/order.
        assert!(
            update_count <= 24,
            "expected display-cadence batching (>=2:1), got {update_count} native updates"
        );
    }

    #[test]
    fn pacing_flushes_first_after_idle_immediately_and_arms_deadline() {
        use super::should_flush_streaming_now;
        use crate::store::ThreadStreamingDeltaKind;
        use crate::types::ThreadKey;

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let delta = |text: &str| AppStoreUpdateRecord::ThreadStreamingDelta {
            key: key.clone(),
            item_id: "assistant-1".to_string(),
            kind: ThreadStreamingDeltaKind::AssistantText,
            text: text.to_string(),
        };

        let t0 = tokio::time::Instant::now();
        let mut pacing: Option<AppStorePacing> = None;

        // First delta after idle: flush immediately, arm a 16ms deadline.
        assert!(should_flush_streaming_now(
            &mut pacing,
            &delta("a"),
            t0
        ));
        let armed = pacing.as_ref().expect("deadline armed");
        assert_eq!(armed.key, key);
        assert_eq!(armed.item_id, "assistant-1");
        assert_eq!(armed.next_flush_at, t0 + STREAMING_COALESCE_WINDOW);

        // Same identity inside the window: do not flush (coalesce).
        assert!(!should_flush_streaming_now(
            &mut pacing,
            &delta("b"),
            t0 + std::time::Duration::from_millis(4)
        ));
        // Deadline unchanged by the query.
        assert_eq!(
            pacing.as_ref().unwrap().next_flush_at,
            t0 + STREAMING_COALESCE_WINDOW
        );

        // At a passed deadline (5ms after the armed deadline): flush and
        // rearm the next deadline from the flush time so an
        // immediately-following same-identity delta coalesces instead of
        // flushing again.
        let old_deadline = pacing.as_ref().unwrap().next_flush_at;
        let flush_time = old_deadline + std::time::Duration::from_millis(5);
        assert!(should_flush_streaming_now(
            &mut pacing,
            &delta("c"),
            flush_time
        ));
        let rearmed = pacing.as_ref().unwrap().next_flush_at;
        assert_eq!(
            rearmed,
            flush_time + STREAMING_COALESCE_WINDOW,
            "passed-deadline flush must rearm from the flush time"
        );

        // Same identity 2ms after the rearm: must coalesce (return false).
        assert!(!should_flush_streaming_now(
            &mut pacing,
            &delta("d"),
            flush_time + std::time::Duration::from_millis(2)
        ));
        // Deadline unchanged by the coalesce query.
        assert_eq!(pacing.as_ref().unwrap().next_flush_at, rearmed);
        // The rearmed deadline is the flush time plus one window, which is
        // strictly greater than the old deadline plus one window because the
        // flush happened after the old deadline.
        assert_ne!(rearmed, old_deadline + STREAMING_COALESCE_WINDOW);
    }

    #[test]
    fn pacing_restarts_for_new_identity_and_clears_on_non_streaming() {
        use super::should_flush_streaming_now;
        use crate::store::ThreadStreamingDeltaKind;
        use crate::types::ThreadKey;

        let key_a = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-a".to_string(),
        };
        let key_b = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-b".to_string(),
        };
        let delta = |key: ThreadKey, text: &str| AppStoreUpdateRecord::ThreadStreamingDelta {
            key,
            item_id: "assistant-1".to_string(),
            kind: ThreadStreamingDeltaKind::AssistantText,
            text: text.to_string(),
        };

        let t0 = tokio::time::Instant::now();
        let mut pacing: Option<AppStorePacing> = None;

        // Arm deadline for identity A.
        assert!(should_flush_streaming_now(&mut pacing, &delta(key_a.clone(), "a"), t0));
        let a_deadline = pacing.as_ref().unwrap().next_flush_at;

        // A different identity inside A's window is a new burst: flush and
        // rearm for B.
        assert!(should_flush_streaming_now(
            &mut pacing,
            &delta(key_b.clone(), "b"),
            t0 + std::time::Duration::from_millis(2)
        ));
        assert_eq!(pacing.as_ref().unwrap().key, key_b);
        assert_ne!(pacing.as_ref().unwrap().next_flush_at, a_deadline);

        // A non-streaming update clears pacing and flushes immediately.
        let non_streaming = AppStoreUpdateRecord::FullResync;
        assert!(should_flush_streaming_now(&mut pacing, &non_streaming, t0));
        assert!(pacing.is_none());

        // After clearing, the next streaming delta is first-after-idle again.
        assert!(should_flush_streaming_now(&mut pacing, &delta(key_b, "c"), t0));
    }

    #[test]
    fn advance_pacing_deadline_never_anchors_in_the_past() {
        use super::advance_pacing_deadline;
        use crate::types::ThreadKey;

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let t0 = tokio::time::Instant::now();
        let mut pacing = Some(AppStorePacing {
            key,
            item_id: "assistant-1".to_string(),
            next_flush_at: t0,
        });

        // Deadline already in the past: re-anchor from `now`.
        let now = t0 + std::time::Duration::from_millis(40);
        advance_pacing_deadline(&mut pacing, now);
        assert_eq!(pacing.as_ref().unwrap().next_flush_at, now + STREAMING_COALESCE_WINDOW);

        // Deadline still in the future: advance from the existing deadline.
        let future_base = now + std::time::Duration::from_millis(50);
        pacing.as_mut().unwrap().next_flush_at = future_base;
        advance_pacing_deadline(&mut pacing, now);
        assert_eq!(pacing.as_ref().unwrap().next_flush_at, future_base + STREAMING_COALESCE_WINDOW);
    }

    #[tokio::test]
    async fn app_store_subscription_delivers_isolated_first_delta_without_cadence_wait() {
        // A single isolated streaming delta must be delivered immediately:
        // the first-after-idle path flushes without waiting for a second
        // receive. The deterministic proof that the first delta bypasses the
        // cadence wait lives in the pacing helper tests above; this test
        // covers the end-to-end content/path (exact text, immediate return
        // without a second delta arriving) without a scheduler-sensitive
        // wall-clock assertion.
        let reducer = Arc::new(AppStoreReducer::new());
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
                pacing: None,
                pending_full_resync: false,
            })),
        };

        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "first",
        );

        let update = subscription.next_update().await.expect("first delta");

        let AppStoreUpdateRecord::ThreadStreamingDelta { text, .. } = update else {
            panic!("expected streaming delta, got {update:?}");
        };
        assert_eq!(text, "first");
    }

    #[tokio::test]
    async fn app_store_subscription_returns_accumulated_delta_on_close_instead_of_discarding() {
        // While coalescing a sustained burst, a closed receiver must surface
        // the already-accumulated delta rather than discarding it.
        let reducer = Arc::new(AppStoreReducer::new());
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
                pacing: None,
                pending_full_resync: false,
            })),
        };

        // First delta flushes immediately and arms the cadence deadline.
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "a",
        );
        let first = subscription.next_update().await.expect("first delta");
        assert_eq!(
            first_text(&first),
            "a",
            "first delta should flush immediately"
        );

        // Emit two more deltas for the same identity, then drop the reducer so
        // the broadcast channel closes. The sustained-burst path should still
        // deliver the accumulated text rather than discarding it on close.
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "b",
        );
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "c",
        );
        drop(reducer);

        let update = subscription.next_update().await.expect("accumulated delta on close");
        // The accumulated burst must contain both b and c (exact text/order).
        let text = first_text(&update);
        assert!(
            text.contains('b') && text.contains('c'),
            "expected accumulated b+c text on close, got {text:?}"
        );
    }

    #[tokio::test]
    async fn app_store_subscription_surfaces_accumulated_text_then_full_resync_after_lag() {
        // While coalescing a sustained burst, a lagged broadcast receiver
        // must surface the already-accumulated delta first, then return
        // FullResync on the next receive so the platform resyncs rather than
        // silently skipping the lagged messages. Deterministic: no sleeps,
        // no producer, no reducer — the lag is forced by sending into a
        // capacity-2 channel an untouched receiver never drained.
        use crate::store::ThreadStreamingDeltaKind;
        use crate::types::ThreadKey;
        use std::collections::VecDeque;
        use tokio::sync::broadcast;

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };

        let (tx, rx) = broadcast::channel::<AppStoreUpdateRecord>(2);
        // Capacity is 2 and the receiver is never drained: sending three
        // FullResync values forces the receiver into a lagged state on the
        // third send.
        tx.send(AppStoreUpdateRecord::FullResync).unwrap();
        tx.send(AppStoreUpdateRecord::FullResync).unwrap();
        tx.send(AppStoreUpdateRecord::FullResync).unwrap();

        let mut state = AppStoreSubscriptionState {
            rx,
            buffered: VecDeque::new(),
            pacing: Some(AppStorePacing {
                key: key.clone(),
                item_id: "assistant-1".to_string(),
                next_flush_at: tokio::time::Instant::now()
                    + std::time::Duration::from_secs(60),
            }),
            pending_full_resync: false,
        };

        let current = AppStoreUpdateRecord::ThreadStreamingDelta {
            key: key.clone(),
            item_id: "assistant-1".to_string(),
            kind: ThreadStreamingDeltaKind::AssistantText,
            text: "current".to_string(),
        };

        // Pass the current item directly into the coalescer. The receiver is
        // already lagged, so the sustained-burst path hits the lag branch:
        // it must return the current exact text and set the deferred resync.
        let returned = super::coalesce_streaming_window(&mut state, current)
            .await
            .expect("coalesce on lag returns accumulated text");
        let returned_text = first_text(&returned);
        assert_eq!(
            returned_text, "current",
            "lag must surface the accumulated exact text first"
        );
        assert!(
            state.pending_full_resync,
            "lag while accumulating must defer a FullResync"
        );

        // The next receive consumes the deferred resync, clears pacing, and
        // returns FullResync.
        let next = super::receive_next_update(&mut state)
            .await
            .expect("deferred full resync");
        assert!(
            matches!(next, AppStoreUpdateRecord::FullResync),
            "expected deferred FullResync after lag, got {next:?}"
        );
        assert!(!state.pending_full_resync, "pending flag must clear after delivery");
        assert!(state.pacing.is_none(), "pacing must clear after deferred resync");

        // Keep the sender alive through the assertions so close is not the
        // observed terminal state during the lag path.
        drop(tx);
    }

    #[test]
    fn app_store_subscription_coalesces_refresh_only_updates_into_full_resync() {
        let reducer = AppStoreReducer::new();
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
                pacing: None,
                pending_full_resync: false,
            })),
        };

        reducer.update_server_health("srv", crate::store::ServerHealthSnapshot::Connected);
        reducer.replace_pending_approvals(Vec::new());
        reducer.set_voice_handoff_thread(None);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let update = runtime
            .block_on(subscription.next_update())
            .expect("next update should succeed");

        assert!(matches!(update, AppStoreUpdateRecord::FullResync));
    }

    #[test]
    fn app_store_subscription_preserves_tool_lifecycle_boundaries() {
        let current = hydrated_item(
            "tool-1",
            HydratedConversationItemContent::McpToolCall(mcp_tool_call(
                AppOperationStatus::InProgress,
                Vec::new(),
            )),
        );
        let next = hydrated_item(
            "tool-1",
            HydratedConversationItemContent::McpToolCall(mcp_tool_call(
                AppOperationStatus::Completed,
                Vec::new(),
            )),
        );

        assert!(should_preserve_thread_item_update_boundary(&current, &next));
    }

    #[test]
    fn app_store_subscription_preserves_tool_progress_boundaries() {
        let current = hydrated_item(
            "tool-1",
            HydratedConversationItemContent::McpToolCall(mcp_tool_call(
                AppOperationStatus::InProgress,
                vec!["connecting".to_string()],
            )),
        );
        let next = hydrated_item(
            "tool-1",
            HydratedConversationItemContent::McpToolCall(mcp_tool_call(
                AppOperationStatus::InProgress,
                vec!["connecting".to_string(), "reading".to_string()],
            )),
        );

        assert!(should_preserve_thread_item_update_boundary(&current, &next));
    }

    #[test]
    fn app_store_subscription_preserves_file_and_agent_progress_boundaries() {
        let current_file = hydrated_item(
            "file-1",
            HydratedConversationItemContent::FileChange(HydratedFileChangeData {
                status: AppOperationStatus::InProgress,
                changes: Vec::new(),
            }),
        );
        let next_file = hydrated_item(
            "file-1",
            HydratedConversationItemContent::FileChange(HydratedFileChangeData {
                status: AppOperationStatus::InProgress,
                changes: vec![HydratedFileChangeEntryData {
                    path: "src/lib.rs".to_string(),
                    kind: "update".to_string(),
                    diff: "@@ -1 +1\n-old\n+new\n".to_string(),
                    additions: 1,
                    deletions: 1,
                }],
            }),
        );
        assert!(should_preserve_thread_item_update_boundary(
            &current_file,
            &next_file
        ));

        let current_agent = hydrated_item(
            "agent-1",
            HydratedConversationItemContent::MultiAgentAction(multi_agent_action(None)),
        );
        let next_agent = hydrated_item(
            "agent-1",
            HydratedConversationItemContent::MultiAgentAction(multi_agent_action(Some(
                "Scanning files".to_string(),
            ))),
        );

        assert!(should_preserve_thread_item_update_boundary(
            &current_agent,
            &next_agent
        ));
    }

    #[test]
    fn app_store_subscription_keeps_non_tool_item_updates_coalescible() {
        let current = hydrated_item(
            "assistant-1",
            HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: "hel".to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
        );
        let next = hydrated_item(
            "assistant-1",
            HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: "hello".to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
        );

        assert!(!should_preserve_thread_item_update_boundary(
            &current, &next
        ));
    }

    fn hydrated_item(
        id: &str,
        content: HydratedConversationItemContent,
    ) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.to_string(),
            content,
            source_turn_id: Some("turn-1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn mcp_tool_call(
        status: AppOperationStatus,
        progress_messages: Vec<String>,
    ) -> HydratedMcpToolCallData {
        HydratedMcpToolCallData {
            server: "filesystem".to_string(),
            tool: "read_file".to_string(),
            status,
            duration_ms: None,
            arguments_json: None,
            content_summary: None,
            structured_content_json: None,
            raw_output_json: None,
            error_message: None,
            progress_messages,
            computer_use: None,
        }
    }

    fn multi_agent_action(message: Option<String>) -> HydratedMultiAgentActionData {
        HydratedMultiAgentActionData {
            tool: "spawn_agent".to_string(),
            status: AppOperationStatus::InProgress,
            prompt: Some("Inspect realtime updates".to_string()),
            targets: vec!["agent-1".to_string()],
            receiver_thread_ids: vec!["thread-child".to_string()],
            agent_states: vec![HydratedMultiAgentStateData {
                target_id: "agent-1".to_string(),
                status: AppSubagentStatus::Running,
                message,
            }],
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl AppStore {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    pub async fn snapshot(&self) -> Result<AppSnapshotRecord, ClientError> {
        AppSnapshotRecord::try_from(self.inner.app_snapshot()).map_err(ClientError::Serialization)
    }

    pub async fn thread_snapshot(
        &self,
        key: ThreadKey,
    ) -> Result<Option<AppThreadSnapshot>, ClientError> {
        crate::store::project_thread_snapshot(&self.inner.app_snapshot(), &key)
            .map_err(ClientError::Serialization)
    }

    pub async fn start_turn(
        &self,
        key: ThreadKey,
        params: AppStartTurnRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params = params.try_into().map_err(|error: crate::RpcClientError| {
                ClientError::Serialization(error.to_string())
            })?;
            c.start_turn(&key.server_id, params)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn set_thread_collaboration_mode(
        &self,
        key: ThreadKey,
        mode: AppModeKind,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.set_thread_collaboration_mode(&key, mode)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub fn dismiss_plan_implementation_prompt(&self, key: ThreadKey) {
        self.inner.dismiss_plan_implementation_prompt(&key);
    }

    pub async fn implement_plan(&self, key: ThreadKey) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.implement_plan(&key)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn steer_queued_follow_up(
        &self,
        key: ThreadKey,
        preview_id: String,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.steer_queued_follow_up(&key, &preview_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn delete_queued_follow_up(
        &self,
        key: ThreadKey,
        preview_id: String,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.delete_queued_follow_up(&key, &preview_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn external_resume_thread(
        &self,
        key: ThreadKey,
        host_id: Option<String>,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.external_resume_thread(&key.server_id, &key.thread_id, host_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    /// Force a fresh `thread/resume` (with `exclude_turns: false`) so the
    /// store can reconcile a stale `active_turn_id` against the server's
    /// authoritative turn list. Use after a long resume / push wake when
    /// the in-flight turn we believe is still running may have completed
    /// during the background window.
    pub async fn force_refresh_thread_authoritative(
        &self,
        key: ThreadKey,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.force_refresh_thread_authoritative(&key.server_id, &key.thread_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn load_thread_turns_page(
        &self,
        key: ThreadKey,
        cursor: Option<String>,
        limit: Option<u32>,
    ) -> Result<crate::types::AppLoadThreadTurnsOutcome, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.load_thread_turns_page(&key.server_id, &key.thread_id, cursor, limit)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn unsubscribe_thread(&self, key: ThreadKey) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.thread_unsubscribe(&key.server_id, &key.thread_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub fn subscribe_updates(&self) -> AppStoreSubscription {
        AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: self.inner.subscribe_app_updates(),
                buffered: VecDeque::new(),
                pacing: None,
                pending_full_resync: false,
            })),
        }
    }

    pub async fn edit_message(
        &self,
        key: ThreadKey,
        selected_turn_index: u32,
    ) -> Result<String, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.edit_message(&key, selected_turn_index)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn fork_thread_from_message(
        &self,
        key: ThreadKey,
        selected_turn_index: u32,
        params: AppForkThreadFromMessageRequest,
    ) -> Result<ThreadKey, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.fork_thread_from_message(
                &key,
                selected_turn_index,
                params.cwd,
                params.model,
                params.approval_policy,
                params.sandbox,
                params.developer_instructions,
                params.persist_extended_history,
            )
            .await
            .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn respond_to_approval(
        &self,
        request_id: String,
        decision: crate::types::ApprovalDecisionValue,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.respond_to_approval(&request_id, decision)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn respond_to_user_input(
        &self,
        request_id: String,
        answers: Vec<crate::types::PendingUserInputAnswer>,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.respond_to_user_input(&request_id, answers)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.inner.set_active_thread(key);
    }

    pub fn rename_server(&self, server_id: String, display_name: String) {
        self.inner.app_store.rename_server(&server_id, display_name);
    }

    pub fn set_voice_handoff_thread(&self, key: Option<ThreadKey>) {
        self.inner.set_voice_handoff_thread(key);
    }

    // -- Recording / Replay --

    pub fn start_recording(&self) {
        self.inner.recorder.start_recording();
    }

    pub fn stop_recording(&self) -> String {
        self.inner.recorder.stop_recording()
    }

    pub fn is_recording(&self) -> bool {
        self.inner.recorder.is_recording()
    }

    pub async fn start_replay(
        &self,
        data: String,
        target_key: ThreadKey,
    ) -> Result<(), ClientError> {
        let entries = crate::recorder::MessageRecorder::replay_entries(
            &data,
            &target_key.server_id,
            &target_key.thread_id,
        )
        .map_err(ClientError::Serialization)?;
        let processor = Arc::clone(&self.inner.event_processor);
        for (i, (ts_ms, server_id, notification)) in entries.iter().enumerate() {
            if i > 0 {
                let prev_ts = entries[i - 1].0;
                let delta = ts_ms.saturating_sub(prev_ts);
                if delta > 0 {
                    tokio::time::sleep(tokio::time::Duration::from_millis(delta)).await;
                }
            }
            processor.process_notification(server_id, "codex".to_string(), notification);
        }
        Ok(())
    }

    /// Open a new terminal session whose strong handle lives on the
    /// shared `MobileClient`. The reducer-side
    /// `AppSnapshot.terminal_sessions` entry mirrors lifecycle and holds
    /// the 64 KiB output tail for re-attach repaint.
    pub async fn open_terminal_session(
        &self,
        kind: crate::terminal::TerminalBackendKind,
        size: crate::terminal::TerminalSize,
    ) -> Result<String, ClientError> {
        self.inner
            .open_terminal_session(kind, size, None)
            .await
            .map_err(|e| ClientError::Rpc(e.to_string()))
    }

    /// Same as [`Self::open_terminal_session`] but consults `trust_store`
    /// for the SSH backend host-key pin policy. Local backends ignore the
    /// trust store.
    pub async fn open_terminal_session_with_trust_store(
        &self,
        kind: crate::terminal::TerminalBackendKind,
        size: crate::terminal::TerminalSize,
        trust_store: Arc<crate::terminal::TerminalSshTrustStore>,
    ) -> Result<String, ClientError> {
        self.inner
            .open_terminal_session(kind, size, Some(trust_store))
            .await
            .map_err(|e| ClientError::Rpc(e.to_string()))
    }

    /// Close a terminal session by id. Drops the live handle (the
    /// underlying backend closes when the last reference is released)
    /// and marks the snapshot exited. The snapshot is kept (so the UI
    /// can render the exit code); call `forget_terminal_session` to
    /// fully remove the record.
    pub async fn close_terminal_session(&self, id: String) -> Result<(), ClientError> {
        self.inner
            .close_terminal_session(&id)
            .await
            .map_err(|e| ClientError::Rpc(e.to_string()))
    }

    /// Remove the snapshot entry for `id`, releasing the output_tail.
    pub fn forget_terminal_session(&self, id: String) {
        self.inner.forget_terminal_session(&id);
    }

    /// Return the live session handle for `id`, or `None` if the session
    /// has been closed.
    pub fn terminal_session_handle(
        &self,
        id: String,
    ) -> Option<Arc<crate::terminal::TerminalSession>> {
        self.inner.terminal_session_handle(&id)
    }

    /// Return the snapshot entry (including output_tail) for `id`.
    pub fn terminal_session_snapshot(
        &self,
        id: String,
    ) -> Option<crate::store::TerminalSessionSnapshot> {
        self.inner.app_store.terminal_session_snapshot(&id)
    }

    /// Write `bytes` to the currently-active terminal session, if any.
    /// Returns `Ok(false)` if no active session is set.
    pub async fn write_to_active_terminal(&self, bytes: Vec<u8>) -> Result<bool, ClientError> {
        self.inner
            .write_to_active_terminal(bytes)
            .await
            .map_err(|e| ClientError::Rpc(e.to_string()))
    }

    /// Return the currently-focused terminal session id, if any.
    pub fn active_terminal_id(&self) -> Option<String> {
        self.inner.app_store.snapshot().active_terminal_id
    }

    /// Set the focused terminal session id. Pass `None` to clear focus.
    pub fn set_active_terminal_id(&self, id: Option<String>) {
        self.inner.app_store.set_active_terminal_id(id);
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl AppStoreSubscription {
    pub async fn next_update(&self) -> Result<AppStoreUpdateRecord, ClientError> {
        let mut state = {
            self.state
                .lock()
                .unwrap()
                .take()
                .ok_or(ClientError::EventClosed(
                    "no app-store subscriber".to_string(),
                ))?
        };
        let result = match receive_next_update(&mut state).await {
            Ok(update) => Ok(update),
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                Ok(AppStoreUpdateRecord::FullResync)
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                Err(ClientError::EventClosed("closed".to_string()))
            }
        };
        *self.state.lock().unwrap() = Some(state);
        result
    }
}

async fn receive_next_update(
    state: &mut AppStoreSubscriptionState,
) -> Result<AppStoreUpdateRecord, tokio::sync::broadcast::error::RecvError> {
    // If a previous receive surfaced accumulated text after a lag, deliver
    // the deferred FullResync now so the platform resyncs rather than
    // silently skipping the lagged messages. Clear pacing: a resync
    // invalidates the active streaming identity.
    if state.pending_full_resync {
        state.pending_full_resync = false;
        state.pacing = None;
        return Ok(AppStoreUpdateRecord::FullResync);
    }

    let first = if let Some(update) = state.buffered.pop_front() {
        update
    } else {
        state.rx.recv().await?
    };

    let first = coalesce_streaming_window(state, first).await?;
    coalesce_ready_updates(state, first)
}

/// Decide whether a streaming `update` should be delivered immediately or
/// coalesced against the active pacing deadline. Returns `true` when the
/// update is first-after-idle / new burst / past deadline and must flush now,
/// arming (or rearming) the pacing deadline for its identity. Returns `false`
/// when the update is a sustained delta for the active identity inside its
/// cadence window and should be accumulated.
fn should_flush_streaming_now(
    pacing: &mut Option<AppStorePacing>,
    update: &AppStoreUpdateRecord,
    now: tokio::time::Instant,
) -> bool {
    let AppStoreUpdateRecord::ThreadStreamingDelta { key, item_id, .. } = update else {
        // Non-streaming updates always clear pacing and flush immediately.
        *pacing = None;
        return true;
    };
    match pacing {
        Some(active) if active.key == *key && active.item_id == *item_id => {
            // Same identity. Flush only once the absolute deadline has elapsed,
            // and rearm the next deadline so an immediately-following delta
            // coalesces instead of flushing again.
            if now >= active.next_flush_at {
                active.next_flush_at = now + STREAMING_COALESCE_WINDOW;
                true
            } else {
                false
            }
        }
        _ => {
            // Different identity, or no pacing state: first-after-idle / new
            // burst. Deliver immediately and arm the next deadline.
            *pacing = Some(AppStorePacing {
                key: key.clone(),
                item_id: item_id.clone(),
                next_flush_at: now + STREAMING_COALESCE_WINDOW,
            });
            true
        }
    }
}

/// Advance the pacing deadline after flushing a sustained burst for the active
/// identity. If the previous deadline is already in the past, re-anchor from
/// `now` so the next window is a full cadence rather than an immediate
/// re-flush.
fn advance_pacing_deadline(pacing: &mut Option<AppStorePacing>, now: tokio::time::Instant) {
    if let Some(active) = pacing {
        let base = if active.next_flush_at > now {
            active.next_flush_at
        } else {
            now
        };
        active.next_flush_at = base + STREAMING_COALESCE_WINDOW;
    }
}

async fn coalesce_streaming_window(
    state: &mut AppStoreSubscriptionState,
    mut update: AppStoreUpdateRecord,
) -> Result<AppStoreUpdateRecord, tokio::sync::broadcast::error::RecvError> {
    let now = tokio::time::Instant::now();
    if should_flush_streaming_now(&mut state.pacing, &update, now) {
        // First-after-idle / new burst / past-deadline: deliver immediately.
        // The deadline was armed by `should_flush_streaming_now`. If this is a
        // non-streaming update, pacing is already cleared and there is nothing
        // more to do.
        return Ok(update);
    }

    // Sustained delta for the active identity inside its cadence window.
    // Coalesce until the existing absolute deadline, then deliver.
    let deadline = state
        .pacing
        .as_ref()
        .map(|p| p.next_flush_at)
        .unwrap_or(now);
    loop {
        let next = if let Some(update) = state.buffered.pop_front() {
            update
        } else {
            match tokio::time::timeout_at(deadline, state.rx.recv()).await {
                Ok(Ok(update)) => update,
                // Close after a current accumulated update exists: do not
                // discard it. Surface the accumulated update; the following
                // receive can report closed normally.
                Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => {
                    advance_pacing_deadline(&mut state.pacing, tokio::time::Instant::now());
                    return Ok(update);
                }
                // Lag after a current accumulated update exists: surface the
                // accumulated text now, then defer a FullResync to the next
                // receive so the platform resyncs rather than silently
                // skipping the lagged messages.
                Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => {
                    state.pending_full_resync = true;
                    advance_pacing_deadline(&mut state.pacing, tokio::time::Instant::now());
                    return Ok(update);
                }
                Err(_) => {
                    advance_pacing_deadline(&mut state.pacing, tokio::time::Instant::now());
                    return Ok(update);
                }
            }
        };

        if let Err(next) = merge_app_update(&mut update, next) {
            state.buffered.push_front(*next);
            advance_pacing_deadline(&mut state.pacing, tokio::time::Instant::now());
            return Ok(update);
        }
    }
}

fn coalesce_ready_updates(
    state: &mut AppStoreSubscriptionState,
    mut update: AppStoreUpdateRecord,
) -> Result<AppStoreUpdateRecord, tokio::sync::broadcast::error::RecvError> {
    loop {
        let next = if let Some(update) = state.buffered.pop_front() {
            Some(update)
        } else {
            match state.rx.try_recv() {
                Ok(update) => Some(update),
                Err(tokio::sync::broadcast::error::TryRecvError::Empty) => None,
                Err(tokio::sync::broadcast::error::TryRecvError::Lagged(skipped)) => {
                    return Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped));
                }
                Err(tokio::sync::broadcast::error::TryRecvError::Closed) => None,
            }
        };

        let Some(next) = next else {
            return Ok(update);
        };

        if let Err(next) = merge_app_update(&mut update, next) {
            state.buffered.push_front(*next);
            return Ok(update);
        }
    }
}

fn merge_app_update(
    current: &mut AppStoreUpdateRecord,
    next: AppStoreUpdateRecord,
) -> Result<(), Box<AppStoreUpdateRecord>> {
    if matches!(current, AppStoreUpdateRecord::FullResync) {
        return Ok(());
    }
    if matches!(next, AppStoreUpdateRecord::FullResync) {
        *current = AppStoreUpdateRecord::FullResync;
        return Ok(());
    }
    if triggers_snapshot_refresh(current) && triggers_snapshot_refresh(&next) {
        *current = AppStoreUpdateRecord::FullResync;
        return Ok(());
    }

    match (current, next) {
        (
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key,
                item_id,
                kind,
                text,
            },
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key: next_key,
                item_id: next_item_id,
                kind: next_kind,
                text: next_text,
            },
        ) if *key == next_key
            && *item_id == next_item_id
            && *kind == next_kind
            && text.len().saturating_add(next_text.len()) <= MAX_COALESCED_STREAMING_TEXT_BYTES =>
        {
            text.push_str(&next_text);
            Ok(())
        }
        (
            AppStoreUpdateRecord::ThreadMetadataChanged {
                state,
                session_summary,
                agent_directory_version,
            },
            AppStoreUpdateRecord::ThreadMetadataChanged {
                state: next_state,
                session_summary: next_summary,
                agent_directory_version: next_version,
            },
        ) if state.key == next_state.key => {
            *state = next_state;
            *session_summary = next_summary;
            *agent_directory_version = next_version;
            Ok(())
        }
        (
            AppStoreUpdateRecord::ThreadItemChanged {
                key,
                item,
                session_summary,
            },
            AppStoreUpdateRecord::ThreadItemChanged {
                key: next_key,
                item: next_item,
                session_summary: next_summary,
            },
        ) if *key == next_key && item.id == next_item.id => {
            if should_preserve_thread_item_update_boundary(item, &next_item) {
                return Err(Box::new(AppStoreUpdateRecord::ThreadItemChanged {
                    key: next_key,
                    item: next_item,
                    session_summary: next_summary,
                }));
            }
            *item = next_item;
            *session_summary = next_summary;
            Ok(())
        }
        (
            AppStoreUpdateRecord::ThreadUpserted {
                thread,
                session_summary,
                agent_directory_version,
            },
            AppStoreUpdateRecord::ThreadUpserted {
                thread: next_thread,
                session_summary: next_summary,
                agent_directory_version: next_version,
            },
        ) if thread.key == next_thread.key => {
            *thread = next_thread;
            *session_summary = next_summary;
            *agent_directory_version = next_version;
            Ok(())
        }
        (
            AppStoreUpdateRecord::ActiveThreadChanged { key },
            AppStoreUpdateRecord::ActiveThreadChanged { key: next_key },
        ) => {
            *key = next_key;
            Ok(())
        }
        (_current, next) => Err(Box::new(next)),
    }
}

fn should_preserve_thread_item_update_boundary(
    current: &HydratedConversationItem,
    next: &HydratedConversationItem,
) -> bool {
    use HydratedConversationItemContent::*;

    match (&current.content, &next.content) {
        (CommandExecution(current), CommandExecution(next)) => {
            current.status != next.status
                || current.exit_code != next.exit_code
                || current.duration_ms != next.duration_ms
                || current.process_id != next.process_id
        }
        (McpToolCall(current), McpToolCall(next)) => {
            current.status != next.status
                || current.duration_ms != next.duration_ms
                || current.progress_messages != next.progress_messages
        }
        (DynamicToolCall(current), DynamicToolCall(next)) => {
            current.status != next.status
                || current.duration_ms != next.duration_ms
                || current.success != next.success
                || current.content_summary != next.content_summary
                || current.display != next.display
        }
        (FileChange(current), FileChange(next)) => {
            current.status != next.status || current.changes != next.changes
        }
        (MultiAgentAction(current), MultiAgentAction(next)) => {
            current.status != next.status
                || current.agent_states != next.agent_states
                || current.targets != next.targets
                || current.receiver_thread_ids != next.receiver_thread_ids
        }
        (ImageGeneration(current), ImageGeneration(next)) => {
            current.status != next.status
                || current.revised_prompt != next.revised_prompt
                || current.saved_path != next.saved_path
                || current.image_png.is_some() != next.image_png.is_some()
        }
        (WebSearch(current), WebSearch(next)) => {
            current.is_in_progress != next.is_in_progress || current.action_json != next.action_json
        }
        _ => false,
    }
}

fn triggers_snapshot_refresh(update: &AppStoreUpdateRecord) -> bool {
    matches!(
        update,
        AppStoreUpdateRecord::ServerChanged { .. }
            | AppStoreUpdateRecord::ServerRemoved { .. }
            | AppStoreUpdateRecord::PendingApprovalsChanged { .. }
            | AppStoreUpdateRecord::PendingUserInputsChanged { .. }
            | AppStoreUpdateRecord::VoiceSessionChanged
            | AppStoreUpdateRecord::RealtimeStarted { .. }
            | AppStoreUpdateRecord::RealtimeError { .. }
            | AppStoreUpdateRecord::RealtimeClosed { .. }
    )
}
