use crate::ffi::ClientError;
use crate::ffi::shared::{shared_mobile_client, shared_runtime};
use crate::session::connection::ServerConfig;
use crate::ssh::{
    CodexInstallOutcome, RemoteShell, SshAuth, SshBootstrapResult, SshClient, SshCredentials,
    SshError,
};
use crate::store::{
    AppConnectionProgressSnapshot, AppConnectionStepKind, AppConnectionStepState,
    ServerHealthSnapshot,
};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use tokio::sync::oneshot;
use tracing::{debug, info, warn};

const WAKE_MAC_SCRIPT: &str = r#"iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -z "$iface" ]; then iface="en0"; fi
mac="$(ifconfig "$iface" 2>/dev/null | awk '/ether /{print $2; exit}')"
if [ -z "$mac" ]; then
  mac="$(ifconfig en0 2>/dev/null | awk '/ether /{print $2; exit}')"
fi
if [ -z "$mac" ]; then
  mac="$(ifconfig 2>/dev/null | awk '/ether /{print $2; exit}')"
fi
printf '%s' "$mac""#;

#[derive(Clone)]
pub(crate) struct ManagedSshSession {
    pub(crate) client: Arc<SshClient>,
    pub(crate) host: String,
    pub(crate) pid: Option<u32>,
    pub(crate) shell: RemoteShell,
}

// `ManagedSshBootstrapFlow` lives on `MobileClient::ssh_bootstrap_flows` so
// the connect entry point (now on `ServerBridge`) and the install-prompt
// response (on `SshBridge`) can share state across bridges.
pub(crate) use crate::mobile_client::ManagedSshBootstrapFlow;

#[derive(uniffi::Object)]
pub struct SshBridge {
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
    pub(crate) ssh_sessions: Mutex<std::collections::HashMap<String, ManagedSshSession>>,
    pub(crate) next_ssh_session_id: AtomicU64,
}

#[derive(uniffi::Record)]
pub struct AppSshConnectionResult {
    pub session_id: String,
    pub normalized_host: String,
    pub server_port: u16,
    pub tunnel_local_port: Option<u16>,
    pub server_version: Option<String>,
    pub pid: Option<u32>,
    pub wake_mac: Option<String>,
}

#[derive(uniffi::Record)]
pub struct AppSshSessionResult {
    pub session_id: String,
    pub normalized_host: String,
    pub wake_mac: Option<String>,
}

#[derive(uniffi::Record)]
pub struct AppSshBridgeConnectResult {
    pub server_id: String,
    pub agent_name: String,
}

