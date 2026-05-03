use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant, UNIX_EPOCH};

use alleycat_bridge_core::{Bridge, ProcessLauncher, serve_stream};
use alleycat_claude_bridge::index::{ClaudeSessionInfo, entry_from_claude};
use alleycat_claude_bridge::{ClaudeBridge, ClaudeSessionRef};
use alleycat_opencode_bridge::{OpencodeBridge, OpencodeRuntime};
use alleycat_pi_bridge::PiBridge;
use alleycat_pi_bridge::index::{PiHydrator, PiSessionInfo};
use chrono::{DateTime, Utc};
use codex_app_server_client::{AppServerClient, RemoteAppServerClient, RemoteAppServerConnectArgs};
use serde::{Deserialize, Serialize};
use tokio::io::duplex;
use tracing::{debug, info, warn};

use crate::session::connection::{
    RuntimeRemoteSessionResource, SshReconnectTransport, connect_remote_client,
};
use crate::ssh::{PROFILE_INIT, RemoteShell, SshClient, SshError, shell_quote};
use crate::ssh_detached_launcher::SshDetachedLauncher;
use crate::ssh_launcher::SshLauncher;
use crate::types::{AgentRuntimeInfo, AgentRuntimeKind};

// Bridge timings — every magic number in this file should live here.
/// How long we'll poll a freshly-spawned local opencode for `/global/health`.
const OPENCODE_LOCAL_HEALTH_BUDGET: Duration = Duration::from_secs(10);
const OPENCODE_LOCAL_HEALTH_INTERVAL: Duration = Duration::from_millis(50);
/// How many candidate ports we'll check when picking a free remote port.
const REMOTE_PORT_PROBE_CANDIDATES: u16 = 50;
/// Probe range for ephemeral remote ports (matches Linux's local port range).
const REMOTE_PORT_PROBE_BASE: u16 = 17600;
const REMOTE_PORT_PROBE_SPAN: u16 = 2000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum SshBridgeTransport {
    Ephemeral,
    Detached,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct RemoteAgentAvailability {
    pub kind: AgentRuntimeKind,
    pub status: AgentAvailabilityStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AgentAvailabilityStatus {
    Available,
    AgentCliMissing,
    WindowsNotYetSupported,
}

#[derive(Debug, thiserror::Error)]
pub enum SshBridgeError {
    #[error("agent CLI missing: {0}")]
    AgentCliMissing(String),
    #[error("bridge startup failed: {0}")]
    BridgeStartupFailed(String),
    #[error("handshake failed: {0}")]
    HandshakeFailed(String),
    #[error("transport error: {0}")]
    Transport(String),
    #[error("codex uses the existing direct SSH path")]
    UseExistingCodexPath,
    #[error("Windows SSH bridge remotes are not supported yet")]
    WindowsRemoteNotYetSupported,
    #[error("detached SSH bridge transport is not implemented yet")]
    DetachedNotYetImplemented,
}

impl From<SshError> for SshBridgeError {
    fn from(value: SshError) -> Self {
        Self::Transport(value.to_string())
    }
}

pub async fn probe_remote_agents(
    ssh: &Arc<SshClient>,
) -> Result<Vec<RemoteAgentAvailability>, SshBridgeError> {
    info!("ssh bridge agent probe start");
    let shell = ssh.detect_remote_shell().await;
    info!("ssh bridge agent probe shell={shell:?}");
    let kinds = [
        AgentRuntimeKind::Claude,
        AgentRuntimeKind::Pi,
        AgentRuntimeKind::Opencode,
        AgentRuntimeKind::Codex,
    ];
    if shell == RemoteShell::PowerShell {
        let availability = kinds
            .into_iter()
            .map(|kind| RemoteAgentAvailability {
                kind,
                status: AgentAvailabilityStatus::WindowsNotYetSupported,
            })
            .collect::<Vec<_>>();
        info!("ssh bridge agent probe result availability={availability:?}");
        return Ok(availability);
    }

    let script = format!(
        "{PROFILE_INIT}\n{}",
        r#"find_cmd() {
  cmd="$1"
  case "$cmd" in
    */*)
      if [ -x "$cmd" ]; then
        printf '%s\n' "$cmd"
        return 0
      fi
      ;;
    *)
      path=$(command -v "$cmd" 2>/dev/null || true)
      if [ -n "$path" ]; then
        printf '%s\n' "$path"
        return 0
      fi
      ;;
  esac
  return 1
}

probe_one() {
  label="$1"
  shift
  for cmd in "$@"; do
    path=$(find_cmd "$cmd" || true)
    if [ -n "$path" ]; then
      printf '%s\t%s\n' "$label" "$path"
      return
    fi
  done
  printf '%s\t\n' "$label"
}

probe_one_executes() {
  label="$1"
  shift
  for cmd in "$@"; do
    path=$(find_cmd "$cmd" || true)
    if [ -n "$path" ]; then
      if "$path" --version >/dev/null 2>&1; then
        printf '%s\t%s\n' "$label" "$path"
      else
        printf '%s\t\n' "$label"
      fi
      return
    fi
  done
  printf '%s\t\n' "$label"
}

probe_one claude claude
probe_one pi pi-coding-agent pi
probe_one_executes opencode opencode
probe_one codex codex"#
    );
    let result = ssh.exec_shell(&script, shell).await?;
    if result.exit_code != 0 {
        warn!(
            "ssh bridge agent probe failed exit_code={} stderr={}",
            result.exit_code, result.stderr
        );
        return Err(SshBridgeError::Transport(result.stderr));
    }
    let availability = parse_agent_probe(&result.stdout);
    info!("ssh bridge agent probe result availability={availability:?}");
    Ok(availability)
}

pub async fn connect_runtime_resources_via_ssh(
    ssh: Arc<SshClient>,
    state_root: impl AsRef<Path>,
    runtime_kinds: Vec<AgentRuntimeKind>,
    transport: SshBridgeTransport,
    prefer_ipv6: bool,
) -> Result<(Vec<RuntimeRemoteSessionResource>, Vec<AgentRuntimeInfo>), SshBridgeError> {
    let state_root = state_root.as_ref().to_path_buf();
    info!(
        "ssh bridge runtime connect start state_root={} runtimes={:?} transport={transport:?} prefer_ipv6={prefer_ipv6}",
        state_root.display(),
        runtime_kinds
    );
    let mut resources = Vec::new();
    let mut infos = Vec::new();
    for kind in runtime_kinds {
        info!("ssh bridge runtime connect begin kind={kind:?}");
        let (client, trait_transport) = if kind == AgentRuntimeKind::Codex {
            let (client, reconnect_transport) =
                connect_codex_via_ssh(Arc::clone(&ssh), prefer_ipv6).await?;
            let t: std::sync::Arc<dyn crate::session::remote_transport::RemoteTransport> =
                std::sync::Arc::new(reconnect_transport);
            (client, Some(t))
        } else {
            (
                connect_app_server_client_via_ssh(
                    Arc::clone(&ssh),
                    state_root.join(runtime_label(kind)),
                    kind,
                    None,
                    transport,
                )
                .await?,
                None,
            )
        };
        info!("ssh bridge runtime connect ready kind={kind:?}");
        resources.push(RuntimeRemoteSessionResource {
            runtime_kind: kind,
            client,
            transport: trait_transport,
            keepalive: None,
        });
        infos.push(AgentRuntimeInfo {
            kind,
            name: runtime_label(kind).to_string(),
            display_name: runtime_display_name(kind).to_string(),
            available: true,
        });
    }
    info!(
        "ssh bridge runtime connect complete registered_runtimes={:?}",
        resources
            .iter()
            .map(|resource| resource.runtime_kind)
            .collect::<Vec<_>>()
    );
    Ok((resources, infos))
}

pub async fn connect_app_server_client_via_ssh(
    ssh: Arc<SshClient>,
    state_dir: impl AsRef<Path>,
    kind: AgentRuntimeKind,
    bin_override: Option<String>,
    transport: SshBridgeTransport,
) -> Result<AppServerClient, SshBridgeError> {
    let shell = ssh.detect_remote_shell().await;
    if shell == RemoteShell::PowerShell {
        return Err(SshBridgeError::WindowsRemoteNotYetSupported);
    }
    let state_dir = state_dir.as_ref().to_path_buf();
    info!(
        "ssh bridge app-server runtime start kind={kind:?} state_dir={} transport={transport:?}",
        state_dir.display()
    );
    let launcher: Arc<dyn ProcessLauncher> = match transport {
        SshBridgeTransport::Ephemeral => Arc::new(SshLauncher::new(Arc::clone(&ssh), shell)),
        SshBridgeTransport::Detached => Arc::new(SshDetachedLauncher::new(Arc::clone(&ssh), shell)),
    };
    let bridge: Arc<dyn Bridge> = match kind {
        AgentRuntimeKind::Claude => {
            let bin = resolve_remote_cli(
                &ssh,
                shell,
                &cli_candidates(&["claude"], bin_override.as_deref()),
            )
            .await?;
            info!("ssh bridge resolved runtime cli kind={kind:?} bin={bin}");
            hydrate_remote_claude_index(&ssh, shell, &state_dir).await;
            ClaudeBridge::builder()
                .agent_bin(bin)
                .launcher(Arc::clone(&launcher))
                .codex_home(state_dir)
                .pool_capacity(4)
                .trust_persisted_cwd(true)
                .build()
                .await
                .map_err(|error| SshBridgeError::BridgeStartupFailed(error.to_string()))?
        }
        AgentRuntimeKind::Pi => {
            let bin = resolve_remote_cli(
                &ssh,
                shell,
                &cli_candidates(&["pi-coding-agent", "pi"], bin_override.as_deref()),
            )
            .await?;
            info!("ssh bridge resolved runtime cli kind={kind:?} bin={bin}");
            let hydrator = match scan_remote_pi_sessions(&ssh, shell).await {
                Ok(sessions) => {
                    info!(
                        count = sessions.len(),
                        "ssh bridge hydrated remote pi session scan"
                    );
                    PiHydrator::with_sessions(sessions)
                }
                Err(error) => {
                    warn!("ssh bridge remote pi session scan failed: {error}");
                    PiHydrator::with_sessions(Vec::new())
                }
            };
            PiBridge::builder()
                .agent_bin(bin)
                .launcher(Arc::clone(&launcher))
                .codex_home(state_dir)
                .pool_capacity(4)
                .trust_persisted_cwd(true)
                .hydrator(hydrator)
                .build()
                .await
                .map_err(|error| SshBridgeError::BridgeStartupFailed(error.to_string()))?
        }
        AgentRuntimeKind::Opencode => {
            return connect_opencode_via_ssh(ssh, state_dir, bin_override).await;
        }
        AgentRuntimeKind::Codex => return Err(SshBridgeError::UseExistingCodexPath),
    };
    connect_bridge_stream(bridge, kind).await
}

async fn connect_bridge_stream(
    bridge: Arc<dyn Bridge>,
    kind: AgentRuntimeKind,
) -> Result<AppServerClient, SshBridgeError> {
    let (client_io, server_io) = duplex(64 * 1024);
    tokio::spawn(async move {
        if let Err(error) = serve_stream(bridge, server_io).await {
            warn!("ssh bridge stream ended kind={kind:?}: {error:#}");
        }
    });
    let label = format!("ssh-bridge://{}", runtime_label(kind));
    info!("ssh bridge stream connect start kind={kind:?} label={label}");
    let args = RemoteAppServerConnectArgs {
        websocket_url: label.clone(),
        auth_token: None,
        client_name: "Litter".to_string(),
        client_version: "1.0".to_string(),
        experimental_api: true,
        opt_out_notification_methods: Vec::new(),
        channel_capacity: 256,
    };
    let remote = RemoteAppServerClient::connect_json_line_stream(client_io, args, label)
        .await
        .map_err(|error| SshBridgeError::HandshakeFailed(error.to_string()))?;
    info!("ssh bridge stream connect ready kind={kind:?}");
    Ok(AppServerClient::Remote(remote))
}

async fn connect_codex_via_ssh(
    ssh: Arc<SshClient>,
    prefer_ipv6: bool,
) -> Result<(AppServerClient, SshReconnectTransport), SshBridgeError> {
    let bootstrap = ssh.bootstrap_codex_server(None, prefer_ipv6).await?;
    let websocket_url = format!("ws://127.0.0.1:{}", bootstrap.tunnel_local_port);
    let args = RemoteAppServerConnectArgs {
        websocket_url: websocket_url.clone(),
        auth_token: None,
        client_name: "Litter".to_string(),
        client_version: "1.0".to_string(),
        experimental_api: true,
        opt_out_notification_methods: Vec::new(),
        channel_capacity: 256,
    };
    let client = connect_remote_client(&args)
        .await
        .map_err(|error| SshBridgeError::HandshakeFailed(error.to_string()))?;
    let ssh_pid = Arc::new(StdMutex::new(bootstrap.pid));
    let reconnect_transport = SshReconnectTransport {
        ssh_client: Arc::clone(&ssh),
        local_port: bootstrap.tunnel_local_port,
        remote_port: Arc::new(StdMutex::new(bootstrap.server_port)),
        prefer_ipv6,
        working_dir: None,
        ssh_pid: Some(ssh_pid),
    };
    info!(
        "ssh codex runtime connected via direct bootstrap: websocket_url={} remote_port={} local_port={}",
        websocket_url, bootstrap.server_port, bootstrap.tunnel_local_port
    );
    Ok((client, reconnect_transport))
}

async fn connect_opencode_via_ssh(
    ssh: Arc<SshClient>,
    state_dir: PathBuf,
    bin_override: Option<String>,
) -> Result<AppServerClient, SshBridgeError> {
    let shell = ssh.detect_remote_shell().await;
    let bin = resolve_remote_cli(
        &ssh,
        shell,
        &cli_candidates(&["opencode"], bin_override.as_deref()),
    )
    .await?;
    info!("ssh bridge resolved runtime cli kind=Opencode bin={bin}");
    validate_remote_cli_executes(&ssh, shell, &bin, "opencode").await?;
    let remote_port = pick_remote_port(&ssh, shell).await?;
    let session_id = format!("opencode-{}", now_millis());
    info!(
        "ssh bridge opencode remote start bin={bin} remote_port={remote_port} session_id={session_id}"
    );
    spawn_remote_opencode(&ssh, shell, &bin, remote_port, &session_id).await?;
    wait_until_remote_opencode_healthy(&ssh, shell, remote_port, &session_id).await?;
    let local_port = ssh.forward_port_to(0, "127.0.0.1", remote_port).await?;
    let base_url = format!("http://127.0.0.1:{local_port}");
    info!(
        "ssh bridge opencode forwarded remote_port={remote_port} local_port={local_port} session_id={session_id}"
    );
    if let Err(error) = wait_until_opencode_healthy(&base_url).await {
        let logs = fetch_remote_opencode_logs(&ssh, shell, &session_id)
            .await
            .unwrap_or_else(|log_error| {
                format!("failed to fetch remote opencode logs: {log_error}")
            });
        return Err(SshBridgeError::BridgeStartupFailed(format!(
            "{error}; remote opencode logs:\n{logs}"
        )));
    }

    let bridge = OpencodeBridge::builder()
        .runtime(OpencodeRuntime::external(base_url, String::new()))
        .state_dir(state_dir)
        .build()
        .await
        .map_err(|error| SshBridgeError::BridgeStartupFailed(error.to_string()))?;
    connect_bridge_stream(bridge, AgentRuntimeKind::Opencode).await
}

fn cli_candidates(defaults: &[&str], bin_override: Option<&str>) -> Vec<String> {
    if let Some(bin) = bin_override
        && !bin.trim().is_empty()
    {
        return vec![bin.to_string()];
    }
    defaults
        .iter()
        .map(|candidate| candidate.to_string())
        .collect()
}

async fn resolve_remote_cli(
    ssh: &SshClient,
    shell: RemoteShell,
    candidates: &[String],
) -> Result<String, SshBridgeError> {
    if shell == RemoteShell::PowerShell {
        return Err(SshBridgeError::WindowsRemoteNotYetSupported);
    }
    let candidate_list = candidates
        .iter()
        .map(|candidate| shell_quote(candidate))
        .collect::<Vec<_>>()
        .join(" ");
    let script = format!(
        "{PROFILE_INIT}\n{}",
        format!(
            r#"for cmd in {candidate_list}; do
  case "$cmd" in
    */*)
      if [ -x "$cmd" ]; then
        printf '%s\n' "$cmd"
        exit 0
      fi
      ;;
    *)
      path=$(command -v "$cmd" 2>/dev/null || true)
      if [ -n "$path" ]; then
        printf '%s\n' "$path"
        exit 0
      fi
      ;;
  esac
done
exit 127"#
        )
    );
    let result = ssh.exec_shell(&script, shell).await?;
    if result.exit_code == 0 {
        let path = result.stdout.trim();
        if path.is_empty() {
            Err(SshBridgeError::AgentCliMissing(candidates.join(" or ")))
        } else {
            Ok(path.to_string())
        }
    } else {
        Err(SshBridgeError::AgentCliMissing(candidates.join(" or ")))
    }
}

