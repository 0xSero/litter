//! Shared reconnection logic for iOS and Android.
//!
//! Consolidates the duplicated transport-resolution and reconnect-plan
//! computation that previously lived in platform Swift/Kotlin code.

use crate::alleycat::{AgentWire as AlleycatAgentWire, ParsedPairPayload as AlleycatPairPayload};
use crate::mobile_client::MobileClient;
use crate::session::connection::{InProcessConfig, ServerConfig};
use crate::ssh::{SshAuth, SshClient, SshCredentials};
use crate::types::AgentRuntimeKind;
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{info, warn};

// ── UniFFI boundary types ───────────────────────────────────────────────

/// Mirrors the platform `SavedServer` data class / struct.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SavedServerRecord {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub port: u16,
    pub codex_ports: Vec<u16>,
    pub ssh_port: Option<u16>,
    pub source: String,
    pub has_codex_server: bool,
    pub wake_mac: Option<String>,
    pub preferred_connection_mode: Option<String>,
    pub preferred_codex_port: Option<u16>,
    pub ssh_port_forwarding_enabled: Option<bool>,
    pub websocket_url: Option<String>,
    pub remembered_by_user: bool,
    /// Legacy Alleycat marker. Unsupported after the iroh-backed host migration;
    /// records with only these fields require a new pairing scan.
    pub alleycat_host: Option<String>,
    /// Legacy Alleycat relay UDP port.
    pub alleycat_udp_port: Option<u16>,
    pub alleycat_node_id: Option<String>,
    pub alleycat_token: Option<String>,
    pub alleycat_relay: Option<String>,
    pub alleycat_agent_name: Option<String>,
    pub alleycat_agent_wire: Option<String>,
}

/// SSH auth method discriminator.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum SshAuthMethodRecord {
    Password,
    Key,
}

/// SSH credential record passed across the FFI boundary.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SshCredentialRecord {
    pub username: String,
    pub auth_method: SshAuthMethodRecord,
    pub password: Option<String>,
    pub private_key_pem: Option<String>,
    pub passphrase: Option<String>,
    pub unlock_macos_keychain: bool,
}

/// Result of a single server reconnection attempt.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ReconnectResult {
    pub server_id: String,
    pub success: bool,
    pub needs_local_auth_restore: bool,
    pub error_message: Option<String>,
}

/// Callback interface for platform-side SSH credential storage.
#[uniffi::export(callback_interface)]
pub trait SshCredentialProvider: Send + Sync {
    fn load_credential(&self, host: String, port: u16) -> Option<SshCredentialRecord>;
}

// ── Internal reconnect plan ─────────────────────────────────────────────

#[derive(Clone, Debug)]
pub(crate) enum ReconnectPlan {
    Ssh {
        server_id: String,
        display_name: String,
        host: String,
        ssh_port: u16,
        credential: SshCredentialRecord,
    },
    SshBridge {
        server_id: String,
        display_name: String,
        host: String,
        ssh_port: u16,
        credential: SshCredentialRecord,
        runtime_kinds: Vec<AgentRuntimeKind>,
    },
    Local {
        server_id: String,
        display_name: String,
    },
    DirectRemote {
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    },
    RemoteUrl {
        server_id: String,
        display_name: String,
        websocket_url: String,
    },
    Alleycat {
        server_id: String,
        display_name: String,
        params: AlleycatPairPayload,
        agent_name: String,
        wire: AlleycatAgentWire,
    },
}

// ── Transport resolution helpers ────────────────────────────────────────

/// Resolve the effective preferred connection mode, handling legacy
/// `ssh_port_forwarding_enabled` migration.
///
/// Mirrors iOS `migratedPreferredConnectionMode` and Android
/// `resolvedPreferredConnectionMode` (simplified — the full Android version
/// also validates that the mode is still reachable, but for reconnect
/// planning the raw preference is what matters since we skip if no
/// credential is available anyway).
pub(crate) fn resolved_preferred_connection_mode(server: &SavedServerRecord) -> Option<String> {
    if let Some(ref mode) = server.preferred_connection_mode {
        return Some(mode.clone());
    }
    if server.ssh_port_forwarding_enabled == Some(true) {
        return Some("ssh".to_string());
    }
    None
}

