//! SSH bootstrap client for remote server setup.
//!
//! Pure Rust SSH2 client (via `russh`) that replaces platform-specific
//! SSH libraries (Citadel on iOS, JSch on Android).
//!
//! The implementation is split across submodules; this file only contains
//! the [`SshClient`] struct, its constants, and a few cross-module
//! glue helpers.
//!
//! - [`connect`] — handshake + auth + teardown
//! - [`exec`] — exec / open_exec_child / upload + per-shell exec wrapper
//! - [`forwarding`] — local↔remote TCP forward + Unix socket helpers
//! - [`port_forward`] — the bidirectional channel proxy task
//! - [`bootstrap`] — `bootstrap_codex_server` orchestration
//! - [`resolve_binary`] — locate an existing remote codex binary
//! - [`detect`] — remote shell + platform detection
//! - [`probes`] — port-listening / process-alive / log-tail
//! - [`keychain`] — macOS unlock-keychain via stdin
//! - [`codex_binary`] — `RemoteCodexBinary` + per-shell launch builders
//! - [`clixml`] — strip PowerShell CLIXML envelopes
//! - [`types`] — public records (`SshCredentials`, `SshError`, …)

mod bootstrap;
mod clixml;
mod codex_binary;
mod connect;
mod detect;
mod exec;
mod forwarding;
mod keychain;
mod port_forward;
mod probes;
mod resolve_binary;
mod terminal_channel;
mod types;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use russh::client::Handle;
use tokio::sync::Mutex;

use crate::logging::{LogLevelName, log_rust};

use clixml::strip_clixml;
use codex_binary::{
    resolve_codex_binary_script_posix, resolve_codex_binary_script_powershell,
    server_launch_command, windows_start_process_spec,
};
use connect::ClientHandler;

pub(crate) use crate::shell_quoting::posix_quote as shell_quote;
pub(crate) use crate::ssh_scripts::posix::{PACKAGE_MANAGER_PROBE, PROFILE_INIT};
pub(crate) use codex_binary::RemoteCodexBinary;
pub(crate) use exec::build_posix_exec_command;
pub use types::{
    ExecResult, SshAuth, SshBootstrapResult, SshCredentials, SshError, SshExecChild, SshExecIo,
    SshExecStderr, SshExecStdin, SshExecStdout,
};
pub(crate) use types::{RemoteShell, SshBootstrapTransport};

// SSH channel sizing — tuned for high-throughput interactive workloads.
const SSH_CHANNEL_WINDOW_SIZE: u32 = 16 * 1024 * 1024;
const SSH_MAX_PACKET_SIZE: u32 = 256 * 1024;
const SSH_CHANNEL_BUFFER_SIZE: usize = 512;

// Connection lifecycle timings.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const EXEC_TIMEOUT: Duration = Duration::from_secs(30);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(15);

/// Default base port for remote Codex server (matches Android).
const DEFAULT_REMOTE_PORT: u16 = 8390;
/// Number of candidate ports to try.
const PORT_CANDIDATES: u16 = 21;

// Bootstrap polling — see `bootstrap` module.
const LISTEN_POLL_ATTEMPTS: u32 = 60;
const LISTEN_POLL_INTERVAL: Duration = Duration::from_millis(500);
const TUNNEL_HEALTH_ATTEMPTS: u32 = 20;
const TUNNEL_HEALTH_INTERVAL: Duration = Duration::from_millis(250);
const SYNC_DIAG_TIMEOUT: Duration = Duration::from_secs(8);

/// A connected SSH session that can execute commands, upload files,
/// forward ports, and bootstrap a remote Codex server.
pub struct SshClient {
    /// The underlying russh handle, behind `Arc<Mutex>` so port-forwarding
    /// background tasks can open channels concurrently with foreground
    /// exec calls.
    handle: Arc<Mutex<Handle<ClientHandler>>>,
    /// Tracks forwarding background tasks so we can abort them on disconnect.
    pub(super) forward_tasks: Mutex<HashMap<u16, ForwardTask>>,
    /// Optional login password to reuse for unlocking the remote macOS
    /// login keychain before detached headless launches.
    pub(super) macos_keychain_password: Option<String>,
}

pub(super) struct ForwardTask {
    pub(super) remote_host: String,
    pub(super) remote_port: u16,
    pub(super) task: tokio::task::JoinHandle<()>,
}

// Logging helpers — every event goes through `log_rust` so the bridge log
// file mirror sees it (see CLAUDE.md / `crate::logging`).
fn append_bridge_log(level: LogLevelName, line: &str) {
    log_rust(level, "ssh", "bridge", line.to_string(), None);
}

pub(super) fn append_android_debug_log(line: &str) {
    append_bridge_log(LogLevelName::Debug, line);
}

pub(super) fn append_bridge_info_log(line: &str) {
    append_bridge_log(LogLevelName::Info, line);
}

pub(super) fn remote_shell_name(shell: RemoteShell) -> &'static str {
    shell.name()
}

pub(super) fn normalize_host(host: &str) -> String {
    let mut h = host.trim().trim_matches('[').trim_matches(']').to_string();
    h = h.replace("%25", "%");
    if !h.contains(':')
        && let Some(idx) = h.find('%') {
            h.truncate(idx);
        }
    h
}

#[cfg(test)]
mod tests;
