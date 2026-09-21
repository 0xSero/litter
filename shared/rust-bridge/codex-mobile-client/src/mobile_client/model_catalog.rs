use std::collections::HashSet;
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use super::MobileClient;
use crate::session::connection::ServerSession;
use crate::types::ModelInfo;

pub(super) struct ModelCatalogRefresh {
    session: Weak<ServerSession>,
    runtimes: Vec<String>,
    refreshed_at: Instant,
    complete: bool,
}

fn refresh_due(age: Duration, complete: bool) -> bool {
    age >= Duration::from_secs(if complete { 60 } else { 5 })
}

impl MobileClient {
    pub(crate) fn model_catalog_lock(&self, server_id: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut locks = self
            .model_catalog_locks
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        locks.retain(|_, lock| lock.strong_count() > 0);
        if let Some(lock) = locks.get(server_id).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(tokio::sync::Mutex::new(()));
        locks.insert(server_id.to_owned(), Arc::downgrade(&lock));
        lock
    }

    pub(crate) fn models_need_refresh(&self, server_id: &str) -> bool {
        let Some(session) = self.sessions_read().get(server_id).cloned() else {
            return false;
        };
        let refreshes = self
            .model_catalog_refreshes
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let Some(refresh) = refreshes.get(server_id) else {
            return true;
        };
        let mut runtimes = session.runtime_kinds();
        runtimes.sort();
        runtimes.dedup();
        refresh
            .session
            .upgrade()
            .is_none_or(|old| !Arc::ptr_eq(&old, &session))
            || refresh.runtimes != runtimes
            || refresh_due(refresh.refreshed_at.elapsed(), refresh.complete)
    }

    /// Replace just the completed runtime. Keep other live runtimes' last good
    /// catalogs until their own requests finish, including when requests fail.
    pub(crate) fn publish_model_catalog_runtime(
        &self,
        server_id: &str,
        session: &Arc<ServerSession>,
        runtimes: &[String],
        completed: Option<(&str, Vec<ModelInfo>)>,
    ) -> Result<bool, String> {
        let sessions = self.sessions_read();
        if !sessions
            .get(server_id)
            .is_some_and(|current| Arc::ptr_eq(current, session))
        {
            return Err("Connection changed while loading models; retry the catalog".into());
        }
        // Serialize concurrent refresh publications, and keep the session guard
        // until publication finishes so reconnect cannot install stale results.
        let _refreshes = self
            .model_catalog_refreshes
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let cached = self.app_store.server_models(server_id);
        let mut models = cached.clone().unwrap_or_default();
        models.retain(|model| {
            runtimes.contains(&model.agent_runtime_kind)
                && completed
                    .as_ref()
                    .is_none_or(|(runtime, _)| model.agent_runtime_kind != *runtime)
        });
        if let Some((_, runtime_models)) = completed {
            models.extend(runtime_models);
        }
        // Stable grouping avoids picker reorder churn from completion order;
        // each runtime still controls the order of its own models.
        models.sort_by(|a, b| a.agent_runtime_kind.cmp(&b.agent_runtime_kind));
        let mut seen = HashSet::new();
        models.retain(|model| seen.insert((model.agent_runtime_kind.clone(), model.id.clone())));
        if cached.as_ref() == Some(&models) {
            return Ok(false);
        }
        self.app_store.update_server_models(server_id, Some(models));
        Ok(true)
    }