/// Resolve the SSH port for a saved server.
///
/// Mirrors Android `resolvedSshPort`:
///   `sshPort ?: port.takeIf { !hasCodexServer && it > 0 } ?: 22`
/// and iOS `SavedServer.toDiscoveredServer()` → `DiscoveredServer.resolvedSSHPort`:
///   `sshPort ?? (hasCodexServer ? nil : port)` then `?? 22`
pub(crate) fn resolved_ssh_port(server: &SavedServerRecord) -> u16 {
    if let Some(port) = server.ssh_port {
        return port;
    }
    if !server.has_codex_server && server.port > 0 {
        return server.port;
    }
    22
}

/// Build the list of available direct Codex ports (merging port + codex_ports).
///
/// Mirrors Android `availableDirectCodexPorts`.
fn available_direct_codex_ports(server: &SavedServerRecord) -> Vec<u16> {
    let mut ordered = Vec::new();
    if server.has_codex_server && server.port > 0 {
        ordered.push(server.port);
    }
    for &p in &server.codex_ports {
        if p > 0 && !ordered.contains(&p) {
            ordered.push(p);
        }
    }
    ordered
}

/// Whether the server prefers SSH connections.
fn prefers_ssh(server: &SavedServerRecord) -> bool {
    resolved_preferred_connection_mode(server).as_deref() == Some("ssh")
}

/// Whether the server requires user to choose a connection mode before
/// we can auto-connect.
fn requires_connection_choice(server: &SavedServerRecord) -> bool {
    if server.websocket_url.is_some() {
        return false;
    }
    let mode = resolved_preferred_connection_mode(server);
    if mode.is_some() {
        return false;
    }
    let ports = available_direct_codex_ports(server);
    let can_ssh = can_connect_via_ssh(server);
    ports.len() > 1 || (!ports.is_empty() && can_ssh)
}

/// Whether SSH is a viable transport for this server.
fn can_connect_via_ssh(server: &SavedServerRecord) -> bool {
    if server.websocket_url.is_some() {
        return false;
    }
    server.ssh_port.is_some()
        || server.source == "ssh"
        || (!server.has_codex_server && resolved_ssh_port(server) > 0)
        || server.preferred_connection_mode.as_deref() == Some("ssh")
        || server.ssh_port_forwarding_enabled == Some(true)
}

/// Resolve the preferred codex port for direct-codex mode.
fn resolved_preferred_codex_port(server: &SavedServerRecord) -> Option<u16> {
    if resolved_preferred_connection_mode(server).as_deref() != Some("directCodex") {
        return None;
    }
    let ports = available_direct_codex_ports(server);
    if let Some(pref) = server.preferred_codex_port {
        if ports.contains(&pref) {
            return Some(pref);
        }
    }
    None
}

/// Resolve the direct Codex port for a saved server.
///
/// Returns `None` when SSH is preferred, when the user needs to choose,
/// or when no direct port is available.
///
/// Mirrors Android `directCodexPort`.
pub(crate) fn direct_codex_port(server: &SavedServerRecord) -> Option<u16> {
    if server.websocket_url.is_some() {
        return None;
    }
    if prefers_ssh(server) {
        return None;
    }
    if let Some(port) = resolved_preferred_codex_port(server) {
        return Some(port);
    }
    if requires_connection_choice(server) {
        return None;
    }
    let ports = available_direct_codex_ports(server);
    ports.first().copied()
}

// ── Plan computation ────────────────────────────────────────────────────

