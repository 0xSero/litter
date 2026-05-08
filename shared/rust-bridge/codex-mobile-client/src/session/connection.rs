//! `ServerSession` state machine for connection lifecycle management.
//!
//! Manages connection health, retry logic, auth flow, sandbox fallback,
//! and initialize handshake for a single Codex server.
//!
//! Uses upstream `RemoteAppServerClient` for remote connections and
//! upstream `InProcessClientHandle` for local (in-process) connections.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant};

use codex_app_server_client::{
    AppServerClient, AppServerEvent, RemoteAppServerClient, RemoteAppServerConnectArgs,
};
use codex_app_server_protocol::{
    ClientNotification, ClientRequest, JSONRPCErrorError, RequestId, Result as JsonRpcResult,
    ServerNotification, ServerRequest,
};
use codex_ipc::{IpcClient, ReconnectingIpcClient, TypedBroadcast};
use serde_json::Value as JsonValue;
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tracing::{debug, info, warn};

use crate::logging::{LogLevelName, log_rust};
use crate::session::remote_transport::{Reconnected, RemoteTransport};
use crate::ssh::{SshBootstrapResult, SshClient};
use crate::transport::{RpcError, TransportError};
use crate::types::AgentRuntimeKind;

const REMOTE_RECONNECT_MAX_ATTEMPTS: u32 = 5;
const REMOTE_RECONNECT_DELAY: Duration = Duration::from_secs(1);

#[derive(Clone)]
pub(crate) struct SshReconnectTransport {
    pub(crate) ssh_client: Arc<SshClient>,
    pub(crate) local_port: u16,
    pub(crate) remote_port: Arc<StdMutex<u16>>,
    pub(crate) prefer_ipv6: bool,
    pub(crate) working_dir: Option<String>,
    pub(crate) ssh_pid: Option<Arc<StdMutex<Option<u32>>>>,
}

fn append_android_debug_log(line: &str) {
    log_rust(
        LogLevelName::Debug,
        "session.connection",
        "bridge",
        line.to_string(),
        None,
    );
}

// ---------------------------------------------------------------------------
// InProcessConfig
// ---------------------------------------------------------------------------

/// Configuration for starting an in-process Codex transport.
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct InProcessConfig {
    /// Override the Codex home directory.
    pub codex_home: Option<PathBuf>,
    /// Override the working directory for Codex operations.
    pub working_directory: Option<PathBuf>,
    /// Capacity for internal event/command channels. Defaults to 256.
    pub channel_capacity: usize,
}

