//! UniFFI-exported `ReconnectController` — shared reconnection orchestration
//! consumed by both iOS and Android.

use crate::ffi::shared::{shared_mobile_client, shared_runtime};
use crate::mobile_client::MobileClient;
use crate::next_request_id;
use crate::reconnect::{
    ReconnectResult, SavedServerRecord, SlingshotCredentialProvider, SshCredentialProvider,
    compute_reconnect_plan_with_slingshot, execute_reconnect_plan,
};
use crate::session::connection::{InProcessConfig, ServerConfig};
use crate::store::ServerHealthSnapshot;
use crate::store::snapshot::AppLifecyclePhaseSnapshot;
use codex_app_server_protocol as upstream;
use std::sync::{Arc, RwLock};
use tokio::runtime::Runtime;
use tokio::task::JoinSet;
use tracing::{info, warn};

fn normalized_local_display_name(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed == "This Device" {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn resolved_local_display_name(
    snapshot: &crate::store::AppSnapshot,
    saved_servers: &[SavedServerRecord],
    server_id: &str,
) -> String {
    snapshot
        .servers
        .get(server_id)
        .filter(|server| server.is_local)
        .and_then(|server| normalized_local_display_name(&server.display_name))
        .or_else(|| {
            snapshot
                .servers
                .values()
                .find(|server| server.is_local)
                .and_then(|server| normalized_local_display_name(&server.display_name))
        })
        .or_else(|| {
            saved_servers
                .iter()
                .find(|server| {
                    (server.id == server_id || server.id == "local")
                        && (server.source == "local" || server.id == "local")
                })
                .and_then(|server| normalized_local_display_name(&server.name))
        })
        .unwrap_or_else(|| "This Device".to_string())
}

fn server_counts_as_connected_for_reconnect(
    server: &crate::store::snapshot::ServerSnapshot,
) -> bool {
    matches!(server.health, ServerHealthSnapshot::Connected)
}

#[derive(uniffi::Object)]
pub struct ReconnectController {
    inner: Arc<MobileClient>,
    rt: Arc<Runtime>,
    saved_servers: Arc<RwLock<Vec<SavedServerRecord>>>,
    credential_provider: Arc<tokio::sync::Mutex<Option<Arc<dyn SshCredentialProvider>>>>,
    slingshot_credential_provider:
        Arc<tokio::sync::Mutex<Option<Arc<dyn SlingshotCredentialProvider>>>>,
    multi_clanker_and_quic_enabled: Arc<std::sync::Mutex<bool>>,
    reconnect_guard: Arc<tokio::sync::Mutex<()>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl ReconnectController {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
            saved_servers: Arc::new(RwLock::new(Vec::new())),
            credential_provider: Arc::new(tokio::sync::Mutex::new(None)),
            slingshot_credential_provider: Arc::new(tokio::sync::Mutex::new(None)),
            multi_clanker_and_quic_enabled: Arc::new(std::sync::Mutex::new(false)),
            reconnect_guard: Arc::new(tokio::sync::Mutex::new(())),
        }
    }

    pub fn set_credential_provider(&self, provider: Box<dyn SshCredentialProvider>) {
        let provider: Arc<dyn SshCredentialProvider> = Arc::from(provider);
        // Try non-blocking first; if contended, spawn an async task.
        let fast = {
            let cp = Arc::clone(&self.credential_provider);
            cp.try_lock().ok().map(|mut g| {
                *g = Some(Arc::clone(&provider));
            })
        };
        if fast.is_none() {
            let cp = Arc::clone(&self.credential_provider);
            self.rt.spawn(async move {
                *cp.lock().await = Some(provider);
            });
        }
    }

    pub fn set_slingshot_credential_provider(
        &self,
        provider: Box<dyn SlingshotCredentialProvider>,
    ) {
        let provider: Arc<dyn SlingshotCredentialProvider> = Arc::from(provider);
        let fast = {
            let cp = Arc::clone(&self.slingshot_credential_provider);
            cp.try_lock().ok().map(|mut g| {
                *g = Some(Arc::clone(&provider));
            })
        };
        if fast.is_none() {
            let cp = Arc::clone(&self.slingshot_credential_provider);
            self.rt.spawn(async move {
                *cp.lock().await = Some(provider);
            });
        }
    }

    pub fn set_multi_clanker_and_quic_enabled(&self, enabled: bool) {
        match self.multi_clanker_and_quic_enabled.lock() {
            Ok(mut guard) => *guard = enabled,
            Err(e) => *e.into_inner() = enabled,
        }
    }

    pub fn sync_saved_servers(&self, servers: Vec<SavedServerRecord>) {
        match self.saved_servers.write() {
            Ok(mut guard) => *guard = servers,
            Err(e) => *e.into_inner() = servers,
        }
    }

    pub async fn reconnect_saved_servers(&self) -> Vec<ReconnectResult> {
        let inner = Arc::clone(&self.inner);
        let saved_servers = Arc::clone(&self.saved_servers);
        let credential_provider = Arc::clone(&self.credential_provider);
        let slingshot_credential_provider = Arc::clone(&self.slingshot_credential_provider);
        let multi_clanker_and_quic_enabled = match self.multi_clanker_and_quic_enabled.lock() {
            Ok(guard) => *guard,
            Err(e) => *e.into_inner(),
        };
        let reconnect_guard = Arc::clone(&self.reconnect_guard);

        // Keep the full reconnect body off the foreign async executor stack.
        // iOS can poll UniFFI futures from a small cooperative thread stack,
        // and reconnect reaches the SSH/websocket handshake path.
        self.rt
            .spawn(async move {
                reconnect_saved_servers_inner(
                    inner,
                    saved_servers,
                    credential_provider,
                    slingshot_credential_provider,
                    multi_clanker_and_quic_enabled,
                    reconnect_guard,
                )
                .await
            })
            .await
            .unwrap_or_else(|error| {
                warn!("ReconnectController: reconnect_saved_servers task failed: {error}");
                Vec::new()
            })
    }

    pub async fn reconnect_server(&self, server_id: String) -> ReconnectResult {
        let inner = Arc::clone(&self.inner);
        let saved_servers = Arc::clone(&self.saved_servers);
        let credential_provider = Arc::clone(&self.credential_provider);
        let slingshot_credential_provider = Arc::clone(&self.slingshot_credential_provider);
        let multi_clanker_and_quic_enabled = match self.multi_clanker_and_quic_enabled.lock() {
            Ok(guard) => *guard,
            Err(e) => *e.into_inner(),
        };
        let server_id_for_error = server_id.clone();

        // Match the SSH bridge behavior and run reconnect on Tokio so the
        // websocket connect path does not execute on Swift's smaller stack.
        self.rt
            .spawn(async move {
                let result = reconnect_server_inner(
                    Arc::clone(&inner),
                    saved_servers,
                    credential_provider,
                    slingshot_credential_provider,
                    multi_clanker_and_quic_enabled,
                    server_id,
                )
                .await;
                result
            })
            .await
            .unwrap_or_else(|error| ReconnectResult {
                server_id: server_id_for_error,
                success: false,
                needs_local_auth_restore: false,
                error_message: Some(format!("reconnect task failed: {error}")),
            })
    }

    pub async fn probe_active_remote_servers(&self) {
        let inner = Arc::clone(&self.inner);

        // Run the probe body on the shared tokio runtime: the probe awaits
        // session.request_client(...), which uses tokio primitives and would
        // panic ("no reactor running") when polled from the Swift/Kotlin
        // foreign async executor.
        let _ = self
            .rt
            .spawn(async move {
                let snapshot = inner.app_snapshot();
                let remote_connected: Vec<String> = snapshot
                    .servers
                    .values()
                    .filter(|s| !s.is_local && s.health == ServerHealthSnapshot::Connected)
                    .map(|s| s.server_id.clone())
                    .collect();

                for server_id in &remote_connected {
                    let request = upstream::ClientRequest::GetAccount {
                        request_id: upstream::RequestId::Integer(next_request_id()),
                        params: upstream::GetAccountParams {
                            refresh_token: false,
                        },
                    };
                    match inner
                        .request_typed_for_server::<upstream::GetAccountResponse>(
                            server_id, request,
                        )
                        .await
                    {
                        Ok(response) => {
                            inner.apply_account_response(server_id, &response);
                        }
                        Err(e) => {
                            warn!(
                                "ReconnectController: probe failed server_id={} error={}",
                                server_id, e
                            );
                        }
                    }
                }
            })
            .await
            .inspect_err(|error| {
                warn!("ReconnectController: probe_active_remote_servers task failed: {error}");
            });
    }

    pub async fn on_app_became_active(&self) -> Vec<ReconnectResult> {
        self.note_app_became_active();
        // Hint iroh-backed sessions that the host network may have changed
        // before we run the reconnect plan. This lets healthy alleycat
        // sessions migrate paths/refresh relays without going through the
        // (heavier) full reconnect path; reconnect_saved_servers is still
        // run for transports that can't recover on their own.
        self.notify_network_change().await;
        let results = self.reconnect_saved_servers().await;
        self.probe_active_remote_servers().await;
        results
    }

    pub fn note_app_became_active(&self) {
        self.inner
            .app_store
            .note_app_lifecycle_phase(AppLifecyclePhaseSnapshot::Active);
    }

    /// Tell every session that the host network may have changed. iOS
    /// suspends app processes (which freezes UDP sockets and relay
    /// keepalives) and there's no in-process API to detect that — without
    /// this hint, iroh would only notice paths are dead via the QUIC idle
    /// timeout (10 min). Calling this on `appDidBecomeActive` lets iroh
    /// re-probe paths immediately. Cheap when nothing changed.
    pub async fn notify_network_change(&self) {
        let inner = Arc::clone(&self.inner);
        let _ = self
            .rt
            .spawn(async move {
                inner.notify_network_change().await;
            })
            .await
            .inspect_err(|error| {
                warn!("ReconnectController: notify_network_change task failed: {error}");
            });
    }

    /// Lifecycle hook for "I just resumed from a long background or a
    /// push wake." iroh's `network_change` hint operates on the endpoint
    /// discovery layer; it can't observe that our connection-level path
    /// has been silently dead since the OS suspended us. After more than
    /// ~iroh's per-path idle (15s), the existing `Connection` is almost
    /// certainly toast and waiting on the 30s connection-idle timer for
    /// the worker to notice would make the next user request hang up to
    /// 30s. This hook short-circuits that wait by closing every active
    /// alleycat `Connection` and letting the worker rebuild via the
    /// existing reconnect path.
    ///
    /// Cheap: alleycat-only (no-op for SSH/WebSocket transports), and
    /// the new `Connection` is opened on the same shared `Endpoint`.
    pub async fn on_long_resume(&self) {
        let inner = Arc::clone(&self.inner);
        let _ = self
            .rt
            .spawn(async move {
                inner.abandon_alleycat_connections().await;
            })
            .await
            .inspect_err(|error| {
                warn!("ReconnectController: on_long_resume task failed: {error}");
            });
    }

    pub fn on_app_became_inactive(&self) {
        self.inner
            .app_store
            .note_app_lifecycle_phase(AppLifecyclePhaseSnapshot::Inactive);
    }

    pub fn on_app_entered_background(&self) {
        self.inner
            .app_store
            .note_app_lifecycle_phase(AppLifecyclePhaseSnapshot::Background);
    }

    pub async fn on_network_reachable(&self) -> Vec<ReconnectResult> {
        self.notify_network_change().await;
        self.reconnect_saved_servers().await
    }
}

async fn reconnect_saved_servers_inner(
    inner: Arc<MobileClient>,
    saved_servers: Arc<RwLock<Vec<SavedServerRecord>>>,
    credential_provider: Arc<tokio::sync::Mutex<Option<Arc<dyn SshCredentialProvider>>>>,
    slingshot_credential_provider: Arc<
        tokio::sync::Mutex<Option<Arc<dyn SlingshotCredentialProvider>>>,
    >,
    multi_clanker_and_quic_enabled: bool,
    reconnect_guard: Arc<tokio::sync::Mutex<()>>,
) -> Vec<ReconnectResult> {
    let guard = match reconnect_guard.try_lock() {
        Ok(guard) => guard,
        Err(_) => {
            info!("ReconnectController: reconnect already in progress; skipping");
            return Vec::new();
        }
    };

    let servers = match saved_servers.read() {
        Ok(s) => s.clone(),
        Err(e) => e.into_inner().clone(),
    };

    let snapshot = inner.app_snapshot();
    let connected_ids: std::collections::HashSet<String> = snapshot
        .servers
        .values()
        .filter(|server| server_counts_as_connected_for_reconnect(server))
        .map(|s| s.server_id.clone())
        .collect();

    let local_display_name = resolved_local_display_name(&snapshot, &servers, "local");

    let has_local = snapshot
        .servers
        .values()
        .any(|server| server.is_local && server_counts_as_connected_for_reconnect(server));
    let mut local_result: Option<ReconnectResult> = None;
    if !has_local {
        info!("ReconnectController: ensuring local server connected");
        let config = ServerConfig {
            server_id: "local".to_string(),
            display_name: local_display_name,
            host: "127.0.0.1".to_string(),
            port: 0,
            websocket_url: None,
            is_local: true,
            tls: false,
        };
        match inner
            .connect_local(config, InProcessConfig::default())
            .await
        {
            Ok(_) => {
                local_result = Some(ReconnectResult {
                    server_id: "local".to_string(),
                    success: true,
                    needs_local_auth_restore: true,
                    error_message: None,
                });
            }
            Err(e) => {
                warn!("ReconnectController: local server connect failed: {}", e);
            }
        }
    }

    let credential_provider = credential_provider.lock().await;
    let slingshot_credential_provider = slingshot_credential_provider.lock().await;
    let slingshot_credential = slingshot_credential_provider
        .as_ref()
        .and_then(|provider| provider.load_credential());

    let mut plans = Vec::new();
    for server in &servers {
        if !server.remembered_by_user || server.source == "local" {
            continue;
        }
        let is_connected = connected_ids.contains(&server.id);
        let credential = credential_provider.as_ref().and_then(|p| {
            let ssh_port = crate::reconnect::resolved_ssh_port(server);
            p.load_credential(server.hostname.clone(), ssh_port)
        });
        if let Some(plan) = compute_reconnect_plan_with_slingshot(
            server,
            credential.as_ref(),
            slingshot_credential.as_ref(),
            is_connected,
            multi_clanker_and_quic_enabled,
        ) {
            plans.push(plan);
        }
    }
    drop(slingshot_credential_provider);
    drop(credential_provider);

    let mut join_set = JoinSet::new();
    for plan in plans {
        let client = Arc::clone(&inner);
        join_set.spawn(async move { execute_reconnect_plan(&plan, &client).await });
    }

    let mut results = Vec::new();
    if let Some(lr) = local_result {
        results.push(lr);
    }
    while let Some(result) = join_set.join_next().await {
        match result {
            Ok(r) => results.push(r),
            Err(e) => warn!("ReconnectController: join error: {}", e),
        }
    }

    drop(guard);
    results
}

async fn reconnect_server_inner(
    inner: Arc<MobileClient>,
    saved_servers: Arc<RwLock<Vec<SavedServerRecord>>>,
    credential_provider: Arc<tokio::sync::Mutex<Option<Arc<dyn SshCredentialProvider>>>>,
    slingshot_credential_provider: Arc<
        tokio::sync::Mutex<Option<Arc<dyn SlingshotCredentialProvider>>>,
    >,
    multi_clanker_and_quic_enabled: bool,
    server_id: String,
) -> ReconnectResult {
    let snapshot = inner.app_snapshot();
    let saved_server = {
        let servers = match saved_servers.read() {
            Ok(s) => s,
            Err(e) => e.into_inner(),
        };
        servers.iter().find(|s| s.id == server_id).cloned()
    };

    let is_local = snapshot.servers.get(&server_id).is_some_and(|s| s.is_local)
        || server_id == "local"
        || saved_server
            .as_ref()
            .is_some_and(|server| server.source == "local");

    if is_local {
        let config = ServerConfig {
            server_id: server_id.clone(),
            display_name: resolved_local_display_name(
                &snapshot,
                saved_server.as_ref().map_or(&[], std::slice::from_ref),
                &server_id,
            ),
            host: "127.0.0.1".to_string(),
            port: 0,
            websocket_url: None,
            is_local: true,
            tls: false,
        };
        inner.disconnect_server(&server_id);
        return match inner
            .connect_local(config, InProcessConfig::default())
            .await
        {
            Ok(_) => ReconnectResult {
                server_id,
                success: true,
                needs_local_auth_restore: true,
                error_message: None,
            },
            Err(e) => ReconnectResult {
                server_id,
                success: false,
                needs_local_auth_restore: false,
                error_message: Some(e.to_string()),
            },
        };
    }

    inner.disconnect_server(&server_id);

    if let Some(server) = saved_server {
        let credential_provider = credential_provider.lock().await;
        let slingshot_credential_provider = slingshot_credential_provider.lock().await;
        let credential = credential_provider.as_ref().and_then(|p| {
            let ssh_port = crate::reconnect::resolved_ssh_port(&server);
            p.load_credential(server.hostname.clone(), ssh_port)
        });
        let slingshot_credential = slingshot_credential_provider
            .as_ref()
            .and_then(|provider| provider.load_credential());
        drop(slingshot_credential_provider);
        drop(credential_provider);

        if let Some(plan) = compute_reconnect_plan_with_slingshot(
            &server,
            credential.as_ref(),
            slingshot_credential.as_ref(),
            false,
            multi_clanker_and_quic_enabled,
        ) {
            return execute_reconnect_plan(&plan, &inner).await;
        }
    }

    if let Some(snap_server) = snapshot.servers.get(&server_id) {
        let config = ServerConfig {
            server_id: snap_server.server_id.clone(),
            display_name: snap_server.display_name.clone(),
            host: snap_server.host.clone(),
            port: snap_server.port,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        return match inner.connect_remote(config).await {
            Ok(_) => ReconnectResult {
                server_id,
                success: true,
                needs_local_auth_restore: false,
                error_message: None,
            },
            Err(e) => ReconnectResult {
                server_id,
                success: false,
                needs_local_auth_restore: false,
                error_message: Some(e.to_string()),
            },
        };
    }

    ReconnectResult {
        server_id,
        success: false,
        needs_local_auth_restore: false,
        error_message: Some("server not found in saved list or snapshot".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::{resolved_local_display_name, server_counts_as_connected_for_reconnect};
    use crate::reconnect::SavedServerRecord;
    use crate::store::snapshot::{
        AppSnapshot, AppVoiceSessionSnapshot, ServerHealthSnapshot, ServerSnapshot,
        ServerTransportDiagnostics,
    };
    use std::collections::HashMap;

    fn empty_snapshot() -> AppSnapshot {
        AppSnapshot {
            servers: HashMap::new(),
            threads: HashMap::new(),
            active_thread: None,
            pending_approvals: Vec::new(),
            pending_approval_seeds: HashMap::new(),
            pending_user_inputs: Vec::new(),
            pending_user_input_seeds: HashMap::new(),
            voice_session: AppVoiceSessionSnapshot::default(),
            terminal_sessions: Vec::new(),
            active_terminal_id: None,
        }
    }

    fn server_with_health(health: ServerHealthSnapshot) -> ServerSnapshot {
        ServerSnapshot {
            server_id: "srv".to_string(),
            display_name: "Test".to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            wake_mac: None,
            is_local: false,
            health,
            account: None,
            requires_openai_auth: false,
            rate_limits: None,
            rate_limits_by_runtime: std::collections::HashMap::new(),
            available_models: None,
            agent_runtimes: Vec::new(),
            connection_progress: None,
            transport: ServerTransportDiagnostics::default(),
            codex_version: None,
            supports_turn_pagination: true,
        }
    }

    #[test]
    fn reconnect_skip_only_counts_fully_connected_servers() {
        assert!(server_counts_as_connected_for_reconnect(
            &server_with_health(ServerHealthSnapshot::Connected)
        ));
        assert!(!server_counts_as_connected_for_reconnect(
            &server_with_health(ServerHealthSnapshot::Connecting)
        ));
        assert!(!server_counts_as_connected_for_reconnect(
            &server_with_health(ServerHealthSnapshot::Disconnected)
        ));
        assert!(!server_counts_as_connected_for_reconnect(
            &server_with_health(ServerHealthSnapshot::Unresponsive)
        ));
    }

    #[test]
    fn local_display_name_prefers_snapshot_name() {
        let mut snapshot = empty_snapshot();
        snapshot.servers.insert(
            "local".to_string(),
            ServerSnapshot {
                server_id: "local".to_string(),
                display_name: "Desk Mac".to_string(),
                host: "127.0.0.1".to_string(),
                port: 0,
                wake_mac: None,
                is_local: true,
                health: ServerHealthSnapshot::Disconnected,
                account: None,
                requires_openai_auth: false,
                rate_limits: None,
                rate_limits_by_runtime: std::collections::HashMap::new(),
                available_models: None,
                agent_runtimes: Vec::new(),
                connection_progress: None,
                transport: ServerTransportDiagnostics::default(),
                codex_version: None,
                supports_turn_pagination: true,
            },
        );

        assert_eq!(
            resolved_local_display_name(&snapshot, &[], "local"),
            "Desk Mac"
        );
    }

    #[test]
    fn local_display_name_falls_back_to_saved_server_name() {
        let saved = SavedServerRecord {
            id: "local".to_string(),
            name: "Laptop".to_string(),
            hostname: "127.0.0.1".to_string(),
            port: 0,
            codex_ports: Vec::new(),
            ssh_port: None,
            source: "local".to_string(),
            has_codex_server: false,
            wake_mac: None,
            preferred_connection_mode: None,
            preferred_codex_port: None,
            ssh_port_forwarding_enabled: None,
            websocket_url: None,
            remembered_by_user: true,
            alleycat_host: None,
            alleycat_udp_port: None,
            alleycat_node_id: None,
            alleycat_token: None,
            alleycat_relay: None,
            alleycat_agent_name: None,
            alleycat_agent_wire: None,
        };

        assert_eq!(
            resolved_local_display_name(&empty_snapshot(), &[saved], "local"),
            "Laptop"
        );
    }

    #[test]
    fn local_display_name_ignores_legacy_placeholder() {
        let mut snapshot = empty_snapshot();
        snapshot.servers.insert(
            "local".to_string(),
            ServerSnapshot {
                server_id: "local".to_string(),
                display_name: "This Device".to_string(),
                host: "127.0.0.1".to_string(),
                port: 0,
                wake_mac: None,
                is_local: true,
                health: ServerHealthSnapshot::Disconnected,
                account: None,
                requires_openai_auth: false,
                rate_limits: None,
                rate_limits_by_runtime: std::collections::HashMap::new(),
                available_models: None,
                agent_runtimes: Vec::new(),
                connection_progress: None,
                transport: ServerTransportDiagnostics::default(),
                codex_version: None,
                supports_turn_pagination: true,
            },
        );

        let saved = SavedServerRecord {
            id: "local".to_string(),
            name: "Desk Mac".to_string(),
            hostname: "127.0.0.1".to_string(),
            port: 0,
            codex_ports: Vec::new(),
            ssh_port: None,
            source: "local".to_string(),
            has_codex_server: false,
            wake_mac: None,
            preferred_connection_mode: None,
            preferred_codex_port: None,
            ssh_port_forwarding_enabled: None,
            websocket_url: None,
            remembered_by_user: true,
            alleycat_host: None,
            alleycat_udp_port: None,
            alleycat_node_id: None,
            alleycat_token: None,
            alleycat_relay: None,
            alleycat_agent_name: None,
            alleycat_agent_wire: None,
        };

        assert_eq!(
            resolved_local_display_name(&snapshot, &[saved], "local"),
            "Desk Mac"
        );
    }
}