/// Compute the reconnect plan for a single saved server.
///
/// Consolidates iOS `reconnectPlan(for:)` and Android
/// `reconnectSavedServer` into a single decision tree.
pub(crate) fn compute_reconnect_plan(
    server: &SavedServerRecord,
    credential: Option<&SshCredentialRecord>,
    is_connected: bool,
    multi_clanker_and_quic_enabled: bool,
) -> Option<ReconnectPlan> {
    // 1. Skip if already connected
    if is_connected {
        return None;
    }

    // 2. Stable Alleycat pairing wins before legacy tunnel/direct transports.
    if multi_clanker_and_quic_enabled {
        if let (Some(node_id), Some(token), Some(agent_name)) = (
            server.alleycat_node_id.as_ref(),
            server.alleycat_token.as_ref(),
            server.alleycat_agent_name.as_ref(),
        ) {
            let wire = match server.alleycat_agent_wire.as_deref() {
                Some("jsonl") => AlleycatAgentWire::Jsonl,
                _ => AlleycatAgentWire::Websocket,
            };
            return Some(ReconnectPlan::Alleycat {
                server_id: server.id.clone(),
                display_name: server.name.clone(),
                params: AlleycatPairPayload {
                    version: crate::alleycat::ALLEYCAT_PROTOCOL_VERSION,
                    node_id: node_id.clone(),
                    token: token.clone(),
                    relay: server.alleycat_relay.clone(),
                    host_name: None,
                },
                agent_name: agent_name.clone(),
                wire,
            });
        }
    }

    // 3. SSH bridge records need to reconnect as the multiplexed in-process
    // bridge group. Falling through to the legacy SSH plan would only
    // bootstrap direct Codex.
    if multi_clanker_and_quic_enabled && is_ssh_bridge_record(server) {
        if let Some(cred) = credential {
            return Some(ReconnectPlan::SshBridge {
                server_id: server.id.clone(),
                display_name: server.name.clone(),
                host: server.hostname.clone(),
                ssh_port: resolved_ssh_port(server),
                credential: cred.clone(),
                runtime_kinds: parse_ssh_bridge_runtime_kinds(
                    server.alleycat_agent_name.as_deref(),
                ),
            });
        }
        return None;
    }

    // 4. WebSocket URL override → RemoteUrl
    if let Some(ref ws_url) = server.websocket_url {
        return Some(ReconnectPlan::RemoteUrl {
            server_id: server.id.clone(),
            display_name: server.name.clone(),
            websocket_url: ws_url.clone(),
        });
    }

    let mode = resolved_preferred_connection_mode(server);

    // 5. Explicit SSH mode + credential → Ssh
    if mode.as_deref() == Some("ssh") {
        if let Some(cred) = credential {
            return Some(ReconnectPlan::Ssh {
                server_id: server.id.clone(),
                display_name: server.name.clone(),
                host: server.hostname.clone(),
                ssh_port: resolved_ssh_port(server),
                credential: cred.clone(),
            });
        }
        // SSH preferred but no credential — cannot reconnect
        return None;
    }

    // 6. Direct Codex port available → DirectRemote
    if let Some(port) = direct_codex_port(server) {
        return Some(ReconnectPlan::DirectRemote {
            server_id: server.id.clone(),
            display_name: server.name.clone(),
            host: server.hostname.clone(),
            port,
        });
    }

    // 7. No explicit mode, but credential available → SSH (legacy fallback)
    if mode.is_none() {
        if let Some(cred) = credential {
            return Some(ReconnectPlan::Ssh {
                server_id: server.id.clone(),
                display_name: server.name.clone(),
                host: server.hostname.clone(),
                ssh_port: resolved_ssh_port(server),
                credential: cred.clone(),
            });
        }
    }

    // 8. Local source → Local
    if server.source == "local" {
        return Some(ReconnectPlan::Local {
            server_id: server.id.clone(),
            display_name: server.name.clone(),
        });
    }

    // 9. No viable transport
    None
}

// ── Plan execution ──────────────────────────────────────────────────────

