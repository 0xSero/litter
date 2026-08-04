use crate::MobileClient;
use crate::discovery_uniffi::{AppDiscoveredServer, AppMdnsSeed, AppProgressiveDiscoveryUpdate};
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::ffi::ssh::{
    mark_progress_failure, normalize_ssh_host, run_guided_ssh_connect, ssh_auth, ssh_auth_kind,
};
use crate::mobile_client::{ManagedSshBootstrapFlow, slingshot_user_agent};
use crate::session::connection::{InProcessConfig, ServerConfig};
use crate::slingshot_url::build_slingshot_connection_url;
use crate::slingshot_url::normalize_slingshot_base_url;
use crate::slingshot_url::parse_slingshot_connection_url;
use crate::ssh::SshCredentials;
use crate::store::{AppConnectionProgressSnapshot, ServerHealthSnapshot};
use std::sync::Arc;
use tokio::sync::oneshot;
use tracing::{debug, info, trace, warn};

#[derive(Clone, Debug, uniffi::Record)]
pub struct AppSlingshotEnvironment {
    pub id: String,
    pub connection_url: String,
    pub display_name: String,
    pub raw_display_name: Option<String>,
    pub name: Option<String>,
    pub host_name: Option<String>,
    pub online: bool,
    pub busy: bool,
    pub operating_system: String,
    pub architecture: Option<String>,
    pub app_server_version: Option<String>,
    pub last_seen_at: Option<String>,
}

impl AppSlingshotEnvironment {
    fn from_environment(value: codex_slingshot::SlingshotEnvironment, base_url: &str) -> Self {
        let operating_system = match value.operating_system {
            codex_slingshot::OperatingSystem::Known(known) => match known {
                codex_slingshot::KnownOperatingSystem::Macos => "macos".to_string(),
                codex_slingshot::KnownOperatingSystem::Windows => "windows".to_string(),
                codex_slingshot::KnownOperatingSystem::Linux => "linux".to_string(),
            },
            codex_slingshot::OperatingSystem::Unknown(raw) => raw,
        };
        let display_name = value
            .name
            .clone()
            .or_else(|| value.raw_display_name.clone())
            .or_else(|| value.host_name.clone())
            .unwrap_or_else(|| value.id.clone());
        let connection_url = build_slingshot_connection_url(&value.id, base_url)
            .unwrap_or_else(|| format!("slingshot://{}", value.id));
        Self {
            id: value.id,
            connection_url,
            display_name,
            raw_display_name: value.raw_display_name,
            name: value.name,
            host_name: value.host_name,
            online: value.online,
            busy: value.busy,
            operating_system,
            architecture: value.architecture,
            app_server_version: value.app_server_version,
            last_seen_at: value.last_seen_at.map(|date| date.to_rfc3339()),
        }
    }
}

#[derive(uniffi::Object)]
pub struct DiscoveryBridge {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object)]
pub struct ServerBridge {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object)]
pub struct DiscoveryScanSubscription {
    pub(crate) rx: std::sync::Mutex<
        Option<tokio::sync::broadcast::Receiver<crate::discovery::ProgressiveDiscoveryUpdate>>,
    >,
}