    pub(crate) fn note_model_catalog_refresh(
        &self,
        server_id: &str,
        session: &Arc<ServerSession>,
        mut runtimes: Vec<String>,
        complete: bool,
    ) -> bool {
        let sessions = self.sessions_read();
        if !sessions
            .get(server_id)
            .is_some_and(|current| Arc::ptr_eq(current, session))
        {
            return false;
        }
        runtimes.sort();
        runtimes.dedup();
        let mut refreshes = self
            .model_catalog_refreshes
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        refreshes.retain(|_, refresh| refresh.session.strong_count() > 0);
        refreshes.insert(
            server_id.to_owned(),
            ModelCatalogRefresh {
                session: Arc::downgrade(session),
                runtimes,
                refreshed_at: Instant::now(),
                complete,
            },
        );
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::connection::ServerConfig;

    fn config() -> ServerConfig {
        ServerConfig {
            server_id: "catalog-test".into(),
            display_name: "Test".into(),
            host: "localhost".into(),
            port: 0,
            websocket_url: None,
            is_local: false,
            tls: false,
        }
    }

    fn model(runtime: &str, id: &str) -> ModelInfo {
        let upstream: codex_app_server_protocol::Model = serde_json::from_value(serde_json::json!({
            "id":id, "model":id, "displayName":id, "description":"Account catalog",
            "hidden":false, "supportedReasoningEfforts":[], "defaultReasoningEffort":"medium", "isDefault":true,
        })).unwrap();
        let mut model = ModelInfo::from(upstream);
        model.agent_runtime_kind = runtime.into();
        model
    }

    #[tokio::test]
    async fn model_catalog_publications_preserve_pending_cache_and_emit_only_changes() {
        let client = MobileClient::new();
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config(),
            None,
            None,
            None,
        ));
        client
            .sessions
            .write()
            .unwrap()
            .insert("catalog-test".into(), session.clone());
        client
            .app_store
            .upsert_server(&config(), crate::store::ServerHealthSnapshot::Connected);
        let cached = vec![
            model("codex", "old-codex"),
            model("hermes", "custom-default"),
        ];
        client
            .app_store
            .update_server_models("catalog-test", Some(cached));
        let mut updates = client.app_store.subscribe();
        let runtimes = vec!["codex".into(), "hermes".into()];
        let fresh = model("codex", "new-codex");
        assert!(
            client
                .publish_model_catalog_runtime(
                    "catalog-test",
                    &session,
                    &runtimes,
                    Some(("codex", vec![fresh.clone(), fresh.clone()]))
                )
                .unwrap()
        );
        assert!(updates.try_recv().is_ok());
        assert_eq!(
            client.app_store.server_models("catalog-test").unwrap(),
            vec![fresh.clone(), model("hermes", "custom-default")]
        );
        assert!(
            !client
                .publish_model_catalog_runtime(
                    "catalog-test",
                    &session,
                    &runtimes,
                    Some(("codex", vec![fresh]))
                )
                .unwrap()
        );
        assert!(matches!(
            updates.try_recv(),
            Err(tokio::sync::broadcast::error::TryRecvError::Empty)
        ));
        // A successful empty catalog clears only that runtime; failure would
        // skip this replacement and leave its last good catalog intact.
        assert!(
            client
                .publish_model_catalog_runtime(
                    "catalog-test",
                    &session,
                    &runtimes,
                    Some(("hermes", vec![]))
                )
                .unwrap()
        );
        assert_eq!(
            client
                .app_store
                .server_models("catalog-test")
                .unwrap()
                .len(),
            1
        );
        assert!(
            client
                .publish_model_catalog_runtime("catalog-test", &session, &[], None)
                .unwrap()
        );
        assert_eq!(client.app_store.server_models("catalog-test"), Some(vec![]));
    }

    #[tokio::test]
    async fn stale_model_catalog_cannot_publish_or_overwrite_reconnect_freshness() {
        let client = MobileClient::new();
        let old = Arc::new(ServerSession::test_stub_with_handlers(
            config(),
            None,
            None,
            None,
        ));
        let current = Arc::new(ServerSession::test_stub_with_handlers(
            config(),
            None,
            None,
            None,
        ));
        client
            .sessions
            .write()
            .unwrap()
            .insert("catalog-test".into(), current.clone());
        client
            .app_store
            .upsert_server(&config(), crate::store::ServerHealthSnapshot::Connected);
        let runtimes = vec!["codex".into()];
        client
            .publish_model_catalog_runtime(
                "catalog-test",
                &current,
                &runtimes,
                Some(("codex", vec![model("codex", "current")])),
            )
            .unwrap();
        assert!(client.note_model_catalog_refresh(
            "catalog-test",
            &current,
            runtimes.clone(),
            true
        ));
        let mut updates = client.app_store.subscribe();
        assert!(
            client
                .publish_model_catalog_runtime(
                    "catalog-test",
                    &old,
                    &runtimes,
                    Some(("codex", vec![model("codex", "stale")]))
                )
                .is_err()
        );
        assert!(!client.note_model_catalog_refresh("catalog-test", &old, runtimes, false));
        assert_eq!(
            client.app_store.server_models("catalog-test").unwrap(),
            vec![model("codex", "current")]
        );
        assert!(!client.models_need_refresh("catalog-test"));
        assert!(matches!(
            updates.try_recv(),
            Err(tokio::sync::broadcast::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn refresh_models_publishes_fast_catalog_before_slow_runtime_finishes() {
        use crate::session::connection::TestRequestHandler;
        use crate::types::AppRefreshModelsRequest;
        let client = Arc::new(MobileClient::new());
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        struct ReleaseOnDrop(Option<std::sync::mpsc::Sender<()>>);
        impl Drop for ReleaseOnDrop {
            fn drop(&mut self) {
                if let Some(tx) = self.0.take() {
                    let _ = tx.send(());
                }
            }
        }
        let release = ReleaseOnDrop(Some(release_tx));
        let release_rx = std::sync::Mutex::new(release_rx);
        let fast: TestRequestHandler = Arc::new(|_| {
            Ok(serde_json::json!({
                "data":[serde_json::to_value(model("codex", "new-codex")).unwrap()], "nextCursor":null
            }))
        });
        let slow: TestRequestHandler = Arc::new(move |_| {
            release_rx.lock().unwrap().recv().unwrap();
            Err(crate::transport::RpcError::Server {
                code: -32000,
                message: "catalog unavailable".into(),
            })
        });
        let session = Arc::new(ServerSession::test_stub_with_runtime_handlers(
            config(),
            vec![("codex".into(), fast), ("hermes".into(), slow)],
        ));
        client
            .sessions
            .write()
            .unwrap()
            .insert("catalog-test".into(), session);
        client
            .app_store
            .upsert_server(&config(), crate::store::ServerHealthSnapshot::Connected);
        client
            .app_store
            .update_server_models("catalog-test", Some(vec![model("hermes", "cached-hermes")]));
        let mut updates = client.app_store.subscribe();
        let app = crate::ffi::AppClient {
            inner: client.clone(),
            rt: crate::ffi::shared::shared_runtime(),
        };
        let refresh = tokio::spawn(async move {
            app.refresh_models(
                "catalog-test".into(),
                AppRefreshModelsRequest {
                    cursor: None,
                    limit: None,
                    include_hidden: None,
                },
            )
            .await
        });
        // The gate, not elapsed time, proves publication is incremental. The
        // timeout is only a deadlock guard if aggregation regresses to join_all.
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                updates.recv().await.unwrap();
                if client
                    .app_store
                    .server_models("catalog-test")
                    .unwrap()
                    .iter()
                    .any(|model| model.id == "new-codex")
                {
                    break;
                }
            }
        })
        .await
        .expect("fast catalog should publish while slow runtime is gated");
        assert!(!refresh.is_finished());
        assert_eq!(
            client
                .app_store
                .server_models("catalog-test")
                .unwrap()
                .iter()
                .map(|model| model.id.as_str())
                .collect::<Vec<_>>(),
            vec!["new-codex", "cached-hermes"]
        );
        drop(release);
        let error = refresh.await.unwrap().unwrap_err();
        assert!(error.to_string().contains("hermes"));
        assert_eq!(
            client
                .app_store
                .server_models("catalog-test")
                .unwrap()
                .len(),
            2
        );
        let refreshes = client.model_catalog_refreshes.lock().unwrap();
        assert!(!refreshes.get("catalog-test").unwrap().complete);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn queued_catalog_refresh_fetches_after_inflight_catalog_finishes() {
        use crate::session::connection::TestRequestHandler;
        use std::sync::atomic::{AtomicUsize, Ordering};
        let client = Arc::new(MobileClient::new());
        let requests = Arc::new(AtomicUsize::new(0));
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let started_tx = std::sync::Mutex::new(Some(started_tx));
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = std::sync::Mutex::new(release_rx);
        let count = requests.clone();
        let handler: TestRequestHandler = Arc::new(move |_| {
            let n = count.fetch_add(1, Ordering::SeqCst);
            if n == 0 {
                started_tx.lock().unwrap().take().unwrap().send(()).unwrap();
                release_rx
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(5))
                    .unwrap();
            }
            Ok(
                serde_json::json!({"data":[serde_json::to_value(model("codex", if n == 0 {"old"} else {"new"})).unwrap()], "nextCursor":null}),
            )
        });
        let session = Arc::new(ServerSession::test_stub_with_runtime_handlers(
            config(),
            vec![("codex".into(), handler)],
        ));
        client
            .sessions
            .write()
            .unwrap()
            .insert("catalog-test".into(), session);
        client
            .app_store
            .upsert_server(&config(), crate::store::ServerHealthSnapshot::Connected);
        let refresh = |client: Arc<MobileClient>| {
            tokio::spawn(async move {
                crate::ffi::AppClient {
                    inner: client,
                    rt: crate::ffi::shared::shared_runtime(),
                }
                .refresh_models(
                    "catalog-test".into(),
                    crate::types::AppRefreshModelsRequest {
                        cursor: None,
                        limit: None,
                        include_hidden: None,
                    },
                )
                .await
            })
        };
        let first = refresh(client.clone());
        started_rx.await.unwrap();
        let queue = client.model_catalog_lock("catalog-test");
        let second = refresh(client.clone());
        // The test, first call, and queued call each own this lock. Wait for
        // the second call to reach the queue, not an assumed scheduler delay.
        tokio::time::timeout(Duration::from_secs(2), async {
            while Arc::strong_count(&queue) < 3 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("second refresh must queue behind the first");
        assert_eq!(requests.load(Ordering::SeqCst), 1);
        release_tx.send(()).unwrap();
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        assert_eq!(requests.load(Ordering::SeqCst), 2);
        assert_eq!(
            client.app_store.server_models("catalog-test").unwrap()[0].id,
            "new"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn runtime_settings_reconnect_never_writes_to_replacement_session() {
        use crate::session::connection::TestRequestHandler;
        use codex_app_server_protocol::ClientRequest;
        use std::sync::atomic::{AtomicUsize, Ordering};
        for replace_on_write in [false, true] {
            let client = Arc::new(MobileClient::new());
            let replacement_calls = Arc::new(AtomicUsize::new(0));
            let calls = replacement_calls.clone();
            let replacement = Arc::new(ServerSession::test_stub_with_runtime_handlers(
                config(),
                vec![(
                    "codex".into(),
                    Arc::new(move |_| {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Ok(serde_json::json!({"config":{"model":"new"}}))
                    }),
                )],
            ));
            let weak = Arc::downgrade(&client);
            let writes = Arc::new(AtomicUsize::new(0));
            let written = writes.clone();
            let handler: TestRequestHandler = Arc::new(move |request| {
                let response = match request {
                    ClientRequest::ConfigRead { .. } => {
                        serde_json::json!({"config":{"model":"old"}})
                    }
                    ClientRequest::ConfigRequirementsRead { .. } => {
                        serde_json::json!({"requirements":null})
                    }
                    ClientRequest::ConfigValueWrite { .. } => {
                        written.fetch_add(1, Ordering::SeqCst);
                        serde_json::json!({"status":"ok"})
                    }
                    _ => panic!("unexpected settings request"),
                };
                if matches!(request, ClientRequest::ConfigValueWrite { .. }) == replace_on_write {
                    weak.upgrade()
                        .unwrap()
                        .sessions
                        .write()
                        .unwrap()
                        .insert("catalog-test".into(), replacement.clone());
                }
                Ok(response)
            });
            let session = Arc::new(ServerSession::test_stub_with_runtime_handlers(
                config(),
                vec![("codex".into(), handler)],
            ));
            client
                .sessions
                .write()
                .unwrap()
                .insert("catalog-test".into(), session);
            let app = crate::ffi::AppClient {
                inner: client,
                rt: crate::ffi::shared::shared_runtime(),
            };
            let error = app
                .set_runtime_setting(
                    "catalog-test".into(),
                    "codex".into(),
                    "model".into(),
                    "\"new\"".into(),
                )
                .await
                .unwrap_err();
            assert!(error.to_string().contains("Connection changed"));
            assert_eq!(writes.load(Ordering::SeqCst), usize::from(replace_on_write));
            assert_eq!(replacement_calls.load(Ordering::SeqCst), 0);
        }
    }

    #[test]
    fn incomplete_catalogs_retry_soon_without_refetching_on_every_render() {
        assert!(!refresh_due(Duration::from_secs(4), false));
        assert!(refresh_due(Duration::from_secs(5), false));
        assert!(!refresh_due(Duration::from_secs(59), true));
        assert!(refresh_due(Duration::from_secs(60), true));
    }

    #[tokio::test]
    async fn reconnect_and_runtime_inventory_changes_invalidate_catalog() {
        let client = MobileClient::new();
        let make_session = || {
            Arc::new(ServerSession::test_stub_with_handlers(
                ServerConfig {
                    server_id: "catalog-test".into(),
                    display_name: "Test".into(),
                    host: "localhost".into(),
                    port: 0,
                    websocket_url: None,
                    is_local: false,
                    tls: false,
                },
                None,
                None,
                None,
            ))
        };
        assert!(!client.models_need_refresh("catalog-test"));
        let first = make_session();
        client
            .sessions
            .write()
            .unwrap()
            .insert("catalog-test".into(), first.clone());
        assert!(client.models_need_refresh("catalog-test"));
        client.note_model_catalog_refresh("catalog-test", &first, first.runtime_kinds(), true);
        assert!(!client.models_need_refresh("catalog-test"));
        client.note_model_catalog_refresh(
            "catalog-test",
            &first,
            vec!["another-runtime".into()],
            true,
        );
        assert!(client.models_need_refresh("catalog-test"));
        client.note_model_catalog_refresh("catalog-test", &first, first.runtime_kinds(), true);
        client
            .sessions
            .write()
            .unwrap()
            .insert("catalog-test".into(), make_session());
        assert!(client.models_need_refresh("catalog-test"));
    }
}
