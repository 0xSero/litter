//! Attach to or spawn a local `codex app-server` process on the host Mac.
//!
//! Used by the direct-dist (non-sandboxed) Mac Catalyst lane to provide a
//! first-class "Local Mac" server without requiring the user to run a
//! terminal command. Not used on the App Store Mac lane (sandboxed) or iOS.
//!
//! Flow per `attach_or_spawn`:
//!   1. Try a cheap TCP probe on `127.0.0.1:{port}`. If something is
//!      listening, attach to it and do not spawn.
//!   2. Resolve a `codex` binary from the same candidate paths the SSH
//!      bootstrap would probe remotely.
//!   3. If not found, fail with a clear "install Codex" error.
//!   4. Spawn `codex app-server --listen ws://127.0.0.1:{port}` and poll
//!      the WebSocket up to 20 × 250 ms for readiness.
//!
//! The returned `LocalServerHandle` keeps the child alive; dropping it or
//! calling `stop()` terminates the process.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::time::sleep;
use tokio_tungstenite::connect_async;
use tracing::{debug, info, warn};

/// How long to wait for a single connect attempt before considering nothing
/// is listening. Matches the "quick attach check" semantics in the plan.
const PROBE_CONNECT_TIMEOUT: Duration = Duration::from_millis(150);

/// Max number of readiness poll iterations after spawn. 20 × 250 ms == 5 s.
const READINESS_MAX_ATTEMPTS: u32 = 20;
const READINESS_POLL_INTERVAL: Duration = Duration::from_millis(250);


/// POSIX candidate lines shared with Alleycat's Codex resolver.
pub(crate) const fn shell_candidate_lines() -> &'static [&'static str] {
    alleycat_bridge_core::codex_resolver::POSIX_SHELL_CANDIDATE_LINES
}

// ---------------------------------------------------------------------------
// Probe + resolve
// ---------------------------------------------------------------------------

/// Attempt a quick TCP connect to `127.0.0.1:{port}` with a short timeout.
/// Returns `true` if something accepted the connection.
pub async fn probe_local_server(port: u16) -> bool {
    let addr = ("127.0.0.1", port);
    match tokio::time::timeout(PROBE_CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
        Ok(Ok(mut stream)) => {
            // Be polite — immediately shut down so we don't leave a dangling
            // half-open connection on the app-server.
            let _ = stream.shutdown().await;
            true
        }
        _ => false,
    }
}

/// Resolve a local `codex` binary using Alleycat's shared newest-version
/// resolver, which is also used by SSH bootstrap and the Alleycat daemon.
pub fn resolve_codex_binary_local() -> Option<PathBuf> {
    alleycat_bridge_core::codex_resolver::resolve_latest_codex_binary(Path::new("codex"))
}

// ---------------------------------------------------------------------------
// Spawn
// ---------------------------------------------------------------------------

/// Errors produced by the local-server bootstrap flow.
#[derive(Debug, thiserror::Error)]
pub enum LocalServerError {
    #[error(
        "codex binary not found locally; install the Codex CLI and make `codex` available on PATH"
    )]
    BinaryNotFound,
    #[error("failed to spawn codex app-server: {0}")]
    Spawn(String),
    #[error(
        "codex app-server did not become ready on 127.0.0.1:{port} within {timeout_ms}ms: {reason}"
    )]
    ReadinessTimeout {
        port: u16,
        timeout_ms: u64,
        reason: String,
    },
}

/// Handle to a spawned `codex app-server` process. Drop (or `stop()`) kills
/// the child so we never leak the process when the app quits.
pub struct LocalServerHandle {
    child: Option<Child>,
    port: u16,
    codex_path: PathBuf,
}

impl LocalServerHandle {
    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn codex_path(&self) -> &Path {
        &self.codex_path
    }

    /// Gracefully terminate the child. First sends SIGTERM; if the process
    /// doesn't exit within a short grace period, the `Child` is dropped
    /// (which kills on Unix via tokio's `kill_on_drop`).
    pub async fn stop(mut self) {
        self.stop_internal().await;
    }

    async fn stop_internal(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };

        #[cfg(unix)]
        {
            if let Some(id) = child.id() {
                // Best-effort SIGTERM first; ignore errors.
                let _ = nix_sigterm(id as i32);
            }
        }

        // Give codex up to 2s to exit cleanly.
        let wait_result = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;

        match wait_result {
            Ok(Ok(status)) => {
                debug!("local codex exited status={:?}", status);
            }
            Ok(Err(err)) => {
                warn!("local codex wait failed: {err}");
            }
            Err(_) => {
                warn!("local codex did not exit within grace period, killing");
                let _ = child.kill().await;
                let _ = child.wait().await;
            }
        }
    }
}

impl Drop for LocalServerHandle {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        #[cfg(unix)]
        if let Some(id) = child.id() {
            let _ = nix_sigterm(id as i32);
        }
        // `kill_on_drop(true)` below ensures the child will be killed if
        // SIGTERM didn't take effect before the runtime goes away.
        let _ = child.start_kill();
    }
}

#[cfg(unix)]
fn nix_sigterm(pid: i32) -> std::io::Result<()> {
    // SIGTERM = 15. Avoid pulling in nix/libc crates just for this.
    // SAFETY: FFI to libc kill with a valid signal number and a pid we
    // produced; no memory involved.
    let rc = unsafe { raw_kill(pid, 15) };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(unix)]
unsafe extern "C" {
    #[link_name = "kill"]
    fn raw_kill(pid: i32, sig: i32) -> i32;
}