impl Default for InProcessConfig {
    fn default() -> Self {
        Self {
            codex_home: None,
            working_directory: None,
            channel_capacity: 256,
        }
    }
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
static IOS_CACERT_PEM: &[u8] = include_bytes!("../../../codex-bridge/src/cacert.pem");

#[allow(unused_mut)]
fn prepare_in_process_config(
    mut config: InProcessConfig,
) -> Result<InProcessConfig, TransportError> {
    #[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
    {
        config = prepare_ios_in_process_config(config)?;
    }

    #[cfg(target_os = "android")]
    {
        config = prepare_android_in_process_config(config)?;
    }

    Ok(config)
}

#[cfg(target_os = "android")]
fn prepare_android_in_process_config(
    mut config: InProcessConfig,
) -> Result<InProcessConfig, TransportError> {
    // On Android, HOME and CODEX_HOME should already be set by UniffiInit.nativeBridgeInit().
    // If codex_home is not set in the config, resolve from CODEX_HOME env var.
    if config.codex_home.is_none() {
        if let Ok(codex_home) = std::env::var("CODEX_HOME") {
            let path = PathBuf::from(&codex_home);
            std::fs::create_dir_all(&path).map_err(|e| {
                TransportError::ConnectionFailed(format!(
                    "failed to create CODEX_HOME {:?}: {e}",
                    path
                ))
            })?;
            config.codex_home = Some(path);
        } else if let Ok(home) = std::env::var("HOME") {
            let path = PathBuf::from(home).join(".codex");
            std::fs::create_dir_all(&path).map_err(|e| {
                TransportError::ConnectionFailed(format!(
                    "failed to create codex home {:?}: {e}",
                    path
                ))
            })?;
            unsafe {
                std::env::set_var("CODEX_HOME", &path);
            }
            config.codex_home = Some(path);
        } else {
            return Err(TransportError::ConnectionFailed(
                "Could not find home directory".to_string(),
            ));
        }
    }

    if config.working_directory.is_none() {
        if let Some(ref codex_home) = config.codex_home {
            let wd = codex_home.join("workspace");
            std::fs::create_dir_all(&wd).map_err(|e| {
                TransportError::ConnectionFailed(format!(
                    "failed to create workspace {:?}: {e}",
                    wd
                ))
            })?;
            config.working_directory = Some(wd);
        }
    }

    // Set up TLS root certificates for Android
    if let Some(ref codex_home) = config.codex_home {
        // Android uses system CAs, but set SSL_CERT_FILE if a bundle exists
        let pem_path = codex_home.join("cacert.pem");
        if pem_path.exists() {
            unsafe {
                std::env::set_var("SSL_CERT_FILE", &pem_path);
            }
        }
    }

    Ok(config)
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
#[cfg_attr(test, allow(dead_code))]
fn prepare_ios_in_process_config(
    mut config: InProcessConfig,
) -> Result<InProcessConfig, TransportError> {
    let home_dir = std::env::var_os("HOME").map(PathBuf::from);
    let docs_root = home_dir.as_ref().map(|home| home.join("Documents"));

    if let Some(root) = &docs_root {
        for relative in ["home/codex", "tmp", "var/log", "etc"] {
            std::fs::create_dir_all(root.join(relative)).map_err(|e| {
                TransportError::ConnectionFailed(format!(
                    "failed to create local sandbox directory {:?}: {e}",
                    root.join(relative)
                ))
            })?;
        }
    }

    if config.working_directory.is_none()
        && let Some(root) = &docs_root
    {
        config.working_directory = Some(root.join("home").join("codex"));
    }

    if let Some(ref working_directory) = config.working_directory {
        std::fs::create_dir_all(working_directory).map_err(|e| {
            TransportError::ConnectionFailed(format!(
                "failed to create local working directory {:?}: {e}",
                working_directory
            ))
        })?;
        unsafe {
            std::env::set_var("SSH_HOME", working_directory);
            std::env::set_var("CURL_HOME", working_directory);
        }
    }

    if config.codex_home.is_none() {
        config.codex_home = Some(resolve_ios_codex_home(&home_dir)?);
    }

    if let Some(ref codex_home) = config.codex_home {
        config.codex_home = Some(prepare_ios_runtime_environment(codex_home)?);
    }

    Ok(config)
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
#[cfg_attr(test, allow(dead_code))]
fn resolve_ios_codex_home(home_dir: &Option<PathBuf>) -> Result<PathBuf, TransportError> {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Ok(existing) = std::env::var("CODEX_HOME")
        && !existing.is_empty()
    {
        candidates.push(PathBuf::from(existing));
    }

    if let Some(home) = home_dir {
        candidates.push(
            home.join("Library")
                .join("Application Support")
                .join("codex"),
        );
        candidates.push(home.join("Documents").join(".codex"));
        candidates.push(home.join(".codex"));
    }

    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        candidates.push(PathBuf::from(tmpdir).join("codex-home"));
    }

    for candidate in candidates {
        match std::fs::create_dir_all(&candidate) {
            Ok(()) => return Ok(candidate),
            Err(err) => {
                warn!(
                    "failed to create CODEX_HOME candidate {:?}: {err}",
                    candidate
                );
            }
        }
    }

    Err(TransportError::ConnectionFailed(
        "unable to initialize any writable CODEX_HOME location".to_string(),
    ))
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
fn prepare_ios_runtime_environment(
    codex_home: &std::path::Path,
) -> Result<PathBuf, TransportError> {
    std::fs::create_dir_all(codex_home).map_err(|e| {
        TransportError::ConnectionFailed(format!(
            "failed to create CODEX_HOME {:?}: {e}",
            codex_home
        ))
    })?;

    let canonical = codex_home
        .canonicalize()
        .unwrap_or_else(|_| codex_home.to_path_buf());
    unsafe {
        std::env::set_var("CODEX_HOME", &canonical);
    }
    init_ios_tls_roots(&canonical)?;

    Ok(canonical)
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
fn init_ios_tls_roots(codex_home: &std::path::Path) -> Result<(), TransportError> {
    if let Some(existing) = std::env::var_os("SSL_CERT_FILE") {
        let existing_path = std::path::PathBuf::from(existing);
        if existing_path.is_file() {
            return Ok(());
        }
        warn!(
            "replacing stale SSL_CERT_FILE {:?} with a regenerated local bundle",
            existing_path
        );
    }

    let pem_path = codex_home.join("cacert.pem");
    if !pem_path.exists() {
        std::fs::write(&pem_path, IOS_CACERT_PEM).map_err(|e| {
            TransportError::ConnectionFailed(format!(
                "failed to write local TLS roots {:?}: {e}",
                pem_path
            ))
        })?;
    }

    unsafe {
        std::env::set_var("SSL_CERT_FILE", &pem_path);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// ServerConfig
// ---------------------------------------------------------------------------

/// Configuration describing a Codex server endpoint.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerConfig {
    /// Unique identifier for this server.
    pub server_id: String,
    /// Human-readable name shown in the UI.
    pub display_name: String,
    /// Hostname or IP address.
    pub host: String,
    /// TCP port.
    pub port: u16,
    /// Explicit WebSocket URL override for remote connections.
    pub websocket_url: Option<String>,
    /// Whether this is a local (in-process) server.
    pub is_local: bool,
    /// Whether to use TLS for the WebSocket connection.
    pub tls: bool,
}

/// Session-wide bookkeeping passed to `connect_remote_multiplexed`.
///
/// These fields back side-channels (IPC streams, SSH client retained for log
/// commands and disconnect cleanup) that live on `ServerSession` for the
/// lifetime of the session. They are independent of any single runtime's RPC
/// transport — that's described per-runtime by `RuntimeRemoteSessionResource`.
#[derive(Default)]
pub struct RemoteSessionExtras {
    pub ssh_client: Option<Arc<SshClient>>,
    pub ssh_pid: Option<Arc<StdMutex<Option<u32>>>>,
    pub ipc_stream_client: Option<Arc<ReconnectingIpcClient>>,
    pub ipc_ssh_client: Option<Arc<SshClient>>,
    pub ipc_stream_bridge_pid: Option<Arc<StdMutex<Option<u32>>>>,
}

pub struct RuntimeRemoteSessionResource {
    pub runtime_kind: AgentRuntimeKind,
    pub client: AppServerClient,
    pub(crate) transport: Option<Arc<dyn RemoteTransport>>,
    pub(crate) keepalive: Option<Arc<dyn Send + Sync>>,
}

// ---------------------------------------------------------------------------
// ConnectionHealth
// ---------------------------------------------------------------------------

/// Observable health state of the connection to a server.
#[derive(Debug, Clone)]
pub enum ConnectionHealth {
    Disconnected,
    Connecting { attempt: u32, max_attempts: u32 },
    Connected,
    Unresponsive { since: Instant },
}

impl PartialEq for ConnectionHealth {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Disconnected, Self::Disconnected) => true,
            (
                Self::Connecting {
                    attempt: a1,
                    max_attempts: m1,
                },
                Self::Connecting {
                    attempt: a2,
                    max_attempts: m2,
                },
            ) => a1 == a2 && m1 == m2,
            (Self::Connected, Self::Connected) => true,
            (Self::Unresponsive { since: s1 }, Self::Unresponsive { since: s2 }) => s1 == s2,
            _ => false,
        }
    }
}

// ---------------------------------------------------------------------------
// Internal command type for the worker task
// ---------------------------------------------------------------------------

enum SessionCommand {
    Request {
        request: ClientRequest,
        response_tx: oneshot::Sender<Result<JsonValue, RpcError>>,
    },
    Notify {
        notification: ClientNotification,
        response_tx: oneshot::Sender<Result<(), RpcError>>,
    },
    Resolve {
        request_id: RequestId,
        result: JsonRpcResult,
        response_tx: oneshot::Sender<Result<(), RpcError>>,
    },
    Reject {
        request_id: RequestId,
        error: JSONRPCErrorError,
        response_tx: oneshot::Sender<Result<(), RpcError>>,
    },
    Shutdown,
}

// ---------------------------------------------------------------------------
// ServerSession
// ---------------------------------------------------------------------------

/// Typed event from the server: either a typed notification, a legacy notification,
/// or a typed server request.
#[derive(Debug, Clone)]
pub enum ServerEvent {
    Notification {
        runtime_kind: AgentRuntimeKind,
        notification: ServerNotification,
    },
    LegacyNotification {
        runtime_kind: AgentRuntimeKind,
        method: String,
        params: JsonValue,
    },
    Request {
        runtime_kind: AgentRuntimeKind,
        request: ServerRequest,
    },
}

/// Manages the full connection lifecycle to a single Codex server.
///
/// Wraps the upstream `AppServerClient` (both in-process and remote variants)
/// behind a worker task that owns the client and multiplexes between command
/// dispatch and event consumption.
pub struct ServerSession {
    config: ServerConfig,
    health_tx: watch::Sender<ConnectionHealth>,
    health_rx: watch::Receiver<ConnectionHealth>,
    command_tx: mpsc::Sender<SessionCommand>,
    runtime_command_txs: std::collections::HashMap<AgentRuntimeKind, mpsc::Sender<SessionCommand>>,
    event_tx: broadcast::Sender<ServerEvent>,
    ipc_stream_client: Option<Arc<ReconnectingIpcClient>>,
    ssh_client: Option<Arc<SshClient>>,
    ssh_pid: Option<Arc<StdMutex<Option<u32>>>>,
    ipc_ssh_client: Option<Arc<SshClient>>,
    ipc_stream_bridge_pid: Option<Arc<StdMutex<Option<u32>>>>,
    worker_handle: tokio::task::JoinHandle<()>,
}

#[cfg(test)]
pub(crate) type TestRequestHandler =
    Arc<dyn Fn(ClientRequest) -> Result<JsonValue, RpcError> + Send + Sync>;
#[cfg(test)]
pub(crate) type TestResolveHandler =
    Arc<dyn Fn(RequestId, JsonRpcResult) -> Result<(), RpcError> + Send + Sync>;
#[cfg(test)]
pub(crate) type TestRejectHandler =
    Arc<dyn Fn(RequestId, JSONRPCErrorError) -> Result<(), RpcError> + Send + Sync>;

#[cfg(test)]
fn spawn_test_command_worker(
    request_handler: Option<TestRequestHandler>,
    resolve_handler: Option<TestResolveHandler>,
    reject_handler: Option<TestRejectHandler>,
) -> (mpsc::Sender<SessionCommand>, tokio::task::JoinHandle<()>) {
    let (command_tx, mut command_rx) = mpsc::channel(16);
    let worker_handle = tokio::spawn(async move {
        while let Some(command) = command_rx.recv().await {
            match command {
                SessionCommand::Request {
                    request,
                    response_tx,
                } => {
                    let result = request_handler
                        .as_ref()
                        .map(|handler| handler(request))
                        .unwrap_or_else(|| Err(RpcError::Transport(TransportError::Disconnected)));
                    let _ = response_tx.send(result);
                }
                SessionCommand::Notify { response_tx, .. } => {
                    let _ = response_tx.send(Ok(()));
                }
                SessionCommand::Resolve {
                    request_id,
                    result,
                    response_tx,
                } => {
                    let outcome = resolve_handler
                        .as_ref()
                        .map(|handler| handler(request_id, result))
                        .unwrap_or(Ok(()));
                    let _ = response_tx.send(outcome);
                }
                SessionCommand::Reject {
                    request_id,
                    error,
                    response_tx,
                } => {
                    let outcome = reject_handler
                        .as_ref()
                        .map(|handler| handler(request_id, error))
                        .unwrap_or(Ok(()));
                    let _ = response_tx.send(outcome);
                }
                SessionCommand::Shutdown => break,
            }
        }
    });
    (command_tx, worker_handle)
}

impl ServerSession {
    /// Connect to a local (in-process) Codex server.
    pub async fn connect_local(
        config: ServerConfig,
        in_process: InProcessConfig,
    ) -> Result<Self, TransportError> {
        use codex_app_server::in_process::InProcessStartArgs;
        use codex_app_server_protocol::{ClientInfo, InitializeCapabilities, InitializeParams};
        use codex_arg0::Arg0DispatchPaths;
        use codex_cloud_requirements::cloud_requirements_loader;
        use codex_config::LoaderOverrides;
        use codex_core::config::ConfigBuilder;
        use codex_feedback::CodexFeedback;
        use codex_login::AuthManager;
        use codex_protocol::protocol::SessionSource;

        let (health_tx, health_rx) = watch::channel(ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 1,
        });

        let in_process = prepare_in_process_config(in_process)?;

        // Apply codex_home override if provided.
        if let Some(ref codex_home) = in_process.codex_home {
            if let Err(e) = std::fs::create_dir_all(codex_home) {
                return Err(TransportError::ConnectionFailed(format!(
                    "failed to create codex_home {:?}: {e}",
                    codex_home
                )));
            }
            unsafe {
                std::env::set_var("CODEX_HOME", codex_home);
            }
        }

        if let Some(ref working_dir) = in_process.working_directory {
            if let Err(e) = std::env::set_current_dir(working_dir) {
                return Err(TransportError::ConnectionFailed(format!(
                    "failed to set working directory {:?}: {e}",
                    working_dir
                )));
            }
        }

        let cli_overrides = vec![
            ("features.realtime_conversation".to_string(), true.into()),
            (
                "experimental_realtime_ws_model".to_string(),
                "gpt-realtime-1.5".to_string().into(),
            ),
            ("realtime.version".to_string(), "v2".to_string().into()),
            (
                "realtime.type".to_string(),
                "conversational".to_string().into(),
            ),
        ];

        let mut base_builder = ConfigBuilder::default().cli_overrides(cli_overrides.clone());
        if let Some(ref codex_home) = in_process.codex_home {
            base_builder = base_builder.codex_home(codex_home.clone());
        }
        if let Some(ref working_dir) = in_process.working_directory {
            base_builder = base_builder.fallback_cwd(Some(working_dir.clone()));
        }

        let base_config = base_builder
            .build()
            .await
            .map_err(|e| TransportError::ConnectionFailed(format!("config build failed: {e}")))?;

        let auth_manager = AuthManager::shared(
            base_config.codex_home.to_path_buf(),
            false,
            base_config.cli_auth_credentials_store_mode,
            Some(base_config.chatgpt_base_url.clone()),
        )
        .await;

        let cloud_requirements = cloud_requirements_loader(
            auth_manager.clone(),
            base_config.chatgpt_base_url.clone(),
            base_config.codex_home.to_path_buf(),
        );

        let mut resolved_builder = ConfigBuilder::default()
            .cli_overrides(cli_overrides.clone())
            .cloud_requirements(cloud_requirements.clone());
        if let Some(ref codex_home) = in_process.codex_home {
            resolved_builder = resolved_builder.codex_home(codex_home.clone());
        }
        if let Some(ref working_dir) = in_process.working_directory {
            resolved_builder = resolved_builder.fallback_cwd(Some(working_dir.clone()));
        }

        let resolved_config = resolved_builder.build().await.unwrap_or(base_config);

        let feedback = CodexFeedback::new();
        let session_source = SessionSource::VSCode;

        let args = InProcessStartArgs {
            arg0_paths: Arg0DispatchPaths::default(),
            config: Arc::new(resolved_config),
            cli_overrides,
            loader_overrides: LoaderOverrides::default(),
            cloud_requirements,
            feedback,
            log_db: None,
            state_db: None,
            thread_config_loader: Arc::new(codex_config::NoopThreadConfigLoader),
            environment_manager: Arc::new(
                codex_exec_server::EnvironmentManager::default_for_tests(),
            ),
            config_warnings: Vec::new(),
            session_source,
            enable_codex_api_key_env: true,
            initialize: InitializeParams {
                client_info: ClientInfo {
                    name: "Litter".to_string(),
                    version: "1.0".to_string(),
                    title: None,
                },
                capabilities: Some(InitializeCapabilities {
                    experimental_api: true,
                    opt_out_notification_methods: None,
                }),
            },
            channel_capacity: in_process.channel_capacity,
        };

        let mut handle = codex_app_server::in_process::start(args)
            .await
            .map_err(|e| {
                TransportError::ConnectionFailed(format!("in-process start failed: {e}"))
            })?;

        let sender = handle.sender();
        let (event_tx, _) = broadcast::channel::<ServerEvent>(256);
        let (command_tx, mut command_rx) = mpsc::channel::<SessionCommand>(256);

        let evt_tx = event_tx.clone();

        let worker_handle = tokio::spawn(async move {
            loop {
                tokio::select! {
                    command = command_rx.recv() => {
                        let Some(command) = command else { break; };
                        match command {
                            SessionCommand::Request { request, response_tx } => {
                                let sender = sender.clone();
                                tokio::spawn(async move {
                                    let result = match sender.request(request).await {
                                        Ok(Ok(value)) => Ok(value),
                                        Ok(Err(error)) => Err(RpcError::Server {
                                            code: error.code,
                                            message: error.message,
                                        }),
                                        Err(e) => Err(RpcError::Transport(
                                            TransportError::SendFailed(e.to_string()),
                                        )),
                                    };
                                    let _ = response_tx.send(result);
                                });
                            }
                            SessionCommand::Notify { notification, response_tx } => {
                                let result = sender
                                    .notify(notification)
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(result);
                            }
                            SessionCommand::Resolve { request_id, result, response_tx } => {
                                let res = sender
                                    .respond_to_server_request(request_id, result)
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(res);
                            }
                            SessionCommand::Reject { request_id, error, response_tx } => {
                                let res = sender
                                    .fail_server_request(request_id, error)
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(res);
                            }
                            SessionCommand::Shutdown => {
                                break;
                            }
                        }
                    }
                    event = handle.next_event() => {
                        let Some(event) = event else { break; };
                        route_in_process_event(&evt_tx, event);
                    }
                }
            }
            debug!("in-process session worker exited");
        });

        let _ = health_tx.send(ConnectionHealth::Connected);
        info!("local server session connected: {}", config.display_name);

        Ok(Self {
            config,
            health_tx,
            health_rx,
            command_tx,
            runtime_command_txs: std::collections::HashMap::new(),
            event_tx,
            ipc_stream_client: None,
            ssh_client: None,
            ssh_pid: None,
            ipc_ssh_client: None,
            ipc_stream_bridge_pid: None,
            worker_handle,
        })
    }

    /// Connect to a remote Codex server via plain WebSocket.
    ///
    /// Uses the upstream `RemoteAppServerClient` which handles the
    /// initialize/initialized handshake, request routing, and event streaming.
    pub async fn connect_remote(config: ServerConfig) -> Result<Self, TransportError> {
        let (_, args) = remote_connect_args(&config);
        let client = connect_remote_client(&args).await?;
        let resource = RuntimeRemoteSessionResource {
            runtime_kind: AgentRuntimeKind::Codex,
            client,
            transport: None,
            keepalive: None,
        };
        Self::connect_remote_multiplexed(config, vec![resource], RemoteSessionExtras::default())
            .await
    }

    pub async fn connect_remote_multiplexed(
        config: ServerConfig,
        resources: Vec<RuntimeRemoteSessionResource>,
        extras: RemoteSessionExtras,
    ) -> Result<Self, TransportError> {
        let requested_runtime_kinds = resources
            .iter()
            .map(|resource| resource.runtime_kind)
            .collect::<Vec<_>>();
        let first_runtime_kind = resources
            .first()
            .map(|resource| resource.runtime_kind)
            .ok_or_else(|| {
                TransportError::ConnectionFailed("no runtime streams available".to_string())
            })?;
        let (health_tx, health_rx) = watch::channel(ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: REMOTE_RECONNECT_MAX_ATTEMPTS,
        });
        let (url, args) = remote_connect_args(&config);
        let (event_tx, _) = broadcast::channel::<ServerEvent>(256);
        let mut runtime_command_txs = std::collections::HashMap::new();
        let mut worker_handles = Vec::new();
        let mut primary_tx = None;

        for resource in resources {
            info!(
                "multiplexed remote runtime worker start server_id={} runtime={:?}",
                config.server_id, resource.runtime_kind
            );
            let (command_tx, command_rx) = mpsc::channel::<SessionCommand>(256);
            if primary_tx.is_none() || resource.runtime_kind == first_runtime_kind {
                primary_tx = Some(command_tx.clone());
            }
            runtime_command_txs.insert(resource.runtime_kind, command_tx);
            worker_handles.push(spawn_remote_runtime_worker(
                resource.runtime_kind,
                resource.client,
                resource.keepalive,
                command_rx,
                event_tx.clone(),
                health_tx.clone(),
                args.clone(),
                url.clone(),
                resource.transport,
            ));
        }

        let command_tx = primary_tx.ok_or_else(|| {
            TransportError::ConnectionFailed("no runtime command channel available".to_string())
        })?;
        let worker_handle = tokio::spawn(async move {
            for handle in worker_handles {
                let _ = handle.await;
            }
        });

        let _ = health_tx.send(ConnectionHealth::Connected);
        info!(
            "multiplexed remote server session connected: {} ({}) runtimes={:?}",
            config.display_name, url, requested_runtime_kinds
        );

        Ok(Self {
            config,
            health_tx,
            health_rx,
            command_tx,
            runtime_command_txs,
            event_tx,
            ipc_stream_client: extras.ipc_stream_client,
            ssh_client: extras.ssh_client,
            ssh_pid: extras.ssh_pid,
            ipc_ssh_client: extras.ipc_ssh_client,
            ipc_stream_bridge_pid: extras.ipc_stream_bridge_pid,
            worker_handle,
        })
    }