#[uniffi::export(async_runtime = "tokio")]
impl SshBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            rt: shared_runtime(),
            ssh_sessions: Mutex::new(std::collections::HashMap::new()),
            next_ssh_session_id: AtomicU64::new(1),
        }
    }

    pub async fn ssh_connect_and_bootstrap(
        &self,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        unlock_macos_keychain: bool,
        accept_unknown_host: bool,
        working_dir: Option<String>,
    ) -> Result<AppSshConnectionResult, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        info!(
            "SshBridge: ssh_connect_and_bootstrap start host={} normalized_host={} ssh_port={} username={} auth={} working_dir={}",
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

        let rt = Arc::clone(&self.rt);
        let session = tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                SshClient::connect(
                    credentials,
                    Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
                )
                .await
                .map_err(map_ssh_error)
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))??;
        info!(
            "SshBridge: ssh_connect_and_bootstrap connected normalized_host={} ssh_port={}",
            normalized_host.as_str(),
            port
        );

        let session = Arc::new(session);
        let bootstrap = {
            let session = Arc::clone(&session);
            let rt = Arc::clone(&self.rt);
            let working_dir = working_dir.clone();
            let use_ipv6 = normalized_host.contains(':');
            tokio::task::spawn_blocking(move || {
                rt.block_on(async move {
                    session
                        .bootstrap_codex_server(working_dir.as_deref(), use_ipv6)
                        .await
                        .map_err(map_ssh_error)
                })
            })
            .await
            .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?
        };

        let bootstrap = match bootstrap {
            Ok(result) => result,
            Err(error) => {
                warn!(
                    "SshBridge: ssh_connect_and_bootstrap bootstrap failed normalized_host={} ssh_port={} error={}",
                    normalized_host.as_str(),
                    port,
                    error
                );
                let session = Arc::clone(&session);
                let rt = Arc::clone(&self.rt);
                let _ = tokio::task::spawn_blocking(move || {
                    rt.block_on(async move {
                        session.disconnect().await;
                    })
                })
                .await;
                return Err(error);
            }
        };

        let wake_mac = self.ssh_read_wake_mac(Arc::clone(&session)).await;
        let session_id = format!(
            "ssh-{}",
            self.next_ssh_session_id.fetch_add(1, Ordering::Relaxed)
        );
        let shell = {
            let session = Arc::clone(&session);
            let rt = Arc::clone(&self.rt);
            tokio::task::spawn_blocking(move || {
                rt.block_on(async move { session.detect_remote_shell().await })
            })
            .await
            .unwrap_or(RemoteShell::Posix)
        };
        self.ssh_sessions_lock().insert(
            session_id.clone(),
            ManagedSshSession {
                client: Arc::clone(&session),
                host: normalized_host.clone(),
                pid: bootstrap.pid,
                shell,
            },
        );
        info!(
            "SshBridge: ssh_connect_and_bootstrap succeeded normalized_host={} ssh_port={} session_id={} remote_port={} local_tunnel_port={} pid={:?}",
            normalized_host.as_str(),
            port,
            session_id,
            bootstrap.server_port,
            bootstrap.tunnel_local_port,
            bootstrap.pid
        );

        Ok(AppSshConnectionResult {
            session_id,
            normalized_host,
            server_port: bootstrap.server_port,
            tunnel_local_port: Some(bootstrap.tunnel_local_port),
            server_version: bootstrap.server_version,
            pid: bootstrap.pid,
            wake_mac,
        })
    }

    pub async fn ssh_open_session(
        &self,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        unlock_macos_keychain: bool,
        accept_unknown_host: bool,
    ) -> Result<AppSshSessionResult, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
            unlock_macos_keychain,
        };
        let session = Arc::new(
            SshClient::connect(
                credentials,
                Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
            )
            .await
            .map_err(map_ssh_error)?,
        );
        let shell = session.detect_remote_shell().await;
        let wake_mac = self.ssh_read_wake_mac(Arc::clone(&session)).await;
        let session_id = format!(
            "ssh-{}",
            self.next_ssh_session_id.fetch_add(1, Ordering::Relaxed)
        );
        self.ssh_sessions_lock().insert(
            session_id.clone(),
            ManagedSshSession {
                client: Arc::clone(&session),
                host: normalized_host.clone(),
                pid: None,
                shell,
            },
        );
        Ok(AppSshSessionResult {
            session_id,
            normalized_host,
            wake_mac,
        })
    }

    pub async fn ssh_probe_remote_agents(
        &self,
        session_id: String,
    ) -> Result<Vec<crate::ssh_bridge::RemoteAgentAvailability>, ClientError> {
        tracing::info!("SshBridge: probe remote agents start session_id={session_id}");
        let session = self
            .ssh_sessions_lock()
            .get(&session_id)
            .map(|session| Arc::clone(&session.client))
            .ok_or_else(|| {
                ClientError::InvalidParams(format!("unknown SSH session id: {session_id}"))
            })?;
        let availability = crate::ssh_bridge::probe_remote_agents(&session)
            .await
            .map_err(|error| ClientError::Transport(error.to_string()))?;
        tracing::info!(
            "SshBridge: probe remote agents complete session_id={} availability={:?}",
            session_id,
            availability
        );
        Ok(availability)
    }

    pub async fn ssh_connect_bridge_session(
        &self,
        session_id: String,
        server_id: String,
        display_name: String,
        host: String,
        state_root: String,
        runtime_kinds: Vec<crate::types::AgentRuntimeKind>,
        transport: crate::ssh_bridge::SshBridgeTransport,
    ) -> Result<AppSshBridgeConnectResult, ClientError> {
        let managed = self
            .ssh_sessions_lock()
            .get(&session_id)
            .cloned()
            .ok_or_else(|| {
                ClientError::InvalidParams(format!("unknown SSH session id: {session_id}"))
            })?;
        let host = if host.trim().is_empty() {
            managed.host.clone()
        } else {
            normalize_ssh_host(&host)
        };
        tracing::info!(
            "SshBridge: connect bridge session start session_id={} server_id={} host={} runtimes={:?} transport={:?}",
            session_id,
            server_id,
            host,
            runtime_kinds,
            transport
        );
        let mobile_client = shared_mobile_client();
        let outcome = mobile_client
            .connect_remote_over_ssh_bridges(
                Arc::clone(&managed.client),
                server_id,
                display_name,
                host,
                state_root,
                runtime_kinds,
                transport,
            )
            .await
            .map_err(|error| ClientError::Transport(error.to_string()))?;
        tracing::info!(
            "SshBridge: connect bridge session complete session_id={} server_id={} agent_name={}",
            session_id,
            outcome.server_id,
            outcome.agent_name
        );
        Ok(AppSshBridgeConnectResult {
            server_id: outcome.server_id,
            agent_name: outcome.agent_name,
        })
    }

    pub async fn ssh_close(&self, session_id: String) -> Result<(), ClientError> {
        debug!("SshBridge: ssh_close session_id={}", session_id);
        let session = self
            .ssh_sessions_lock()
            .remove(&session_id)
            .ok_or_else(|| {
                ClientError::InvalidParams(format!("unknown SSH session id: {session_id}"))
            })?;
        let rt = Arc::clone(&self.rt);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                if let Some(pid) = session.pid {
                    let kill_cmd = match session.shell {
                        RemoteShell::Posix => format!("kill {pid} 2>/dev/null"),
                        RemoteShell::PowerShell => {
                            format!("Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue")
                        }
                    };
                    let _ = session.client.exec_shell(&kill_cmd, session.shell).await;
                }
                session.client.disconnect().await;
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?;
        debug!("SshBridge: ssh_close completed session_id={}", session_id);
        Ok(())
    }

    pub async fn ssh_respond_to_install_prompt(
        &self,
        server_id: String,
        install: bool,
    ) -> Result<(), ClientError> {
        info!(
            "SshBridge: ssh_respond_to_install_prompt server_id={} install={}",
            server_id, install
        );
        let mobile_client = shared_mobile_client();
        let sender = {
            let mut flows = mobile_client.ssh_bootstrap_flows.lock().await;
            flows
                .get_mut(&server_id)
                .and_then(|flow| flow.install_decision.take())
        }
        .ok_or_else(|| {
            ClientError::InvalidParams(format!("no pending install prompt for {server_id}"))
        })?;

        sender
            .send(install)
            .map_err(|_| ClientError::EventClosed("install prompt already closed".to_string()))
    }
}