async fn validate_remote_cli_executes(
    ssh: &SshClient,
    shell: RemoteShell,
    bin: &str,
    label: &str,
) -> Result<(), SshBridgeError> {
    let script = format!(
        "{PROFILE_INIT}\n{} --version >/dev/null 2>&1",
        shell_quote(bin)
    );
    let result = ssh.exec_shell(&script, shell).await?;
    if result.exit_code == 0 {
        return Ok(());
    }
    Err(SshBridgeError::AgentCliMissing(format!(
        "{label} ({bin}) is present but failed to execute"
    )))
}

async fn hydrate_remote_claude_index(ssh: &SshClient, shell: RemoteShell, state_dir: &Path) {
    match scan_remote_claude_sessions(ssh, shell).await {
        Ok(sessions) => {
            let index_path = state_dir.join("threads.json");
            let index = match alleycat_bridge_core::ThreadIndex::<ClaudeSessionRef>::open_at(
                index_path,
            )
            .await
            {
                Ok(index) => index,
                Err(error) => {
                    warn!(
                        state_dir = %state_dir.display(),
                        "ssh bridge failed to open claude thread index for remote hydration: {error:#}"
                    );
                    return;
                }
            };
            let mut upserted = 0usize;
            for session in sessions {
                if let Err(error) = index.insert(entry_from_claude(&session)).await {
                    warn!(
                        thread_id = %session.session_id,
                        "ssh bridge failed to insert hydrated claude session: {error:#}"
                    );
                    continue;
                }
                upserted += 1;
            }
            debug!(
                state_dir = %state_dir.display(),
                upserted,
                "ssh bridge hydrated remote claude sessions"
            );
        }
        Err(error) => {
            warn!("ssh bridge remote claude session scan failed: {error}");
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemoteClaudeSession {
    path: String,
    session_id: String,
    cwd: String,
    created_ms: i64,
    modified_ms: i64,
    first_message: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemotePiSession {
    path: String,
    session_id: String,
    cwd: String,
    parent_session_path: Option<String>,
    created: String,
    modified_ms: i64,
    message_count: usize,
    name: Option<String>,
    first_message: String,
}

async fn scan_remote_claude_sessions(
    ssh: &SshClient,
    shell: RemoteShell,
) -> Result<Vec<ClaudeSessionInfo>, SshBridgeError> {
    let script = format!("{PROFILE_INIT}\n{REMOTE_CLAUDE_SESSION_SCAN}");
    let result = ssh.exec_shell(&script, shell).await?;
    if result.exit_code != 0 {
        return Err(SshBridgeError::Transport(nonempty_stderr_or_stdout(result)));
    }
    Ok(parse_remote_claude_scan(&result.stdout)
        .into_iter()
        .map(|session| ClaudeSessionInfo {
            path: PathBuf::from(session.path),
            session_id: session.session_id,
            cwd: session.cwd,
            created: datetime_from_millis(session.created_ms),
            modified: datetime_from_millis(session.modified_ms),
            first_message: session.first_message,
        })
        .collect())
}

async fn scan_remote_pi_sessions(
    ssh: &SshClient,
    shell: RemoteShell,
) -> Result<Vec<PiSessionInfo>, SshBridgeError> {
    let script = format!("{PROFILE_INIT}\n{REMOTE_PI_SESSION_SCAN}");
    let result = ssh.exec_shell(&script, shell).await?;
    if result.exit_code != 0 {
        return Err(SshBridgeError::Transport(nonempty_stderr_or_stdout(result)));
    }
    Ok(parse_remote_pi_scan(&result.stdout)
        .into_iter()
        .map(|session| {
            let modified = datetime_from_millis(session.modified_ms);
            PiSessionInfo {
                path: PathBuf::from(session.path),
                id: session.session_id,
                cwd: session.cwd,
                name: session.name.filter(|name| !name.trim().is_empty()),
                parent_session_path: session.parent_session_path.map(PathBuf::from),
                created: parse_rfc3339_or_default(&session.created, modified),
                modified,
                message_count: session.message_count,
                first_message: default_first_message(&session.first_message),
                all_messages_text: session.first_message,
            }
        })
        .collect())
}

fn datetime_from_millis(ms: i64) -> DateTime<Utc> {
    if ms <= 0 {
        return Utc::now();
    }
    DateTime::<Utc>::from_timestamp_millis(ms).unwrap_or_else(Utc::now)
}

fn parse_rfc3339_or_default(value: &str, fallback: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(fallback)
}

fn parse_remote_claude_scan(stdout: &str) -> Vec<RemoteClaudeSession> {
    stdout
        .lines()
        .filter_map(|line| {
            let fields = line.split('\t').collect::<Vec<_>>();
            if fields.len() < 7 || fields[0] != "C" {
                return None;
            }
            Some(RemoteClaudeSession {
                path: fields[1].to_string(),
                session_id: fields[2].to_string(),
                cwd: fields[3].to_string(),
                created_ms: parse_i64_field(fields[4]),
                modified_ms: parse_i64_field(fields[5]),
                first_message: default_first_message(fields[6]),
            })
        })
        .collect()
}

fn parse_remote_pi_scan(stdout: &str) -> Vec<RemotePiSession> {
    stdout
        .lines()
        .filter_map(|line| {
            let fields = line.split('\t').collect::<Vec<_>>();
            if fields.len() < 9 || fields[0] != "P" {
                return None;
            }
            Some(RemotePiSession {
                path: fields[1].to_string(),
                session_id: fields[2].to_string(),
                cwd: fields[3].to_string(),
                parent_session_path: nonempty_string(fields[4]),
                created: fields[5].to_string(),
                modified_ms: parse_i64_field(fields[6]),
                message_count: fields[7].parse().unwrap_or(0),
                name: nonempty_string(fields[8]),
                first_message: fields.get(9).copied().unwrap_or_default().to_string(),
            })
        })
        .collect()
}

fn nonempty_string(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

fn parse_i64_field(value: &str) -> i64 {
    value.parse().unwrap_or(0)
}

fn default_first_message(value: &str) -> String {
    let value = value.trim();
    if value.is_empty() {
        "(no messages)".to_string()
    } else {
        value.to_string()
    }
}

const REMOTE_CLAUDE_SESSION_SCAN: &str = crate::ssh_scripts::posix::CLAUDE_SESSION_SCAN;
const REMOTE_PI_SESSION_SCAN: &str = crate::ssh_scripts::posix::PI_SESSION_SCAN;

async fn spawn_remote_opencode(
    ssh: &SshClient,
    shell: RemoteShell,
    bin: &str,
    port: u16,
    session_id: &str,
) -> Result<(), SshBridgeError> {
    let port_str = port.to_string();
    let bin_quoted = shell_quote(bin);
    let script = crate::ssh_scripts::render(
        crate::ssh_scripts::posix::OPENCODE_SPAWN,
        &[
            ("PROFILE_INIT", PROFILE_INIT),
            ("SESSION_ID", session_id),
            ("BIN", &bin_quoted),
            ("PORT", &port_str),
        ],
    );
    let result = ssh.exec_shell(&script, shell).await?;
    if result.exit_code == 0 {
        Ok(())
    } else {
        Err(SshBridgeError::BridgeStartupFailed(
            nonempty_stderr_or_stdout(result),
        ))
    }
}

async fn wait_until_remote_opencode_healthy(
    ssh: &SshClient,
    shell: RemoteShell,
    port: u16,
    session_id: &str,
) -> Result<(), SshBridgeError> {
    let port_str = port.to_string();
    let script = crate::ssh_scripts::render(
        crate::ssh_scripts::posix::OPENCODE_HEALTH_WAIT,
        &[
            ("PROFILE_INIT", PROFILE_INIT),
            ("SESSION_ID", session_id),
            ("PORT", &port_str),
        ],
    );
    let result = ssh.exec_shell(&script, shell).await?;
    if result.exit_code == 0 {
        Ok(())
    } else {
        Err(SshBridgeError::BridgeStartupFailed(
            nonempty_stderr_or_stdout(result),
        ))
    }
}

async fn wait_until_opencode_healthy(base_url: &str) -> Result<(), SshBridgeError> {
    let client = reqwest::Client::new();
    let url = format!("{}/global/health", base_url.trim_end_matches('/'));
    let deadline = Instant::now() + OPENCODE_LOCAL_HEALTH_BUDGET;
    loop {
        if let Ok(resp) = client.get(&url).send().await
            && resp.status().is_success()
            && let Ok(body) = resp.json::<serde_json::Value>().await
            && body.get("healthy").and_then(serde_json::Value::as_bool) == Some(true)
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(SshBridgeError::BridgeStartupFailed(format!(
                "opencode did not become healthy at {url}"
            )));
        }
        tokio::time::sleep(OPENCODE_LOCAL_HEALTH_INTERVAL).await;
    }
}

async fn fetch_remote_opencode_logs(
    ssh: &SshClient,
    shell: RemoteShell,
    session_id: &str,
) -> Result<String, SshBridgeError> {
    let script = crate::ssh_scripts::render(
        crate::ssh_scripts::posix::OPENCODE_LOGS,
        &[("PROFILE_INIT", PROFILE_INIT), ("SESSION_ID", session_id)],
    );
    let result = ssh.exec_shell(&script, shell).await?;
    Ok(nonempty_stdout_or_stderr(result))
}

fn parse_agent_probe(stdout: &str) -> Vec<RemoteAgentAvailability> {
    stdout
        .lines()
        .filter_map(|line| {
            let (cmd, path) = line.split_once('\t').unwrap_or((line, ""));
            let kind = match cmd {
                "claude" => AgentRuntimeKind::Claude,
                "pi" | "pi-coding-agent" => AgentRuntimeKind::Pi,
                "opencode" => AgentRuntimeKind::Opencode,
                "codex" => AgentRuntimeKind::Codex,
                _ => return None,
            };
            let status = if path.trim().is_empty() {
                AgentAvailabilityStatus::AgentCliMissing
            } else {
                AgentAvailabilityStatus::Available
            };
            Some(RemoteAgentAvailability { kind, status })
        })
        .collect()
}

async fn pick_remote_port(ssh: &SshClient, shell: RemoteShell) -> Result<u16, SshBridgeError> {
    let start = fallback_remote_port();
    for offset in 0..REMOTE_PORT_PROBE_CANDIDATES {
        let port = REMOTE_PORT_PROBE_BASE
            + ((start - REMOTE_PORT_PROBE_BASE + offset) % REMOTE_PORT_PROBE_SPAN);
        if remote_port_looks_free(ssh, shell, port).await? {
            return Ok(port);
        }
    }
    debug!(
        "remote free-port probe failed, falling back to time-derived port: {}",
        start
    );
    Ok(start)
}

async fn remote_port_looks_free(
    ssh: &SshClient,
    shell: RemoteShell,
    port: u16,
) -> Result<bool, SshBridgeError> {
    let port_str = port.to_string();
    let script = format!(
        "{PROFILE_INIT}\n{}",
        crate::ssh_scripts::render(
            crate::ssh_scripts::posix::REMOTE_PORT_FREE_PROBE,
            &[("PORT", &port_str)],
        )
    );
    let result = ssh.exec_shell(&script, shell).await?;
    Ok(result.exit_code == 0)
}

fn fallback_remote_port() -> u16 {
    let span = now_millis() % 2000;
    17600 + span as u16
}

fn nonempty_stderr_or_stdout(result: crate::ssh::ExecResult) -> String {
    if result.stderr.trim().is_empty() {
        result.stdout
    } else if result.stdout.trim().is_empty() {
        result.stderr
    } else {
        format!("{}\n{}", result.stderr, result.stdout)
    }
}

fn nonempty_stdout_or_stderr(result: crate::ssh::ExecResult) -> String {
    if result.stdout.trim().is_empty() {
        result.stderr
    } else if result.stderr.trim().is_empty() {
        result.stdout
    } else {
        format!("{}\n{}", result.stdout, result.stderr)
    }
}

fn now_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

pub fn runtime_label(kind: AgentRuntimeKind) -> &'static str {
    match kind {
        AgentRuntimeKind::Codex => "codex",
        AgentRuntimeKind::Pi => "pi",
        AgentRuntimeKind::Opencode => "opencode",
        AgentRuntimeKind::Claude => "claude",
    }
}

fn runtime_display_name(kind: AgentRuntimeKind) -> &'static str {
    match kind {
        AgentRuntimeKind::Codex => "Codex",
        AgentRuntimeKind::Pi => "Pi",
        AgentRuntimeKind::Opencode => "OpenCode",
        AgentRuntimeKind::Claude => "Claude",
    }
}