    /// Get the server configuration.
    pub fn config(&self) -> &ServerConfig {
        &self.config
    }

    pub fn ssh_client(&self) -> Option<Arc<SshClient>> {
        self.ssh_client.clone()
    }

    /// Get a watch receiver for health state changes.
    pub fn health(&self) -> watch::Receiver<ConnectionHealth> {
        self.health_rx.clone()
    }

    pub fn runtime_kinds(&self) -> Vec<AgentRuntimeKind> {
        if self.runtime_command_txs.is_empty() {
            return vec![AgentRuntimeKind::Codex];
        }
        let mut kinds = self.runtime_command_txs.keys().copied().collect::<Vec<_>>();
        kinds.sort();
        kinds
    }

    /// Send a typed `ClientRequest` and await the raw JSON response.
    pub async fn request_client(&self, request: ClientRequest) -> Result<JsonValue, RpcError> {
        self.request_client_for_runtime(AgentRuntimeKind::Codex, request)
            .await
    }

    pub async fn request_client_for_runtime(
        &self,
        runtime_kind: AgentRuntimeKind,
        request: ClientRequest,
    ) -> Result<JsonValue, RpcError> {
        let wire_method = serde_json::to_value(&request)
            .ok()
            .and_then(|value| {
                value
                    .get("method")
                    .and_then(|method| method.as_str().map(str::to_string))
            })
            .unwrap_or_else(|| "<unknown>".to_string());
        let (response_tx, response_rx) = oneshot::channel();
        let command_tx = self
            .runtime_command_txs
            .get(&runtime_kind)
            .unwrap_or(&self.command_tx);
        debug!(
            "session request route server_id={} runtime={:?} method={}",
            self.config.server_id, runtime_kind, wire_method
        );
        command_tx
            .send(SessionCommand::Request {
                request,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Send a JSON-RPC request (constructed from method + params) and await the response.
    pub async fn request(&self, method: &str, params: JsonValue) -> Result<JsonValue, RpcError> {
        let request_id = RequestId::Integer(next_request_id());
        let request_value = serde_json::json!({
            "id": request_id,
            "method": method,
            "params": params,
        });
        let request: ClientRequest = serde_json::from_value(request_value)
            .map_err(|e| RpcError::Deserialization(format!("failed to build request: {e}")))?;
        self.request_client(request).await
    }

    /// Send a method/params request to a specific runtime. Used by callers
    /// that need to reach a non-Codex runtime (e.g. an Alleycat-hosted Pi or
    /// Opencode tunnel). Falls back to the default channel when the
    /// `runtime_kind` is not registered for this session.
    pub async fn request_for_runtime(
        &self,
        runtime_kind: AgentRuntimeKind,
        method: &str,
        params: JsonValue,
    ) -> Result<JsonValue, RpcError> {
        let request_id = RequestId::Integer(next_request_id());
        let request_value = serde_json::json!({
            "id": request_id,
            "method": method,
            "params": params,
        });
        let request: ClientRequest = serde_json::from_value(request_value)
            .map_err(|e| RpcError::Deserialization(format!("failed to build request: {e}")))?;
        self.request_client_for_runtime(runtime_kind, request).await
    }

    /// Send a JSON-RPC notification (fire-and-forget).
    pub async fn notify(&self, method: &str, params: JsonValue) -> Result<(), RpcError> {
        let notif_value = serde_json::json!({
            "method": method,
            "params": params,
        });
        let notification: ClientNotification = serde_json::from_value(notif_value)
            .map_err(|e| RpcError::Deserialization(format!("failed to build notification: {e}")))?;

        let (response_tx, response_rx) = oneshot::channel();
        self.command_tx
            .send(SessionCommand::Notify {
                notification,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Subscribe to typed server events (notifications, legacy notifications, requests).
    pub fn events(&self) -> broadcast::Receiver<ServerEvent> {
        self.event_tx.subscribe()
    }

    pub fn has_ipc(&self) -> bool {
        self.ipc_stream_client
            .as_ref()
            .is_some_and(|client| client.is_connected())
    }

    pub fn ipc_stream_client(&self) -> Option<IpcClient> {
        self.ipc_stream_client
            .as_ref()
            .and_then(|client| client.client())
    }

    pub fn ipc_broadcasts(&self) -> Option<broadcast::Receiver<TypedBroadcast>> {
        self.ipc_stream_client
            .as_ref()
            .map(|client| client.subscribe_broadcasts())
    }

    pub fn ipc_connection_state(&self) -> Option<watch::Receiver<bool>> {
        self.ipc_stream_client
            .as_ref()
            .map(|client| client.subscribe_connection_state())
    }

    pub fn invalidate_ipc(&self) {
        if let Some(ipc_client) = self.ipc_stream_client.as_ref() {
            ipc_client.invalidate();
        }
    }

    /// Respond to a server-initiated request.
    pub async fn respond(&self, id: JsonValue, result: JsonValue) -> Result<(), RpcError> {
        self.respond_for_runtime(AgentRuntimeKind::Codex, id, result)
            .await
    }

    pub async fn respond_for_runtime(
        &self,
        runtime_kind: AgentRuntimeKind,
        id: JsonValue,
        result: JsonValue,
    ) -> Result<(), RpcError> {
        let request_id = json_value_to_request_id(&id)?;
        let (response_tx, response_rx) = oneshot::channel();
        let command_tx = self
            .runtime_command_txs
            .get(&runtime_kind)
            .unwrap_or(&self.command_tx);
        command_tx
            .send(SessionCommand::Resolve {
                request_id,
                result,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Reject a server-initiated request with a JSON-RPC error.
    pub async fn reject(&self, id: JsonValue, error: JSONRPCErrorError) -> Result<(), RpcError> {
        let request_id = json_value_to_request_id(&id)?;
        let (response_tx, response_rx) = oneshot::channel();
        self.command_tx
            .send(SessionCommand::Reject {
                request_id,
                error,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Disconnect from the server, shutting down all background tasks.
    pub async fn disconnect(&self) {
        self.disconnect_inner(false).await;
    }

    /// Disconnect and force-stop the remote app-server listener even when
    /// this session reused an existing process whose PID was not tracked.
    pub async fn restart_app_server_and_disconnect(&self) {
        self.disconnect_inner(true).await;
    }

    async fn disconnect_inner(&self, kill_reused_app_server: bool) {
        let _ = self.health_tx.send(ConnectionHealth::Disconnected);
        let _ = self.command_tx.send(SessionCommand::Shutdown).await;
        for tx in self.runtime_command_txs.values() {
            let _ = tx.send(SessionCommand::Shutdown).await;
        }
        if let Some(ipc_client) = self.ipc_stream_client.as_ref() {
            ipc_client.shutdown().await;
        }
        if let Some(ipc_ssh_client) = self.ipc_ssh_client.as_ref() {
            ipc_ssh_client.disconnect().await;
        }
        if let Some(ssh_client) = self.ssh_client.as_ref() {
            if let Some(ipc_bridge_pid) = self.ipc_stream_bridge_pid.as_ref() {
                let pid = match ipc_bridge_pid.lock() {
                    Ok(mut guard) => guard.take(),
                    Err(error) => {
                        warn!("ServerSession: recovering poisoned ipc_stream_bridge_pid lock");
                        error.into_inner().take()
                    }
                };
                if let Some(pid) = pid {
                    let _ = ssh_client.exec(&format!("kill {pid} 2>/dev/null")).await;
                }
            }
            if let Some(pid) = self.ssh_pid.as_ref() {
                let pid = match pid.lock() {
                    Ok(mut guard) => guard.take(),
                    Err(error) => {
                        warn!("ServerSession: recovering poisoned ssh_pid lock");
                        error.into_inner().take()
                    }
                };
                if let Some(pid) = pid {
                    let _ = ssh_client.exec(&format!("kill {pid} 2>/dev/null")).await;
                }
            }
            if kill_reused_app_server && self.config.port > 0 {
                match ssh_client.kill_listener_on_port(self.config.port).await {
                    Ok(result) => {
                        info!(
                            "restart app server stop listener port={} exit_code={} stdout={} stderr={}",
                            self.config.port,
                            result.exit_code,
                            result.stdout.trim(),
                            result.stderr.trim()
                        );
                    }
                    Err(error) => {
                        warn!(
                            "restart app server stop listener failed port={} error={}",
                            self.config.port, error
                        );
                    }
                }
            }
            ssh_client.disconnect().await;
        }
        // Give the worker a moment to shut down gracefully.
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        self.worker_handle.abort();
        info!("server session disconnected: {}", self.config.display_name);
    }
}

pub(crate) fn remote_connect_args(config: &ServerConfig) -> (String, RemoteAppServerConnectArgs) {
    let url = if let Some(url) = config.websocket_url.clone() {
        url
    } else {
        let scheme = if config.tls { "wss" } else { "ws" };
        format!("{scheme}://{}:{}", config.host, config.port)
    };

    let args = RemoteAppServerConnectArgs {
        websocket_url: url.clone(),
        auth_token: None,
        client_name: "Litter".to_string(),
        client_version: "1.0".to_string(),
        experimental_api: true,
        opt_out_notification_methods: Vec::new(),
        channel_capacity: 256,
    };

    (url, args)
}

pub(crate) async fn connect_remote_client(
    args: &RemoteAppServerConnectArgs,
) -> Result<AppServerClient, TransportError> {
    #[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
    {
        let home_dir = std::env::var_os("HOME").map(PathBuf::from);
        let codex_home = resolve_ios_codex_home(&home_dir)?;
        let _ = prepare_ios_runtime_environment(&codex_home)?;
    }

    Ok(AppServerClient::Remote(
        RemoteAppServerClient::connect(args.clone())
            .await
            .map_err(|e| TransportError::ConnectionFailed(e.to_string()))?,
    ))
}

async fn reconnect_remote_client(
    client: &mut AppServerClient,
    keepalive: &mut Option<Arc<dyn Send + Sync>>,
    args: &RemoteAppServerConnectArgs,
    websocket_url: &str,
    health_tx: &watch::Sender<ConnectionHealth>,
    transport: Option<&Arc<dyn RemoteTransport>>,
) -> bool {
    for attempt in 1..=REMOTE_RECONNECT_MAX_ATTEMPTS {
        append_android_debug_log(&format!(
            "reconnect_start url={} attempt={}/{}",
            websocket_url, attempt, REMOTE_RECONNECT_MAX_ATTEMPTS
        ));
        info!(
            "remote reconnect start url={} attempt={}/{}",
            websocket_url, attempt, REMOTE_RECONNECT_MAX_ATTEMPTS
        );
        let _ = health_tx.send(ConnectionHealth::Connecting {
            attempt,
            max_attempts: REMOTE_RECONNECT_MAX_ATTEMPTS,
        });

        let connect_result: Result<Reconnected, TransportError> = match transport {
            Some(t) => t.reconnect(args, websocket_url).await,
            None => connect_remote_client(args).await.map(|client| Reconnected {
                client,
                keepalive: None,
            }),
        };

        match connect_result {
            Ok(next) => {
                *client = next.client;
                if next.keepalive.is_some() {
                    *keepalive = next.keepalive;
                }
                let _ = health_tx.send(ConnectionHealth::Connected);
                info!(
                    "remote server session reconnected: {} (attempt {attempt}/{})",
                    websocket_url, REMOTE_RECONNECT_MAX_ATTEMPTS
                );
                append_android_debug_log(&format!(
                    "reconnect_success url={} attempt={}/{}",
                    websocket_url, attempt, REMOTE_RECONNECT_MAX_ATTEMPTS
                ));
                return true;
            }
            Err(error) => {
                warn!(
                    "remote server reconnect failed: {} (attempt {attempt}/{}) - {}",
                    websocket_url, REMOTE_RECONNECT_MAX_ATTEMPTS, error
                );
                append_android_debug_log(&format!(
                    "reconnect_failed url={} attempt={}/{} error={}",
                    websocket_url, attempt, REMOTE_RECONNECT_MAX_ATTEMPTS, error
                ));
                if attempt < REMOTE_RECONNECT_MAX_ATTEMPTS {
                    tokio::time::sleep(REMOTE_RECONNECT_DELAY).await;
                }
            }
        }
    }

    let _ = health_tx.send(ConnectionHealth::Disconnected);
    false
}

fn ssh_reconnect_remote_host(transport: &SshReconnectTransport) -> &'static str {
    if transport.prefer_ipv6 {
        "::1"
    } else {
        "127.0.0.1"
    }
}

fn ssh_reconnect_remote_port(transport: &SshReconnectTransport) -> u16 {
    match transport.remote_port.lock() {
        Ok(guard) => *guard,
        Err(error) => {
            warn!("remote reconnect: recovering poisoned remote_port lock");
            *error.into_inner()
        }
    }
}

fn update_ssh_reconnect_remote_port(transport: &SshReconnectTransport, port: u16) {
    match transport.remote_port.lock() {
        Ok(mut guard) => *guard = port,
        Err(error) => {
            warn!("remote reconnect: recovering poisoned remote_port lock");
            *error.into_inner() = port;
        }
    }
}

fn update_ssh_reconnect_pid(transport: &SshReconnectTransport, pid: Option<u32>) {
    let Some(pid_slot) = transport.ssh_pid.as_ref() else {
        return;
    };
    match pid_slot.lock() {
        Ok(mut guard) => *guard = pid,
        Err(error) => {
            warn!("remote reconnect: recovering poisoned ssh_pid lock");
            *error.into_inner() = pid;
        }
    }
}

async fn rebootstrap_remote_client_over_ssh(
    transport: &SshReconnectTransport,
    websocket_url: &str,
) -> bool {
    let bootstrap = match transport
        .ssh_client
        .bootstrap_codex_server(transport.working_dir.as_deref(), transport.prefer_ipv6)
        .await
    {
        Ok(bootstrap) => bootstrap,
        Err(error) => {
            warn!(
                "remote reconnect ssh rebootstrap failed: {} error={}",
                websocket_url, error
            );
            return false;
        }
    };

    finalize_ssh_rebootstrap(transport, bootstrap, websocket_url).await
}

async fn finalize_ssh_rebootstrap(
    transport: &SshReconnectTransport,
    bootstrap: SshBootstrapResult,
    websocket_url: &str,
) -> bool {
    let remote_host = ssh_reconnect_remote_host(transport);
    let existing_local_port = transport.local_port;
    let previous_remote_port = ssh_reconnect_remote_port(transport);

    if bootstrap.tunnel_local_port != existing_local_port {
        let _ = transport
            .ssh_client
            .abort_forward_port(bootstrap.tunnel_local_port)
            .await;
    }
    if bootstrap.server_port != previous_remote_port {
        let _ = transport
            .ssh_client
            .abort_forward_port(existing_local_port)
            .await;
    }

    if let Err(error) = transport
        .ssh_client
        .ensure_forward_port_to(existing_local_port, remote_host, bootstrap.server_port)
        .await
    {
        warn!(
            "remote reconnect ssh rebootstrap forward failed: {} local_port={} remote={}:{} error={}",
            websocket_url, existing_local_port, remote_host, bootstrap.server_port, error
        );
        return false;
    }

    update_ssh_reconnect_remote_port(transport, bootstrap.server_port);
    update_ssh_reconnect_pid(transport, bootstrap.pid);
    true
}

#[async_trait::async_trait]
impl RemoteTransport for SshReconnectTransport {
    async fn reconnect(
        &self,
        args: &RemoteAppServerConnectArgs,
        websocket_url: &str,
    ) -> Result<Reconnected, TransportError> {
        let remote_host = ssh_reconnect_remote_host(self);
        let remote_port = ssh_reconnect_remote_port(self);
        if let Err(error) = self
            .ssh_client
            .ensure_forward_port_to(self.local_port, remote_host, remote_port)
            .await
        {
            warn!(
                "remote reconnect forward restore failed: {} local_port={} remote={}:{} error={}",
                websocket_url, self.local_port, remote_host, remote_port, error
            );
        }

        match connect_remote_client(args).await {
            Ok(client) => Ok(Reconnected {
                client,
                keepalive: None,
            }),
            Err(error) => {
                if rebootstrap_remote_client_over_ssh(self, websocket_url).await {
                    match connect_remote_client(args).await {
                        Ok(client) => {
                            info!(
                                "remote reconnect succeeded after ssh rebootstrap: {}",
                                websocket_url
                            );
                            Ok(Reconnected {
                                client,
                                keepalive: None,
                            })
                        }
                        Err(retry_error) => {
                            warn!(
                                "remote reconnect after ssh rebootstrap still failed: {} - {}",
                                websocket_url, retry_error
                            );
                            Err(retry_error)
                        }
                    }
                } else {
                    Err(error)
                }
            }
        }
    }
}

fn spawn_remote_runtime_worker(
    runtime_kind: AgentRuntimeKind,
    mut client: AppServerClient,
    initial_keepalive: Option<Arc<dyn Send + Sync>>,
    mut command_rx: mpsc::Receiver<SessionCommand>,
    event_tx: broadcast::Sender<ServerEvent>,
    health_tx: watch::Sender<ConnectionHealth>,
    reconnect_args: RemoteAppServerConnectArgs,
    reconnect_url: String,
    reconnect_transport: Option<Arc<dyn RemoteTransport>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut keepalive: Option<Arc<dyn Send + Sync>> = initial_keepalive;
        loop {
            tokio::select! {
                command = command_rx.recv() => {
                    let Some(command) = command else { break; };
                    match command {
                        SessionCommand::Request { request, response_tx } => {
                            let request_retry = request.clone();
                            let mut result = match client.request(request).await {
                                Ok(Ok(value)) => Ok(value),
                                Ok(Err(error)) => Err(RpcError::Server {
                                    code: error.code,
                                    message: error.message,
                                }),
                                Err(error) => Err(RpcError::Transport(
                                    TransportError::SendFailed(error.to_string()),
                                )),
                            };
                            if matches!(result, Err(RpcError::Transport(_)))
                                && reconnect_remote_client(
                                    &mut client,
                                    &mut keepalive,
                                    &reconnect_args,
                                    &reconnect_url,
                                    &health_tx,
                                    reconnect_transport.as_ref(),
                                )
                                .await
                            {
                                result = match client.request(request_retry).await {
                                    Ok(Ok(value)) => Ok(value),
                                    Ok(Err(error)) => Err(RpcError::Server {
                                        code: error.code,
                                        message: error.message,
                                    }),
                                    Err(error) => Err(RpcError::Transport(
                                        TransportError::SendFailed(error.to_string()),
                                    )),
                                };
                            }
                            let _ = response_tx.send(result);
                        }
                        SessionCommand::Notify { notification, response_tx } => {
                            let result = client.notify(notification).await.map_err(|error| {
                                RpcError::Transport(TransportError::SendFailed(error.to_string()))
                            });
                            let _ = response_tx.send(result);
                        }
                        SessionCommand::Resolve { request_id, result, response_tx } => {
                            let result = client
                                .resolve_server_request(request_id, result)
                                .await
                                .map_err(|error| {
                                    RpcError::Transport(TransportError::SendFailed(
                                        error.to_string(),
                                    ))
                                });
                            let _ = response_tx.send(result);
                        }
                        SessionCommand::Reject { request_id, error, response_tx } => {
                            let result = client
                                .reject_server_request(request_id, error)
                                .await
                                .map_err(|error| {
                                    RpcError::Transport(TransportError::SendFailed(
                                        error.to_string(),
                                    ))
                                });
                            let _ = response_tx.send(result);
                        }
                        SessionCommand::Shutdown => {
                            let _ = client.shutdown().await;
                            break;
                        }
                    }
                }
                event = client.next_event() => {
                    let Some(event) = event else {
                        if reconnect_remote_client(
                            &mut client,
                            &mut keepalive,
                            &reconnect_args,
                            &reconnect_url,
                            &health_tx,
                            reconnect_transport.as_ref(),
                        )
                        .await {
                            continue;
                        }
                        break;
                    };
                    if let AppServerEvent::Disconnected { .. } = &event
                        && reconnect_remote_client(
                            &mut client,
                            &mut keepalive,
                            &reconnect_args,
                            &reconnect_url,
                            &health_tx,
                            reconnect_transport.as_ref(),
                        )
                        .await
                    {
                        continue;
                    }
                    route_app_server_event(&event_tx, &health_tx, runtime_kind, &event);
                }
            }
        }
        // Hold the keepalive Arc for the entire worker lifetime so transport-scoped
        // resources (e.g. an iroh Endpoint) are dropped only after the worker exits.
        drop(keepalive);
    })
}

// ---------------------------------------------------------------------------
// Event routing helpers
// ---------------------------------------------------------------------------

fn route_app_server_event(
    event_tx: &broadcast::Sender<ServerEvent>,
    health_tx: &watch::Sender<ConnectionHealth>,
    runtime_kind: AgentRuntimeKind,
    event: &AppServerEvent,
) {
    match event {
        AppServerEvent::ServerNotification(notification) => {
            info!("remote event notification {:?}", notification);
            let _ = event_tx.send(ServerEvent::Notification {
                runtime_kind,
                notification: notification.clone(),
            });
        }
        AppServerEvent::ServerRequest(request) => {
            info!("remote event server request {:?}", request);
            append_android_debug_log(&format!("server_request={request:?}"));
            let _ = event_tx.send(ServerEvent::Request {
                runtime_kind,
                request: request.clone(),
            });
        }
        AppServerEvent::Lagged { skipped } => {
            warn!("event: lagged, skipped {skipped} events");
        }
        AppServerEvent::Disconnected { message } => {
            warn!("event: disconnected: {message}");
            append_android_debug_log(&format!("disconnected={message}"));
            let _ = health_tx.send(ConnectionHealth::Disconnected);
        }
    }
}

fn route_in_process_event(
    event_tx: &broadcast::Sender<ServerEvent>,
    event: codex_app_server::in_process::InProcessServerEvent,
) {
    use codex_app_server::in_process::InProcessServerEvent;

    match event {
        InProcessServerEvent::ServerNotification(notification) => {
            let _ = event_tx.send(ServerEvent::Notification {
                runtime_kind: AgentRuntimeKind::Codex,
                notification,
            });
        }
        InProcessServerEvent::ServerRequest(request) => {
            let _ = event_tx.send(ServerEvent::Request {
                runtime_kind: AgentRuntimeKind::Codex,
                request,
            });
        }
        InProcessServerEvent::Lagged { skipped } => {
            warn!("in-process event: lagged, skipped {skipped} events");
        }
    }
}

#[cfg(test)]
impl ServerSession {
    pub(crate) fn test_stub(
        config: ServerConfig,
        ipc_client: Option<ReconnectingIpcClient>,
    ) -> Self {
        Self::test_stub_with_handlers(config, ipc_client, None, None, None)
    }

    pub(crate) fn test_stub_with_handlers(
        config: ServerConfig,
        ipc_client: Option<ReconnectingIpcClient>,
        request_handler: Option<TestRequestHandler>,
        resolve_handler: Option<TestResolveHandler>,
        reject_handler: Option<TestRejectHandler>,
    ) -> Self {
        let (health_tx, health_rx) = watch::channel(ConnectionHealth::Connected);
        let (command_tx, mut command_rx) = mpsc::channel(16);
        let (event_tx, _) = broadcast::channel(16);
        let worker_handle = tokio::spawn(async move {
            while let Some(command) = command_rx.recv().await {
                match command {
                    SessionCommand::Request {
                        request,
                        response_tx,
                    } => {
                        let result = request_handler
                            .as_ref()
                            .map(|handler| handler(request))
                            .unwrap_or_else(|| {
                                Err(RpcError::Transport(TransportError::Disconnected))
                            });
                        let _ = response_tx.send(result);
                    }
                    SessionCommand::Notify { response_tx, .. } => {
                        let _ = response_tx.send(Ok(()));
                    }
                    SessionCommand::Resolve {
                        request_id,
                        result,
                        response_tx,
                    } => {
                        let outcome = resolve_handler
                            .as_ref()
                            .map(|handler| handler(request_id, result))
                            .unwrap_or(Ok(()));
                        let _ = response_tx.send(outcome);
                    }
                    SessionCommand::Reject {
                        request_id,
                        error,
                        response_tx,
                    } => {
                        let outcome = reject_handler
                            .as_ref()
                            .map(|handler| handler(request_id, error))
                            .unwrap_or(Ok(()));
                        let _ = response_tx.send(outcome);
                    }
                    SessionCommand::Shutdown => break,
                }
            }
        });
        let shared_ipc_client = ipc_client.map(Arc::new);

        Self {
            config,
            health_tx,
            health_rx,
            command_tx,
            runtime_command_txs: std::collections::HashMap::new(),
            event_tx,
            ipc_stream_client: shared_ipc_client,
            ssh_client: None,
            ssh_pid: None,
            ipc_ssh_client: None,
            ipc_stream_bridge_pid: None,
            worker_handle,
        }
    }

    #[cfg(test)]
    pub(crate) fn test_stub_with_runtime_handlers(
        config: ServerConfig,
        runtime_handlers: Vec<(AgentRuntimeKind, TestRequestHandler)>,
    ) -> Self {
        let (health_tx, health_rx) = watch::channel(ConnectionHealth::Connected);
        let (command_tx, default_worker_handle) = spawn_test_command_worker(None, None, None);
        let (event_tx, _) = broadcast::channel(16);
        let mut runtime_command_txs = std::collections::HashMap::new();
        let mut worker_handles = vec![default_worker_handle];
        for (runtime_kind, handler) in runtime_handlers {
            let (runtime_tx, runtime_worker_handle) =
                spawn_test_command_worker(Some(handler), None, None);
            runtime_command_txs.insert(runtime_kind, runtime_tx);
            worker_handles.push(runtime_worker_handle);
        }
        let worker_handle = tokio::spawn(async move {
            for handle in worker_handles {
                let _ = handle.await;
            }
        });

        Self {
            config,
            health_tx,
            health_rx,
            command_tx,
            runtime_command_txs,
            event_tx,
            ipc_stream_client: None,
            ssh_client: None,
            ssh_pid: None,
            ipc_ssh_client: None,
            ipc_stream_bridge_pid: None,
            worker_handle,
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn json_value_to_request_id(value: &JsonValue) -> Result<RequestId, RpcError> {
    match value {
        JsonValue::Number(n) => Ok(RequestId::Integer(n.as_i64().unwrap_or(0))),
        JsonValue::String(s) => Ok(RequestId::String(s.clone())),
        _ => Err(RpcError::Deserialization(
            "invalid request id type".to_string(),
        )),
    }
}

fn next_request_id() -> i64 {
    use std::sync::atomic::{AtomicI64, Ordering};
    static COUNTER: AtomicI64 = AtomicI64::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::{Mutex, OnceLock};
    use std::time::{SystemTime, UNIX_EPOCH};

    use serde_json::json;

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn unique_temp_path(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be after unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("litter-{label}-{nanos}"))
    }

    #[test]
    fn server_config_local() {
        let config = ServerConfig {
            server_id: "local-1".into(),
            display_name: "My Mac".into(),
            host: "127.0.0.1".into(),
            port: 0,
            websocket_url: None,
            is_local: true,
            tls: false,
        };
        assert!(config.is_local);
        assert_eq!(config.server_id, "local-1");
    }

    #[test]
    fn server_config_remote() {
        let config = ServerConfig {
            server_id: "remote-1".into(),
            display_name: "Cloud Server".into(),
            host: "codex.example.com".into(),
            port: 443,
            websocket_url: None,
            is_local: false,
            tls: true,
        };
        assert!(!config.is_local);
        assert!(config.tls);
        assert_eq!(config.port, 443);
    }

    #[test]
    fn connection_health_disconnected_eq() {
        assert_eq!(
            ConnectionHealth::Disconnected,
            ConnectionHealth::Disconnected
        );
    }

    #[test]
    fn connection_health_connecting_eq() {
        let a = ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 5,
        };
        let b = ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 5,
        };
        assert_eq!(a, b);
    }

    #[test]
    fn connection_health_connecting_ne_different_attempt() {
        let a = ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 5,
        };
        let b = ConnectionHealth::Connecting {
            attempt: 2,
            max_attempts: 5,
        };
        assert_ne!(a, b);
    }

    #[test]
    fn connection_health_connected_eq() {
        assert_eq!(ConnectionHealth::Connected, ConnectionHealth::Connected);
    }

    #[test]
    fn connection_health_different_variants_ne() {
        assert_ne!(ConnectionHealth::Connected, ConnectionHealth::Disconnected);
        assert_ne!(
            ConnectionHealth::Connecting {
                attempt: 1,
                max_attempts: 5
            },
            ConnectionHealth::Connected,
        );
    }

    #[test]
    fn connection_health_unresponsive_same_instant() {
        let now = Instant::now();
        let a = ConnectionHealth::Unresponsive { since: now };
        let b = ConnectionHealth::Unresponsive { since: now };
        assert_eq!(a, b);
    }

    #[test]
    fn health_watch_initial_value() {
        let (tx, rx) = watch::channel(ConnectionHealth::Disconnected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Disconnected);
        let _ = tx.send(ConnectionHealth::Connected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Connected);
    }

    #[test]
    fn health_watch_multiple_transitions() {
        let (tx, rx) = watch::channel(ConnectionHealth::Disconnected);

        let _ = tx.send(ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 3,
        });
        assert_eq!(
            *rx.borrow(),
            ConnectionHealth::Connecting {
                attempt: 1,
                max_attempts: 3
            }
        );

        let _ = tx.send(ConnectionHealth::Connected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Connected);

        let _ = tx.send(ConnectionHealth::Disconnected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Disconnected);
    }

    // -- Event bridge tests (using string-based bridge for backward compat) --

    fn spawn_string_event_bridge(
        mut event_rx: broadcast::Receiver<String>,
        notification_tx: broadcast::Sender<(String, JsonValue)>,
        server_request_tx: broadcast::Sender<(JsonValue, String, JsonValue)>,
    ) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            loop {
                match event_rx.recv().await {
                    Ok(json_str) => {
                        let parsed: JsonValue = match serde_json::from_str(&json_str) {
                            Ok(v) => v,
                            Err(e) => {
                                warn!("event bridge: failed to parse event JSON: {e}");
                                continue;
                            }
                        };

                        let has_id = parsed.get("id").is_some();
                        let method = parsed
                            .get("method")
                            .and_then(|m| m.as_str())
                            .map(|s| s.to_string());
                        let params = parsed.get("params").cloned().unwrap_or(JsonValue::Null);

                        match (has_id, method) {
                            (true, Some(method)) => {
                                let id = parsed.get("id").cloned().unwrap_or(JsonValue::Null);
                                let _ = server_request_tx.send((id, method, params));
                            }
                            (false, Some(method)) => {
                                let _ = notification_tx.send((method, params));
                            }
                            (true, None) => {}
                            (false, None) => {}
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        })
    }

    #[tokio::test]
    async fn event_bridge_routes_notification() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let notif = json!({"method": "codex/event/turnComplete", "params": {"turn_id": "t1"}});
        event_tx.send(notif.to_string()).unwrap();

        let (method, params) =
            tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
                .await
                .expect("should receive within timeout")
                .expect("should receive notification");

        assert_eq!(method, "codex/event/turnComplete");
        assert_eq!(params, json!({"turn_id": "t1"}));
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_routes_server_request() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, _notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, mut req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let req = json!({"id": "srv-42", "method": "tools/approve", "params": {"tool": "bash"}});
        event_tx.send(req.to_string()).unwrap();

        let (id, method, params) =
            tokio::time::timeout(std::time::Duration::from_secs(2), req_rx.recv())
                .await
                .expect("should receive within timeout")
                .expect("should receive server request");

        assert_eq!(id, json!("srv-42"));
        assert_eq!(method, "tools/approve");
        assert_eq!(params, json!({"tool": "bash"}));
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_skips_response_like_events() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, mut req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let resp = json!({"id": 1, "result": {"ok": true}});
        event_tx.send(resp.to_string()).unwrap();

        let notif = json!({"method": "ping"});
        event_tx.send(notif.to_string()).unwrap();

        let (method, _) = tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
            .await
            .expect("should receive within timeout")
            .expect("should receive notification");

        assert_eq!(method, "ping");
        assert!(req_rx.try_recv().is_err());
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_handles_malformed_json() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        event_tx.send("not valid json".to_string()).unwrap();

        let notif = json!({"method": "test/ok"});
        event_tx.send(notif.to_string()).unwrap();

        let (method, _) = tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
            .await
            .expect("should receive within timeout")
            .expect("should receive notification");

        assert_eq!(method, "test/ok");
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_handles_missing_params() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let notif = json!({"method": "heartbeat"});
        event_tx.send(notif.to_string()).unwrap();

        let (method, params) =
            tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
                .await
                .expect("should receive within timeout")
                .expect("should receive notification");

        assert_eq!(method, "heartbeat");
        assert_eq!(params, JsonValue::Null);
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_stops_on_channel_close() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, _notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        drop(event_tx);

        let result = tokio::time::timeout(std::time::Duration::from_secs(2), handle).await;
        assert!(
            result.is_ok(),
            "bridge task should complete when channel closes"
        );
    }

    #[test]
    fn ws_url_construction_no_tls() {
        let config = ServerConfig {
            server_id: "s1".into(),
            display_name: "Test".into(),
            host: "192.168.1.100".into(),
            port: 8080,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        let scheme = if config.tls { "wss" } else { "ws" };
        let url = format!("{scheme}://{}:{}", config.host, config.port);
        assert_eq!(url, "ws://192.168.1.100:8080");
    }

    #[test]
    fn ws_url_construction_with_tls() {
        let config = ServerConfig {
            server_id: "s2".into(),
            display_name: "Secure".into(),
            host: "codex.example.com".into(),
            port: 443,
            websocket_url: None,
            is_local: false,
            tls: true,
        };
        let scheme = if config.tls { "wss" } else { "ws" };
        let url = format!("{scheme}://{}:{}", config.host, config.port);
        assert_eq!(url, "wss://codex.example.com:443");
    }

    #[test]
    fn json_value_to_request_id_integer() {
        let id = json_value_to_request_id(&json!(42)).unwrap();
        assert!(matches!(id, RequestId::Integer(42)));
    }

    #[test]
    fn json_value_to_request_id_string() {
        let id = json_value_to_request_id(&json!("srv-1")).unwrap();
        assert!(matches!(id, RequestId::String(ref s) if s == "srv-1"));
    }

    #[test]
    fn json_value_to_request_id_invalid() {
        let result = json_value_to_request_id(&json!(true));
        assert!(result.is_err());
    }

    #[test]
    fn next_request_id_is_monotonic() {
        let a = next_request_id();
        let b = next_request_id();
        let c = next_request_id();
        assert!(b > a);
        assert!(c > b);
    }

    #[test]
    fn in_process_config_default() {
        let config = InProcessConfig::default();
        assert_eq!(config.channel_capacity, 256);
        assert!(config.codex_home.is_none());
        assert!(config.working_directory.is_none());
    }

    #[test]
    fn prepare_ios_runtime_environment_sets_codex_home_and_tls_bundle() {
        let _guard = env_lock().lock().expect("env lock should not be poisoned");
        let original_codex_home = std::env::var_os("CODEX_HOME");
        let original_ssl_cert_file = std::env::var_os("SSL_CERT_FILE");
        let codex_home = unique_temp_path("ios-runtime");

        unsafe {
            std::env::set_var("CODEX_HOME", &codex_home);
            std::env::remove_var("SSL_CERT_FILE");
        }

        let canonical = prepare_ios_runtime_environment(&codex_home)
            .expect("ios runtime environment should initialize");
        let pem_path = canonical.join("cacert.pem");

        assert_eq!(
            std::env::var_os("CODEX_HOME"),
            Some(canonical.clone().into())
        );
        assert_eq!(
            std::env::var_os("SSL_CERT_FILE"),
            Some(pem_path.clone().into())
        );
        assert!(pem_path.is_file(), "cacert.pem should be written");

        if let Some(value) = original_codex_home {
            unsafe {
                std::env::set_var("CODEX_HOME", value);
            }
        } else {
            unsafe {
                std::env::remove_var("CODEX_HOME");
            }
        }

        if let Some(value) = original_ssl_cert_file {
            unsafe {
                std::env::set_var("SSL_CERT_FILE", value);
            }
        } else {
            unsafe {
                std::env::remove_var("SSL_CERT_FILE");
            }
        }

        let _ = std::fs::remove_dir_all(codex_home);
    }
}