pub(crate) fn ssh_auth_kind(auth: &SshAuth) -> &'static str {
    match auth {
        SshAuth::Password(_) => "password",
        SshAuth::PrivateKey { .. } => "private_key",
    }
}

impl SshBridge {
    fn ssh_sessions_lock(
        &self,
    ) -> std::sync::MutexGuard<'_, std::collections::HashMap<String, ManagedSshSession>> {
        match self.ssh_sessions.lock() {
            Ok(guard) => guard,
            Err(error) => {
                tracing::warn!("SshBridge: recovering poisoned ssh_sessions lock");
                error.into_inner()
            }
        }
    }

    pub(crate) async fn ssh_read_wake_mac(&self, session: Arc<SshClient>) -> Option<String> {
        let rt = Arc::clone(&self.rt);
        let result = tokio::task::spawn_blocking(move || {
            rt.block_on(async move { read_wake_mac(session).await })
        })
        .await
        .ok()?;
        result
    }
}

async fn read_wake_mac(session: Arc<SshClient>) -> Option<String> {
    let result = session
        .exec(WAKE_MAC_SCRIPT)
        .await
        .map_err(map_ssh_error)
        .ok()?;
    if result.exit_code != 0 {
        return None;
    }
    normalize_wake_mac(&result.stdout)
}