/// Execute a single reconnect plan against the shared `MobileClient`.
pub(crate) async fn execute_reconnect_plan(
    plan: &ReconnectPlan,
    client: &MobileClient,
    ipc_override: Option<String>,
) -> ReconnectResult {
    match plan {
        ReconnectPlan::Ssh {
            server_id,
            display_name,
            host,
            ssh_port,
            credential,
        } => {
            info!(
                "reconnect: executing SSH plan server_id={} host={} ssh_port={}",
                server_id, host, ssh_port
            );
            let auth = match credential.auth_method {
                SshAuthMethodRecord::Password => {
                    SshAuth::Password(credential.password.clone().unwrap_or_default())
                }
                SshAuthMethodRecord::Key => SshAuth::PrivateKey {
                    key_pem: credential.private_key_pem.clone().unwrap_or_default(),
                    passphrase: credential.passphrase.clone(),
                },
            };
            let ssh_creds = SshCredentials {
                host: host.clone(),
                port: *ssh_port,
                username: credential.username.clone(),
                auth,
                unlock_macos_keychain: credential.unlock_macos_keychain,
            };
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: host.clone(),
                port: 0,
                websocket_url: None,
                is_local: false,
                tls: false,
            };
            match client
                .connect_remote_over_ssh(config, ssh_creds, true, None, ipc_override)
                .await
            {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: SSH plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::SshBridge {
            server_id,
            display_name,
            host,
            ssh_port,
            credential,
            runtime_kinds,
        } => {
            info!(
                "reconnect: executing SSH bridge plan server_id={} host={} ssh_port={} runtimes={:?}",
                server_id, host, ssh_port, runtime_kinds
            );
            let auth = match credential.auth_method {
                SshAuthMethodRecord::Password => {
                    SshAuth::Password(credential.password.clone().unwrap_or_default())
                }
                SshAuthMethodRecord::Key => SshAuth::PrivateKey {
                    key_pem: credential.private_key_pem.clone().unwrap_or_default(),
                    passphrase: credential.passphrase.clone(),
                },
            };
            let ssh_creds = SshCredentials {
                host: host.clone(),
                port: *ssh_port,
                username: credential.username.clone(),
                auth,
                unlock_macos_keychain: credential.unlock_macos_keychain,
            };
            let ssh_client = match SshClient::connect(
                ssh_creds,
                Box::new(move |_fingerprint| Box::pin(async move { true })),
            )
            .await
            {
                Ok(client) => Arc::new(client),
                Err(e) => {
                    warn!(
                        "reconnect: SSH bridge plan failed to connect server_id={} error={}",
                        server_id, e
                    );
                    return ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    };
                }
            };
            let selected =
                resolve_ssh_bridge_runtime_kinds(Arc::clone(&ssh_client), runtime_kinds).await;
            let state_root = match ssh_bridge_state_root(host) {
                Ok(path) => path,
                Err(error) => {
                    return ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(error),
                    };
                }
            };
            match client
                .connect_remote_over_ssh_bridges(
                    ssh_client,
                    server_id.clone(),
                    display_name.clone(),
                    host.clone(),
                    state_root,
                    selected,
                    crate::ssh_bridge::SshBridgeTransport::Ephemeral,
                )
                .await
            {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: SSH bridge plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::Local {
            server_id,
            display_name,
        } => {
            info!("reconnect: executing Local plan server_id={}", server_id);
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: "127.0.0.1".to_string(),
                port: 0,
                websocket_url: None,
                is_local: true,
                tls: false,
            };
            match client
                .connect_local(config, InProcessConfig::default())
                .await
            {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: true,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: Local plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::DirectRemote {
            server_id,
            display_name,
            host,
            port,
        } => {
            info!(
                "reconnect: executing DirectRemote plan server_id={} host={} port={}",
                server_id, host, port
            );
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: host.clone(),
                port: *port,
                websocket_url: None,
                is_local: false,
                tls: false,
            };
            match client.connect_remote(config).await {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: DirectRemote plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::RemoteUrl {
            server_id,
            display_name,
            websocket_url,
        } => {
            info!(
                "reconnect: executing RemoteUrl plan server_id={} url={}",
                server_id, websocket_url
            );
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: String::new(),
                port: 0,
                websocket_url: Some(websocket_url.clone()),
                is_local: false,
                tls: false,
            };
            match client.connect_remote(config).await {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: RemoteUrl plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::Alleycat {
            server_id,
            display_name,
            params,
            agent_name,
            wire,
        } => {
            info!(
                "reconnect: executing Alleycat plan server_id={} node_id={} agent={}",
                server_id, params.node_id, agent_name
            );
            match client
                .connect_remote_over_alleycat(
                    server_id.clone(),
                    display_name.clone(),
                    params.clone(),
                    agent_name.clone(),
                    split_agent_names(agent_name),
                    *wire,
                )
                .await
            {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: Alleycat plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
    }
}

fn is_ssh_bridge_record(server: &SavedServerRecord) -> bool {
    server.id.starts_with("ssh-bridge:")
        || server.alleycat_agent_wire.as_deref() == Some("ssh-bridge")
        || server
            .websocket_url
            .as_deref()
            .is_some_and(|url| url.starts_with("ssh-bridge://"))
}

fn parse_ssh_bridge_runtime_kinds(value: Option<&str>) -> Vec<AgentRuntimeKind> {
    value
        .unwrap_or_default()
        .split(',')
        .filter_map(|part| match part.trim().to_ascii_lowercase().as_str() {
            "codex" => Some(AgentRuntimeKind::Codex),
            "claude" => Some(AgentRuntimeKind::Claude),
            "pi" => Some(AgentRuntimeKind::Pi),
            "opencode" | "open-code" | "open_code" => Some(AgentRuntimeKind::Opencode),
            _ => None,
        })
        .fold(Vec::new(), |mut acc, kind| {
            if !acc.contains(&kind) {
                acc.push(kind);
            }
            acc
        })
}

async fn resolve_ssh_bridge_runtime_kinds(
    ssh_client: Arc<SshClient>,
    requested: &[AgentRuntimeKind],
) -> Vec<AgentRuntimeKind> {
    let availability = crate::ssh_bridge::probe_remote_agents(&ssh_client)
        .await
        .unwrap_or_default();
    info!(
        "reconnect: SSH bridge agent availability requested={:?} availability={:?}",
        requested, availability
    );
    let available = |kind: AgentRuntimeKind| {
        kind == AgentRuntimeKind::Codex
            || availability.iter().any(|entry| {
                entry.kind == kind
                    && entry.status == crate::ssh_bridge::AgentAvailabilityStatus::Available
            })
    };

    let candidates = if requested.is_empty() {
        vec![
            AgentRuntimeKind::Claude,
            AgentRuntimeKind::Pi,
            AgentRuntimeKind::Opencode,
            AgentRuntimeKind::Codex,
        ]
    } else {
        requested.to_vec()
    };
    let mut selected =
        candidates
            .into_iter()
            .filter(|kind| available(*kind))
            .fold(Vec::new(), |mut acc, kind| {
                if !acc.contains(&kind) {
                    acc.push(kind);
                }
                acc
            });
    if selected.is_empty() {
        selected.push(AgentRuntimeKind::Codex);
    }
    info!(
        "reconnect: SSH bridge selected runtimes requested={:?} selected={:?}",
        requested, selected
    );
    selected
}

fn ssh_bridge_state_root(host: &str) -> Result<String, String> {
    let base = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library").join("Application Support"))
        .unwrap_or_else(std::env::temp_dir);
    let path = base
        .join("alleycat-bridges")
        .join(percent_encode_alphanumeric(host));
    std::fs::create_dir_all(&path)
        .map_err(|error| format!("failed to create SSH bridge state dir {:?}: {error}", path))?;
    Ok(path.to_string_lossy().into_owned())
}

fn percent_encode_alphanumeric(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        if byte.is_ascii_alphanumeric() {
            encoded.push(char::from(*byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn split_agent_names(agent_name: &str) -> Vec<String> {
    agent_name
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

// ── Unit tests ──────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn base_server() -> SavedServerRecord {
        SavedServerRecord {
            id: "srv-1".into(),
            name: "Test Server".into(),
            hostname: "192.168.1.100".into(),
            port: 8080,
            codex_ports: vec![],
            ssh_port: None,
            source: "manual".into(),
            has_codex_server: true,
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
        }
    }

    fn ssh_credential() -> SshCredentialRecord {
        SshCredentialRecord {
            username: "user".into(),
            auth_method: SshAuthMethodRecord::Password,
            password: Some("pass".into()),
            private_key_pem: None,
            passphrase: None,
            unlock_macos_keychain: false,
        }
    }

    // -- resolved_preferred_connection_mode tests --

    #[test]
    fn resolved_mode_explicit_ssh() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        assert_eq!(
            resolved_preferred_connection_mode(&s).as_deref(),
            Some("ssh")
        );
    }

    #[test]
    fn resolved_mode_explicit_direct_codex() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("directCodex".into());
        assert_eq!(
            resolved_preferred_connection_mode(&s).as_deref(),
            Some("directCodex")
        );
    }

    #[test]
    fn resolved_mode_legacy_ssh_port_forwarding_enabled() {
        let mut s = base_server();
        s.ssh_port_forwarding_enabled = Some(true);
        assert_eq!(
            resolved_preferred_connection_mode(&s).as_deref(),
            Some("ssh")
        );
    }

    #[test]
    fn resolved_mode_legacy_ssh_port_forwarding_disabled() {
        let mut s = base_server();
        s.ssh_port_forwarding_enabled = Some(false);
        assert!(resolved_preferred_connection_mode(&s).is_none());
    }

    #[test]
    fn resolved_mode_none_when_no_preference() {
        let s = base_server();
        assert!(resolved_preferred_connection_mode(&s).is_none());
    }

    // -- resolved_ssh_port tests --

    #[test]
    fn resolved_ssh_port_explicit() {
        let mut s = base_server();
        s.ssh_port = Some(2222);
        assert_eq!(resolved_ssh_port(&s), 2222);
    }

    #[test]
    fn resolved_ssh_port_fallback_to_port_when_no_codex() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 3333;
        assert_eq!(resolved_ssh_port(&s), 3333);
    }

    #[test]
    fn resolved_ssh_port_default_22_when_has_codex() {
        let s = base_server();
        assert_eq!(resolved_ssh_port(&s), 22);
    }

    #[test]
    fn resolved_ssh_port_default_22_when_port_zero() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 0;
        assert_eq!(resolved_ssh_port(&s), 22);
    }

    // -- direct_codex_port tests --

    #[test]
    fn direct_codex_port_returns_port_when_has_codex() {
        let s = base_server();
        // has_codex_server=true, port=8080, no SSH preference → port 8080
        assert_eq!(direct_codex_port(&s), Some(8080));
    }

    #[test]
    fn direct_codex_port_none_when_ssh_preferred() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        assert_eq!(direct_codex_port(&s), None);
    }

    #[test]
    fn direct_codex_port_preferred_codex_port_in_direct_mode() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("directCodex".into());
        s.codex_ports = vec![9090, 9091];
        s.preferred_codex_port = Some(9091);
        assert_eq!(direct_codex_port(&s), Some(9091));
    }

    #[test]
    fn direct_codex_port_none_when_requires_choice() {
        let mut s = base_server();
        // Two ports + SSH available + no preferred mode → requires choice
        s.codex_ports = vec![9090, 9091];
        s.ssh_port = Some(22);
        assert_eq!(direct_codex_port(&s), None);
    }

    #[test]
    fn direct_codex_port_none_when_no_codex() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 22;
        s.codex_ports = vec![];
        assert_eq!(direct_codex_port(&s), None);
    }

    #[test]
    fn direct_codex_port_none_when_websocket_url() {
        let mut s = base_server();
        s.websocket_url = Some("wss://example.com/ws".into());
        assert_eq!(direct_codex_port(&s), None);
    }

    // -- compute_reconnect_plan tests --

    #[test]
    fn plan_skip_when_connected() {
        let s = base_server();
        assert!(compute_reconnect_plan(&s, None, true, false).is_none());
    }

    #[test]
    fn plan_remote_url_when_websocket_set() {
        let mut s = base_server();
        s.websocket_url = Some("wss://example.com/ws".into());
        let plan = compute_reconnect_plan(&s, None, false, false);
        assert!(matches!(plan, Some(ReconnectPlan::RemoteUrl { .. })));
    }

    #[test]
    fn plan_alleycat_when_saved_pairing_has_token_and_agent() {
        let mut s = base_server();
        s.alleycat_node_id = Some("node123".into());
        s.alleycat_token = Some("token123".into());
        s.alleycat_relay = Some("https://relay.example".into());
        s.alleycat_agent_name = Some("pi".into());
        s.alleycat_agent_wire = Some("jsonl".into());
        s.websocket_url = Some("wss://should-not-win.example/ws".into());

        let plan = compute_reconnect_plan(&s, None, false, true);

        match plan {
            Some(ReconnectPlan::Alleycat {
                server_id,
                display_name,
                params,
                agent_name,
                wire,
            }) => {
                assert_eq!(server_id, "srv-1");
                assert_eq!(display_name, "Test Server");
                assert_eq!(params.node_id, "node123");
                assert_eq!(params.token, "token123");
                assert_eq!(params.relay.as_deref(), Some("https://relay.example"));
                assert_eq!(agent_name, "pi");
                assert_eq!(wire, AlleycatAgentWire::Jsonl);
            }
            other => panic!("expected alleycat reconnect plan, got {other:?}"),
        }
    }

    #[test]
    fn plan_alleycat_defaults_wire_to_websocket() {
        let mut s = base_server();
        s.alleycat_node_id = Some("node123".into());
        s.alleycat_token = Some("token123".into());
        s.alleycat_agent_name = Some("codex".into());

        let plan = compute_reconnect_plan(&s, None, false, true);

        match plan {
            Some(ReconnectPlan::Alleycat { wire, .. }) => {
                assert_eq!(wire, AlleycatAgentWire::Websocket)
            }
            other => panic!("expected alleycat reconnect plan, got {other:?}"),
        }
    }

    #[test]
    fn plan_alleycat_disabled_falls_through_to_direct_remote() {
        let mut s = base_server();
        s.alleycat_node_id = Some("node123".into());
        s.alleycat_token = Some("token123".into());
        s.alleycat_agent_name = Some("pi".into());
        s.port = 8390;
        s.codex_ports = vec![8390];

        let plan = compute_reconnect_plan(&s, None, false, false);

        assert!(matches!(plan, Some(ReconnectPlan::DirectRemote { .. })));
    }

    #[test]
    fn plan_alleycat_disabled_without_transport_is_skipped() {
        let mut s = base_server();
        s.alleycat_node_id = Some("node123".into());
        s.alleycat_token = Some("token123".into());
        s.alleycat_agent_name = Some("pi".into());
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];

        assert!(compute_reconnect_plan(&s, None, false, false).is_none());
    }

    #[test]
    fn plan_ssh_when_mode_is_ssh_and_credential() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        let cred = ssh_credential();
        let plan = compute_reconnect_plan(&s, Some(&cred), false, false);
        assert!(matches!(plan, Some(ReconnectPlan::Ssh { .. })));
    }

    #[test]
    fn plan_none_when_mode_is_ssh_but_no_credential() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        assert!(compute_reconnect_plan(&s, None, false, false).is_none());
    }

    #[test]
    fn plan_direct_remote_when_port_available() {
        let s = base_server();
        let plan = compute_reconnect_plan(&s, None, false, false);
        assert!(matches!(plan, Some(ReconnectPlan::DirectRemote { .. })));
        if let Some(ReconnectPlan::DirectRemote { port, .. }) = plan {
            assert_eq!(port, 8080);
        }
    }

    #[test]
    fn plan_ssh_legacy_fallback_when_no_mode_but_credential() {
        let mut s = base_server();
        // No explicit mode, no direct codex port available, but has credential
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];
        let cred = ssh_credential();
        let plan = compute_reconnect_plan(&s, Some(&cred), false, false);
        assert!(matches!(plan, Some(ReconnectPlan::Ssh { .. })));
    }

    #[test]
    fn plan_local_when_source_is_local() {
        let mut s = base_server();
        s.source = "local".into();
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];
        let plan = compute_reconnect_plan(&s, None, false, false);
        assert!(matches!(plan, Some(ReconnectPlan::Local { .. })));
    }

    #[test]
    fn plan_none_when_no_viable_transport() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];
        s.source = "manual".into();
        assert!(compute_reconnect_plan(&s, None, false, false).is_none());
    }

    #[test]
    fn plan_legacy_alleycat_record_falls_through_to_direct_transport() {
        let mut s = base_server();
        s.has_codex_server = true;
        s.port = 8390;
        s.codex_ports = vec![8390];
        s.alleycat_host = Some("studio.tail.ts.net".into());
        s.alleycat_udp_port = Some(51820);

        let plan = compute_reconnect_plan(&s, None, false, false);
        assert!(matches!(plan, Some(ReconnectPlan::DirectRemote { .. })));
    }

    #[test]
    fn plan_legacy_alleycat_record_requires_new_pairing_when_no_transport() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];
        s.alleycat_host = Some("studio.tail.ts.net".into());
        s.alleycat_udp_port = Some(51820);

        assert!(compute_reconnect_plan(&s, None, false, false).is_none());
    }

    #[test]
    fn plan_legacy_alleycat_record_skipped_when_already_connected() {
        let mut s = base_server();
        s.alleycat_host = Some("studio.tail.ts.net".into());
        s.alleycat_udp_port = Some(51820);
        assert!(compute_reconnect_plan(&s, None, true, false).is_none());
    }

    #[test]
    fn plan_ssh_bridge_enabled_uses_bridge_plan() {
        let mut s = base_server();
        s.id = "ssh-bridge:studio".into();
        s.hostname = "studio".into();
        s.port = 0;
        s.codex_ports = vec![];
        s.ssh_port = Some(22);
        s.preferred_connection_mode = Some("ssh".into());
        s.alleycat_agent_name = Some("pi,opencode".into());
        s.alleycat_agent_wire = Some("ssh-bridge".into());
        let cred = ssh_credential();

        let plan = compute_reconnect_plan(&s, Some(&cred), false, true);

        match plan {
            Some(ReconnectPlan::SshBridge { runtime_kinds, .. }) => {
                assert_eq!(
                    runtime_kinds,
                    vec![AgentRuntimeKind::Pi, AgentRuntimeKind::Opencode]
                );
            }
            other => panic!("expected ssh bridge reconnect plan, got {other:?}"),
        }
    }

    #[test]
    fn plan_ssh_bridge_disabled_uses_codex_ssh_plan() {
        let mut s = base_server();
        s.id = "ssh-bridge:studio".into();
        s.hostname = "studio".into();
        s.port = 0;
        s.codex_ports = vec![];
        s.ssh_port = Some(22);
        s.preferred_connection_mode = Some("ssh".into());
        s.alleycat_agent_name = Some("pi,opencode".into());
        s.alleycat_agent_wire = Some("ssh-bridge".into());
        let cred = ssh_credential();

        let plan = compute_reconnect_plan(&s, Some(&cred), false, false);

        assert!(matches!(plan, Some(ReconnectPlan::Ssh { .. })));
    }
}