#[uniffi::export(async_runtime = "tokio")]
impl DiscoveryBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    pub async fn scan_servers_with_mdns_context(
        &self,
        seeds: Vec<AppMdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Result<Vec<AppDiscoveredServer>, ClientError> {
        let seeds: Vec<_> = seeds.into_iter().map(Into::into).collect();
        blocking_async!(self.rt, self.inner, |c| {
            Ok(c.scan_servers_with_mdns_context(seeds, local_ipv4)
                .await
                .into_iter()
                .map(AppDiscoveredServer::from)
                .collect())
        })
    }

    pub fn scan_servers_with_mdns_context_progressive(
        &self,
        seeds: Vec<AppMdnsSeed>,
        local_ipv4: Option<String>,
    ) -> DiscoveryScanSubscription {
        let seeds: Vec<_> = seeds.into_iter().map(Into::into).collect();
        DiscoveryScanSubscription {
            rx: std::sync::Mutex::new(Some(
                self.inner
                    .subscribe_scan_servers_with_mdns_context(seeds, local_ipv4),
            )),
        }
    }

    pub fn reconcile_servers(
        &self,
        candidates: Vec<AppDiscoveredServer>,
    ) -> Vec<AppDiscoveredServer> {
        crate::discovery::reconcile_discovered_servers(
            candidates.into_iter().map(Into::into).collect(),
        )
        .into_iter()
        .map(AppDiscoveredServer::from)
        .collect()
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl ServerBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    pub async fn connect_local_server(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    ) -> Result<String, ClientError> {
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            websocket_url: None,
            is_local: true,
            tls: false,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_local(config, InProcessConfig::default())
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn connect_remote_server(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    ) -> Result<String, ClientError> {
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_remote(config)
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn connect_remote_url_server(
        &self,
        server_id: String,
        display_name: String,
        websocket_url: String,
    ) -> Result<String, ClientError> {
        let parsed = url::Url::parse(&websocket_url)
            .map_err(|e| ClientError::InvalidParams(format!("invalid websocket URL: {e}")))?;
        let host = parsed
            .host_str()
            .ok_or_else(|| ClientError::InvalidParams("websocket URL host missing".to_string()))?
            .to_string();
        let port = parsed
            .port_or_known_default()
            .ok_or_else(|| ClientError::InvalidParams("websocket URL port missing".to_string()))?;
        let tls = matches!(parsed.scheme(), "wss" | "https");
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            websocket_url: Some(websocket_url),
            is_local: false,
            tls,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_remote(config)
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn list_slingshot_environments(
        &self,
        base_url: String,
        access_token: String,
        account_id: String,
    ) -> Result<Vec<AppSlingshotEnvironment>, ClientError> {
        blocking_async!(self.rt, self.inner, |_c| {
            let normalized_base_url = normalize_slingshot_base_url(base_url.trim());
            let base_url = url::Url::parse(&normalized_base_url).map_err(|e| {
                ClientError::InvalidParams(format!("invalid Slingshot base URL: {e}"))
            })?;
            let api = codex_slingshot::SlingshotApi::new(codex_slingshot::SlingshotConfig {
                base_url,
                auth_token: access_token,
                user_agent: slingshot_user_agent(),
                account_id: Some(account_id),
                originator: Some("Codex Desktop".to_string()),
                client_id: None,
            });
            api.list_environments()
                .await
                .map(|envs| {
                    envs.into_iter()
                        .map(|env| {
                            AppSlingshotEnvironment::from_environment(env, &normalized_base_url)
                        })
                        .collect()
                })
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn connect_remote_slingshot_url_server(
        &self,
        server_id: String,
        display_name: String,
        connection_url: String,
        access_token: String,
        account_id: String,
        step_up_token: String,
    ) -> Result<String, ClientError> {
        let slingshot = parse_slingshot_connection_url(&connection_url).ok_or_else(|| {
            ClientError::InvalidParams("invalid Slingshot connection URL".to_string())
        })?;
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_remote_over_slingshot(
                server_id,
                display_name,
                slingshot.base_url,
                access_token,
                account_id,
                slingshot.environment_id,
                step_up_token,
            )
            .await
            .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn list_alleycat_agents(
        &self,
        params: crate::ffi::alleycat::AppAlleycatPairPayload,
        wait_for_registration: bool,
    ) -> Result<Vec<crate::ffi::alleycat::AppAlleycatAgentInfo>, ClientError> {
        let parsed: crate::alleycat::ParsedPairPayload = params.into();
        blocking_async!(self.rt, self.inner, |c| {
            c.list_alleycat_agents(parsed, wait_for_registration)
                .await
                .map(|agents| agents.into_iter().map(Into::into).collect())
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn connect_remote_over_alleycat(
        &self,
        server_id: String,
        display_name: String,
        params: crate::ffi::alleycat::AppAlleycatPairPayload,
        agent_name: String,
        selected_agent_names: Vec<String>,
        wire: crate::ffi::alleycat::AppAlleycatAgentWire,
    ) -> Result<crate::ffi::alleycat::AppAlleycatConnectResult, ClientError> {
        let parsed: crate::alleycat::ParsedPairPayload = params.into();
        let wire: crate::alleycat::AgentWire = wire.into();
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_remote_over_alleycat(
                server_id,
                display_name,
                parsed,
                agent_name,
                selected_agent_names,
                wire,
            )
            .await
            .map(|outcome| crate::ffi::alleycat::AppAlleycatConnectResult {
                server_id: outcome.server_id,
                node_id: outcome.node_id,
                agent_name: outcome.agent_name,
            })
            .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub fn disconnect_server(&self, server_id: String) {
        self.inner.disconnect_server(&server_id);
    }

    pub async fn restart_app_server(&self, server_id: String) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.restart_app_server(&server_id)
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    /// Connect to a remote server over SSH (non-guided). The full SSH bootstrap
    /// runs on Tokio and only the final completion is surfaced back through
    /// UniFFI — polling the bootstrap directly from Swift's cooperative
    /// executor can overflow its small stack on iOS during the WebSocket
    /// handshake.
    #[allow(clippy::too_many_arguments)]
    pub async fn connect_remote_over_ssh(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        unlock_macos_keychain: bool,
        accept_unknown_host: bool,
        working_dir: Option<String>,
    ) -> Result<String, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        info!(
            "ServerBridge: connect_remote_over_ssh start server_id={} host={} normalized_host={} ssh_port={} username={} auth={} working_dir={}",
            server_id,
            host.as_str(),
            normalized_host.as_str(),
            port,
            username.as_str(),
            ssh_auth_kind(&auth),
            working_dir.as_deref().unwrap_or("<none>")
        );
        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
            unlock_macos_keychain,
        };
        let config = ServerConfig {
            server_id,
            display_name,
            host: normalized_host,
            port: 0,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        let mobile_client = shared_mobile_client();
        let (tx, rx) = oneshot::channel();
        let task_server_id = config.server_id.clone();
        tokio::spawn(async move {
            let result = mobile_client
                .connect_remote_over_ssh(config, credentials, accept_unknown_host, working_dir)
                .await
                .map_err(|e| ClientError::Transport(e.to_string()));
            match &result {
                Ok(server_id) => info!(
                    "ServerBridge: connect_remote_over_ssh completed server_id={}",
                    server_id
                ),
                Err(error) => warn!(
                    "ServerBridge: connect_remote_over_ssh failed server_id={} error={}",
                    task_server_id, error
                ),
            }
            let _ = tx.send(result);
        });
        rx.await
            .map_err(|_| ClientError::Rpc("ssh connect task cancelled".to_string()))?
    }

    /// Start a guided SSH connect: spawns the bootstrap task and returns
    /// immediately so the UI can show step-by-step progress via
    /// `AppConnectionProgressSnapshot`. Codex must already be installed on the
    /// remote host and discoverable as `codex`.
    #[allow(clippy::too_many_arguments)]
    pub async fn start_remote_over_ssh_connect(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        unlock_macos_keychain: bool,
        accept_unknown_host: bool,
        working_dir: Option<String>,
    ) -> Result<String, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        info!(
            "ServerBridge: start_remote_over_ssh_connect start server_id={} host={} normalized_host={} ssh_port={} username={} auth={} working_dir={}",
            server_id,
            host.as_str(),
            normalized_host.as_str(),
            port,
            username.as_str(),
            ssh_auth_kind(&auth),
            working_dir.as_deref().unwrap_or("<none>")
        );
        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
            unlock_macos_keychain,
        };
        let config = ServerConfig {
            server_id: server_id.clone(),
            display_name,
            host: normalized_host,
            port: 0,
            websocket_url: None,
            is_local: false,
            tls: false,
        };

        let mobile_client = shared_mobile_client();
        {
            let mut flows = mobile_client.ssh_bootstrap_flows.lock().await;
            if flows.contains_key(&server_id) {
                debug!(
                    "ServerBridge: start_remote_over_ssh_connect reusing existing bootstrap flow server_id={}",
                    server_id
                );
                return Ok(server_id);
            }
            flows.insert(server_id.clone(), ManagedSshBootstrapFlow {});
        }

        mobile_client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting);
        let initial_progress = AppConnectionProgressSnapshot::ssh_bootstrap();
        mobile_client
            .app_store
            .update_server_connection_progress(&server_id, Some(initial_progress.clone()));

        let flows = Arc::clone(&mobile_client.ssh_bootstrap_flows);
        let task_server_id = server_id.clone();
        let task_host = credentials.host.clone();
        tokio::spawn(async move {
            let mut progress = initial_progress;
            trace!(
                "ServerBridge: guided ssh connect task spawned server_id={} host={}",
                task_server_id, task_host
            );
            let task_result = run_guided_ssh_connect(
                Arc::clone(&mobile_client),
                config,
                credentials,
                accept_unknown_host,
                working_dir,
                &mut progress,
            )
            .await;

            if let Err(ref error) = task_result {
                warn!(
                    "guided ssh connect failed server_id={} host={} error={}",
                    task_server_id, task_host, error
                );
                mark_progress_failure(&mut progress, error.to_string());
                mobile_client
                    .app_store
                    .update_server_health(&task_server_id, ServerHealthSnapshot::Disconnected);
                mobile_client
                    .app_store
                    .update_server_connection_progress(&task_server_id, Some(progress));
            }

            if task_result.is_ok() {
                info!(
                    "ServerBridge: guided ssh connect completed server_id={} host={}",
                    task_server_id, task_host
                );
            }

            flows.lock().await.remove(&task_server_id);
        });

        Ok(server_id)
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl DiscoveryScanSubscription {
    pub async fn next_event(&self) -> Result<AppProgressiveDiscoveryUpdate, ClientError> {
        let mut rx = {
            self.rx
                .lock()
                .unwrap()
                .take()
                .ok_or(ClientError::EventClosed(
                    "no discovery subscriber".to_string(),
                ))?
        };
        let result = loop {
            match rx.recv().await {
                Ok(update) => break Ok(update.into()),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break Err(ClientError::EventClosed("closed".to_string()));
                }
            }
        };
        *self.rx.lock().unwrap() = Some(rx);
        result
    }
}