pub(crate) async fn run_guided_ssh_connect(
    mobile_client: Arc<crate::MobileClient>,
    bootstrap_flows: Arc<
        tokio::sync::Mutex<std::collections::HashMap<String, ManagedSshBootstrapFlow>>,
    >,
    config: ServerConfig,
    credentials: SshCredentials,
    accept_unknown_host: bool,
    working_dir: Option<String>,
    ipc_socket_path_override: Option<String>,
    progress: &mut AppConnectionProgressSnapshot,
) -> Result<(), ClientError> {
    let server_id = config.server_id.clone();
    info!(
        "guided ssh connect start server_id={} host={} ssh_port={} working_dir={} ipc_socket_path_override={}",
        server_id,
        credentials.host.as_str(),
        credentials.port,
        working_dir.as_deref().unwrap_or("<none>"),
        ipc_socket_path_override.as_deref().unwrap_or("<none>")
    );
    let ssh_client = Arc::new(
        SshClient::connect(
            credentials.clone(),
            Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
        )
        .await
        .map_err(map_ssh_error)?,
    );
    info!(
        "guided ssh connect connected to ssh server_id={} host={} ssh_port={}",
        server_id,
        credentials.host.as_str(),
        credentials.port
    );
    let wake_mac_server_id = server_id.clone();
    let wake_mac_store = Arc::clone(&mobile_client.app_store);
    let wake_mac_client = Arc::clone(&ssh_client);
    tokio::spawn(async move {
        if let Some(wake_mac) = read_wake_mac(wake_mac_client).await {
            info!(
                "guided ssh connect discovered wake mac server_id={} wake_mac={}",
                wake_mac_server_id, wake_mac
            );
            wake_mac_store.update_server_wake_mac(&wake_mac_server_id, Some(wake_mac));
        }
    });
    progress.update_step(
        AppConnectionStepKind::ConnectingToSsh,
        AppConnectionStepState::Completed,
        Some(format!("Connected to {}", credentials.host.as_str())),
    );
    progress.update_step(
        AppConnectionStepKind::FindingCodex,
        AppConnectionStepState::InProgress,
        None,
    );
    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, Some(progress.clone()));

    let remote_shell = ssh_client.detect_remote_shell().await;
    info!(
        "guided ssh connect detected shell server_id={} shell={:?}",
        server_id, remote_shell
    );
    let codex_binary = match ssh_client
        .resolve_codex_binary_optional_with_shell(Some(remote_shell))
        .await
        .map_err(map_ssh_error)?
    {
        Some(binary) => {
            info!(
                "guided ssh connect found codex server_id={} path={}",
                server_id,
                binary.path()
            );
            progress.update_step(
                AppConnectionStepKind::FindingCodex,
                AppConnectionStepState::Completed,
                Some(binary.path().to_string()),
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));

            // Best-effort: if this looks like our managed `~/.litter/` install
            // and we haven't checked in 24h, probe for a newer release and
            // swap in the updated binary. Any failure falls through to the
            // already-resolved binary.
            let update_result = ssh_client
                .maybe_update_managed_codex(&binary, remote_shell)
                .await;
            let (effective_binary, install_detail, install_state) = match update_result {
                Some((new_binary, CodexInstallOutcome::Installed)) => {
                    info!(
                        "guided ssh connect auto-updated codex server_id={} path={}",
                        server_id,
                        new_binary.path()
                    );
                    let detail = format!("Updated Codex ({})", new_binary.path());
                    (new_binary, detail, AppConnectionStepState::Completed)
                }
                Some((_, CodexInstallOutcome::AlreadyAtLatestTag)) => (
                    binary,
                    "Already installed (up to date)".to_string(),
                    AppConnectionStepState::Cancelled,
                ),
                None => (
                    binary,
                    "Already installed".to_string(),
                    AppConnectionStepState::Cancelled,
                ),
            };
            progress.update_step(
                AppConnectionStepKind::InstallingCodex,
                install_state,
                Some(install_detail),
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));
            effective_binary
        }
        None => {
            info!(
                "guided ssh connect missing codex server_id={} host={}; awaiting install decision",
                server_id,
                credentials.host.as_str()
            );
            progress.pending_install = true;
            progress.update_step(
                AppConnectionStepKind::FindingCodex,
                AppConnectionStepState::AwaitingUserInput,
                Some("Codex not found on remote host".to_string()),
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));

            let (tx, rx) = oneshot::channel();
            {
                let mut flows = bootstrap_flows.lock().await;
                if let Some(flow) = flows.get_mut(&server_id) {
                    flow.install_decision = Some(tx);
                }
            }

            let should_install = rx.await.unwrap_or(false);
            info!(
                "guided ssh connect install decision server_id={} install={}",
                server_id, should_install
            );
            progress.pending_install = false;
            if !should_install {
                progress.update_step(
                    AppConnectionStepKind::FindingCodex,
                    AppConnectionStepState::Failed,
                    Some("Install declined".to_string()),
                );
                progress.update_step(
                    AppConnectionStepKind::InstallingCodex,
                    AppConnectionStepState::Cancelled,
                    Some("Install declined".to_string()),
                );
                progress.terminal_message = Some("Install declined".to_string());
                mobile_client
                    .app_store
                    .update_server_health(&server_id, ServerHealthSnapshot::Disconnected);
                mobile_client
                    .app_store
                    .update_server_connection_progress(&server_id, Some(progress.clone()));
                ssh_client.disconnect().await;
                return Ok(());
            }

            progress.update_step(
                AppConnectionStepKind::FindingCodex,
                AppConnectionStepState::Completed,
                Some("Installing latest stable release".to_string()),
            );
            progress.update_step(
                AppConnectionStepKind::InstallingCodex,
                AppConnectionStepState::InProgress,
                None,
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));

            let platform = ssh_client
                .detect_remote_platform_with_shell(Some(remote_shell))
                .await
                .map_err(map_ssh_error)?;
            info!(
                "guided ssh connect install platform server_id={} platform={:?}",
                server_id, platform
            );
            let (installed_binary, install_outcome) = ssh_client
                .install_latest_stable_codex(platform)
                .await
                .map_err(map_ssh_error)?;
            info!(
                "guided ssh connect install completed server_id={} path={} outcome={:?}",
                server_id,
                installed_binary.path(),
                install_outcome
            );
            progress.update_step(
                AppConnectionStepKind::InstallingCodex,
                AppConnectionStepState::Completed,
                Some(installed_binary.path().to_string()),
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));
            installed_binary
        }
    };

    progress.update_step(
        AppConnectionStepKind::StartingAppServer,
        AppConnectionStepState::InProgress,
        None,
    );
    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, Some(progress.clone()));

    info!(
        "guided ssh connect bootstrapping app server server_id={} host={}",
        server_id,
        credentials.host.as_str()
    );
    let bootstrap = ssh_client
        .bootstrap_codex_server_with_binary(
            &codex_binary,
            working_dir.as_deref(),
            config.host.contains(':'),
        )
        .await
        .map_err(map_ssh_error)?;
    info!(
        "guided ssh connect bootstrap completed server_id={} remote_port={} local_tunnel_port={} pid={:?}",
        server_id, bootstrap.server_port, bootstrap.tunnel_local_port, bootstrap.pid
    );

    progress.update_step(
        AppConnectionStepKind::StartingAppServer,
        AppConnectionStepState::Completed,
        Some(format!("Remote port {}", bootstrap.server_port)),
    );
    progress.update_step(
        AppConnectionStepKind::OpeningTunnel,
        AppConnectionStepState::Completed,
        Some(format!("127.0.0.1:{}", bootstrap.tunnel_local_port)),
    );
    progress.update_step(
        AppConnectionStepKind::Connected,
        AppConnectionStepState::InProgress,
        None,
    );
    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, Some(progress.clone()));

    let host = credentials.host.clone();
    mobile_client
        .finish_connect_remote_over_ssh(
            config,
            credentials,
            accept_unknown_host,
            ssh_client,
            SshBootstrapResult {
                server_port: bootstrap.server_port,
                tunnel_local_port: bootstrap.tunnel_local_port,
                server_version: bootstrap.server_version,
                pid: bootstrap.pid,
            },
            working_dir,
            ipc_socket_path_override,
        )
        .await
        .map_err(|error| ClientError::Transport(error.to_string()))?;
    info!(
        "guided ssh connect attached remote session server_id={} host={}",
        server_id,
        host.as_str()
    );

    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, None);
    Ok(())
}