/// Attach to an existing `127.0.0.1:{port}` listener, or spawn one if
/// nothing is listening. Returns a handle describing the connection and,
/// when we spawned, a process to keep alive.
pub async fn attach_or_spawn_local_server(
    port: u16,
    codex_home: Option<PathBuf>,
) -> Result<LocalServerAttach, LocalServerError> {
    if probe_local_server(port).await {
        info!("attaching to existing local codex on 127.0.0.1:{}", port);
        return Ok(LocalServerAttach {
            port,
            handle: None,
            attached_to_existing: true,
            codex_path: None,
        });
    }

    info!(
        "no existing codex on 127.0.0.1:{}; attempting to spawn",
        port
    );

    let codex_path = resolve_codex_binary_local().ok_or(LocalServerError::BinaryNotFound)?;

    let handle = spawn_local_server(port, &codex_path, codex_home.as_deref()).await?;

    match wait_for_local_server_ready(port).await {
        Ok(()) => Ok(LocalServerAttach {
            port,
            handle: Some(handle),
            attached_to_existing: false,
            codex_path: Some(codex_path),
        }),
        Err(err) => {
            // Drop the handle so we don't leak the half-started child.
            drop(handle);
            Err(err)
        }
    }
}

async fn spawn_local_server(
    port: u16,
    codex_path: &Path,
    codex_home: Option<&Path>,
) -> Result<LocalServerHandle, LocalServerError> {
    let listen_url = format!("ws://127.0.0.1:{port}");
    let mut cmd = Command::new(codex_path);
    cmd.arg("--enable").arg("goals");

    if let Some(base_url) = crate::session::connection::openai_base_url_from_env() {
        cmd.arg("--config").arg(format!(
            "openai_base_url={}",
            toml_string_literal(&base_url)
        ));
    }

    cmd.arg("app-server")
        .arg("--listen")
        .arg(&listen_url)
        .stdin(Stdio::null())
        // Route stdout/stderr to the parent process so `codex` logs appear
        // alongside the app's own logs (Console.app on Mac).
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .kill_on_drop(true);

    if let Some(home) = codex_home {
        cmd.env("CODEX_HOME", home);
    }

    let child = cmd
        .spawn()
        .map_err(|err| LocalServerError::Spawn(err.to_string()))?;

    info!(
        "spawned local codex pid={:?} path={:?} listen={}",
        child.id(),
        codex_path,
        listen_url
    );

    Ok(LocalServerHandle {
        child: Some(child),
        port,
        codex_path: codex_path.to_path_buf(),
    })
}

async fn wait_for_local_server_ready(port: u16) -> Result<(), LocalServerError> {
    let url = format!("ws://127.0.0.1:{port}");
    let mut last_error = String::new();

    for attempt in 0..READINESS_MAX_ATTEMPTS {
        match connect_async(&url).await {
            Ok((mut ws, _)) => {
                let _ = ws.close(None).await;
                debug!(
                    "local codex ready on 127.0.0.1:{} after attempt {}",
                    port,
                    attempt + 1
                );
                return Ok(());
            }
            Err(err) => {
                last_error = err.to_string();
                if attempt == 0 || attempt + 1 == READINESS_MAX_ATTEMPTS {
                    debug!(
                        "local codex readiness attempt {} failed: {}",
                        attempt + 1,
                        last_error
                    );
                }
            }
        }
        sleep(READINESS_POLL_INTERVAL).await;
    }

    Err(LocalServerError::ReadinessTimeout {
        port,
        timeout_ms: (READINESS_POLL_INTERVAL * READINESS_MAX_ATTEMPTS).as_millis() as u64,
        reason: last_error,
    })
}

fn toml_string_literal(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    for ch in value.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            ch if ch.is_control() => {
                use std::fmt::Write as _;
                let codepoint = ch as u32;
                if codepoint <= 0xFFFF {
                    let _ = write!(escaped, "\\u{codepoint:04X}");
                } else {
                    let _ = write!(escaped, "\\U{codepoint:08X}");
                }
            }
            ch => escaped.push(ch),
        }
    }
    escaped.push('"');
    escaped
}

// ---------------------------------------------------------------------------
// Attach result
// ---------------------------------------------------------------------------

/// Outcome of `attach_or_spawn_local_server`.
///
/// `handle` is `Some` when this invocation started the child; `None` when
/// we attached to a codex that was already listening (user ran it in a
/// terminal).
pub struct LocalServerAttach {
    pub port: u16,
    pub handle: Option<LocalServerHandle>,
    pub attached_to_existing: bool,
    pub codex_path: Option<PathBuf>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_candidate_lines_has_matching_entries() {
        let shell = shell_candidate_lines().join("\n");
        assert!(shell.contains("_litter_consider_path_candidates codex codex"));
        assert!(shell.contains("packages/standalone/current/codex"));
        assert!(!shell.contains(".litter/bin/codex"));
        assert!(!shell.contains(".litter/codex/node_modules/.bin/codex"));
        assert!(shell.contains(".local/bin/codex"));
        assert!(shell.contains("/opt/homebrew/bin/codex"));
        assert!(shell.contains("/usr/local/bin/codex"));
        assert!(shell.contains("/usr/bin/codex"));
    }

    #[test]
    fn toml_string_literal_escapes_base_url_value() {
        assert_eq!(
            toml_string_literal("http://localhost:11434/v1"),
            "\"http://localhost:11434/v1\""
        );
        assert_eq!(
            toml_string_literal("http://host/quote\"slash\\"),
            "\"http://host/quote\\\"slash\\\\\""
        );
    }

    #[tokio::test]
    async fn probe_returns_false_for_unused_port() {
        // Pick a high port unlikely to be in use in CI. If a flake
        // happens, bump this to a different port.
        assert!(!probe_local_server(1).await);
    }
}