pub(crate) fn mark_progress_failure(progress: &mut AppConnectionProgressSnapshot, message: String) {
    if let Some(step) = progress.steps.iter_mut().find(|step| {
        matches!(
            step.state,
            AppConnectionStepState::InProgress | AppConnectionStepState::AwaitingUserInput
        )
    }) {
        step.state = AppConnectionStepState::Failed;
        step.detail = Some(message.clone());
    } else if let Some(step) = progress.steps.last_mut() {
        step.state = AppConnectionStepState::Failed;
        step.detail = Some(message.clone());
    }
    progress.pending_install = false;
    progress.terminal_message = Some(message);
}

pub(crate) fn map_ssh_error(error: SshError) -> ClientError {
    match error {
        SshError::ConnectionFailed(message)
        | SshError::AuthFailed(message)
        | SshError::PortForwardFailed(message)
        | SshError::ExecFailed {
            stderr: message, ..
        } => ClientError::Transport(message),
        SshError::HostKeyVerification { fingerprint } => {
            ClientError::Transport(format!("host key verification failed: {fingerprint}"))
        }
        SshError::Timeout => ClientError::Transport("SSH operation timed out".into()),
        SshError::Disconnected => ClientError::Transport("SSH session disconnected".into()),
    }
}

pub(crate) fn ssh_auth(
    password: Option<String>,
    private_key_pem: Option<String>,
    passphrase: Option<String>,
) -> Result<SshAuth, ClientError> {
    match (password, private_key_pem) {
        (Some(password), None) => Ok(SshAuth::Password(password)),
        (None, Some(key_pem)) => Ok(SshAuth::PrivateKey {
            key_pem,
            passphrase,
        }),
        (None, None) => Err(ClientError::InvalidParams(
            "missing SSH credential: provide either password or private key".into(),
        )),
        (Some(_), Some(_)) => Err(ClientError::InvalidParams(
            "ambiguous SSH credentials: provide either password or private key, not both".into(),
        )),
    }
}

pub(crate) fn normalize_ssh_host(host: &str) -> String {
    let mut normalized = host.trim().trim_matches(['[', ']']).replace("%25", "%");
    if !normalized.contains(':') {
        if let Some((base, _scope)) = normalized.split_once('%') {
            normalized = base.to_string();
        }
    }
    normalized
}

fn normalize_wake_mac(raw: &str) -> Option<String> {
    let compact = raw
        .trim()
        .replace(':', "")
        .replace('-', "")
        .to_ascii_lowercase();
    if compact.len() != 12 || !compact.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }

    let mut chunks = Vec::with_capacity(6);
    for index in (0..12).step_by(2) {
        chunks.push(compact[index..index + 2].to_string());
    }
    Some(chunks.join(":"))
}
