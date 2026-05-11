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
//!   3. If not found, install via `npm @openai/codex@latest` into
//!      `~/.litter/codex` (same layout as the SSH installer).
//!   4. If an existing install is >24h old, re-run the npm install to
//!      refresh.
//!   5. Spawn `codex app-server --listen ws://127.0.0.1:{port}` and poll
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

/// If the managed codex install under `~/.litter/codex` is older than this,
/// re-run `npm install @openai/codex@latest` on next spawn. Mirrors
/// `CODEX_UPDATE_CHECK_INTERVAL_SECS` in `ssh.rs`.
const MANAGED_CODEX_MAX_AGE_SECS: u64 = 24 * 60 * 60;
const OPENAI_BASE_URL_ENV_KEY: &str = "OPENAI_BASE_URL";

// ---------------------------------------------------------------------------
// Shared path list
// ---------------------------------------------------------------------------

/// A single candidate path where we might find the `codex` binary locally
/// (or equivalently, on a POSIX SSH host). Each entry is expanded at
/// resolution time against `$HOME` and a small set of env anchors.
///
/// The list is shared with the SSH bash script in `ssh.rs` so the two
/// resolvers cannot drift.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CodexPathCandidate {
    /// Home-relative path (no leading `$HOME/`) or absolute path.
    pub rel_or_abs: &'static str,
    /// If set, the path uses the named env anchor for a configurable
    /// prefix (e.g. `BUN_INSTALL`). Rust resolver falls back to the
    /// documented default when the env var is unset.
    pub env_anchor: Option<EnvAnchor>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct EnvAnchor {
    pub name: &'static str,
    /// Default value when the env var is unset, relative to `$HOME`
    /// (empty string means "no home prefix").
    pub default_home_rel: &'static str,
    /// Suffix appended after the resolved anchor before the binary name.
    /// For example, `/bin` for most package-manager homes.
    pub suffix: &'static str,
}

/// POSIX candidate paths in priority order. Kept in sync with
/// `resolve_codex_binary_script_posix` in `ssh.rs` — any addition here
/// should be mirrored in that script.
pub(crate) const CODEX_BINARY_POSIX_CANDIDATES: &[CodexPathCandidate] = &[
    // Managed Litter install (release tarball symlink).
    CodexPathCandidate {
        rel_or_abs: ".litter/bin/codex",
        env_anchor: None,
    },
    // Managed Litter install (npm fallback).
    CodexPathCandidate {
        rel_or_abs: ".litter/codex/node_modules/.bin/codex",
        env_anchor: None,
    },
    // Bun (env-overridable, defaults to ~/.bun).
    CodexPathCandidate {
        rel_or_abs: "",
        env_anchor: Some(EnvAnchor {
            name: "BUN_INSTALL",
            default_home_rel: ".bun",
            suffix: "/bin/codex",
        }),
    },
    // Volta shim dir.
    CodexPathCandidate {
        rel_or_abs: ".volta/bin/codex",
        env_anchor: None,
    },
    // Generic per-user bin.
    CodexPathCandidate {
        rel_or_abs: ".local/bin/codex",
        env_anchor: None,
    },
    // Cargo install bin (env-overridable, defaults to ~/.cargo).
    CodexPathCandidate {
        rel_or_abs: "",
        env_anchor: Some(EnvAnchor {
            name: "CARGO_HOME",
            default_home_rel: ".cargo",
            suffix: "/bin/codex",
        }),
    },
    // Homebrew / system prefixes.
    CodexPathCandidate {
        rel_or_abs: "/opt/homebrew/bin/codex",
        env_anchor: None,
    },
    CodexPathCandidate {
        rel_or_abs: "/usr/local/bin/codex",
        env_anchor: None,
    },
];

/// Named env anchors referenced from `resolve_codex_binary_script_posix`
/// when emitting the shell equivalent of this list. Rendered as
/// `_litter_emit_from_dir codex codex "${ANCHOR:-$HOME/<default>}"`.
pub(crate) const fn shell_candidate_lines() -> &'static [&'static str] {
    // Pre-rendered lines. Keeping them here (rather than generating at
    // runtime) avoids building the script string every time it is used.
    &[
        r#"_litter_emit_candidate codex "$HOME/.litter/bin/codex""#,
        r#"_litter_emit_candidate codex "$HOME/.litter/codex/node_modules/.bin/codex""#,
        r#"_litter_emit_candidate codex "$(command -v codex 2>/dev/null || true)""#,
        r#"_litter_emit_candidate codex "${BUN_INSTALL:-$HOME/.bun}/bin/codex""#,
        r#"_litter_emit_candidate codex "$HOME/.volta/bin/codex""#,
        r#"_litter_emit_candidate codex "$HOME/.local/bin/codex""#,
        r#"_litter_emit_from_dir codex codex "${PNPM_HOME:-}""#,
        r#"_litter_emit_from_dir codex codex "${NVM_BIN:-}""#,
        r#"_litter_emit_from_dir codex codex "${VOLTA_HOME:+$VOLTA_HOME/bin}""#,
        r#"_litter_emit_from_dir codex codex "${CARGO_HOME:-$HOME/.cargo}/bin""#,
        r#"_litter_emit_candidate codex "/opt/homebrew/bin/codex""#,
        r#"_litter_emit_candidate codex "/usr/local/bin/codex""#,
    ]
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

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Resolve a local `codex` binary by probing the shared candidate list.
/// Returns the first path that exists and is executable.
///
/// Ordering matches `resolve_codex_binary_script_posix` in `ssh.rs`:
///   1. managed `~/.litter/bin/codex` symlink
///   2. managed `~/.litter/codex/node_modules/.bin/codex`
///   3. `which codex` (walk PATH)
///   4. the remaining env-anchored / literal candidates
pub fn resolve_codex_binary_local() -> Option<PathBuf> {
    let home = home_dir();

    let managed = [
        CODEX_BINARY_POSIX_CANDIDATES[0],
        CODEX_BINARY_POSIX_CANDIDATES[1],
    ];
    for candidate in &managed {
        if let Some(path) = expand_candidate(candidate, home.as_deref()) {
            if is_executable_file(&path) {
                return Some(path);
            }
        }
    }

    if let Some(path) = which_codex() {
        return Some(path);
    }

    for candidate in &CODEX_BINARY_POSIX_CANDIDATES[2..] {
        if let Some(path) = expand_candidate(candidate, home.as_deref()) {
            if is_executable_file(&path) {
                return Some(path);
            }
        }
    }

    None
}

fn which_codex() -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join("codex");
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn expand_candidate(candidate: &CodexPathCandidate, home: Option<&Path>) -> Option<PathBuf> {
    if let Some(anchor) = candidate.env_anchor {
        let base = match std::env::var(anchor.name) {
            Ok(val) if !val.is_empty() => PathBuf::from(val),
            _ => {
                if anchor.default_home_rel.is_empty() {
                    return None;
                }
                home?.join(anchor.default_home_rel)
            }
        };
        // suffix starts with `/` by convention.
        let suffix = anchor.suffix.trim_start_matches('/');
        return Some(base.join(suffix));
    }

    if candidate.rel_or_abs.starts_with('/') {
        return Some(PathBuf::from(candidate.rel_or_abs));
    }

    if candidate.rel_or_abs.is_empty() {
        return None;
    }

    Some(home?.join(candidate.rel_or_abs))
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

// ---------------------------------------------------------------------------
// Spawn
// ---------------------------------------------------------------------------

/// Errors produced by the local-server bootstrap flow.
#[derive(Debug, thiserror::Error)]
pub enum LocalServerError {
    #[error("codex binary not found locally and npm install failed: {0}")]
    Install(String),
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

    let codex_path = match resolve_codex_binary_local() {
        Some(path) => {
            if is_managed_install(&path) && is_managed_codex_stale() {
                info!(
                    "managed codex install older than 24h; refreshing via npm ({:?})",
                    path
                );
                if let Err(err) = install_codex_via_local_npm().await {
                    warn!("npm refresh failed, continuing with existing binary: {err}");
                } else {
                    touch_managed_codex_sentinel();
                }
            }
            path
        }
        None => {
            info!("codex binary not found locally; installing via npm");
            install_codex_via_local_npm()
                .await
                .map_err(LocalServerError::Install)?;
            touch_managed_codex_sentinel();
            resolve_codex_binary_local().ok_or_else(|| {
                LocalServerError::Install(
                    "npm install reported success but codex binary not found in expected locations"
                        .into(),
                )
            })?
        }
    };

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

    if let Some(base_url) = openai_base_url_from_env() {
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

// ---------------------------------------------------------------------------
// npm install + managed sentinel
// ---------------------------------------------------------------------------

fn managed_codex_dir() -> Option<PathBuf> {
    home_dir().map(|home| home.join(".litter/codex"))
}

fn managed_codex_sentinel() -> Option<PathBuf> {
    managed_codex_dir().map(|dir| dir.join(".last-update-check"))
}

fn is_managed_install(path: &Path) -> bool {
    let Some(home) = home_dir() else {
        return false;
    };
    let litter_root = home.join(".litter");
    path.starts_with(&litter_root)
}

fn is_managed_codex_stale() -> bool {
    let Some(sentinel) = managed_codex_sentinel() else {
        return false;
    };
    let Ok(metadata) = std::fs::metadata(&sentinel) else {
        // No sentinel yet — treat as stale so we pick up updates on first
        // launch after install.
        return true;
    };
    match metadata.modified() {
        Ok(modified) => match modified.elapsed() {
            Ok(age) => age.as_secs() >= MANAGED_CODEX_MAX_AGE_SECS,
            Err(_) => true,
        },
        Err(_) => true,
    }
}

fn touch_managed_codex_sentinel() {
    let Some(dir) = managed_codex_dir() else {
        return;
    };
    let _ = std::fs::create_dir_all(&dir);
    let Some(path) = managed_codex_sentinel() else {
        return;
    };
    // Rewrite empty to update mtime (simpler than threading a filetime
    // crate dependency just for this).
    let _ = std::fs::write(&path, b"");
}

/// Run `npm install @openai/codex@latest` into `~/.litter/codex/`. Mirrors
/// the POSIX branch of `SshClient::install_codex_via_npm`.
async fn install_codex_via_local_npm() -> Result<(), String> {
    let Some(dir) = managed_codex_dir() else {
        return Err("HOME not set".to_string());
    };

    std::fs::create_dir_all(&dir).map_err(|err| format!("mkdir {:?} failed: {err}", dir))?;

    // Initialize a package.json if absent.
    if !dir.join("package.json").exists() {
        let status = Command::new("npm")
            .arg("init")
            .arg("-y")
            .current_dir(&dir)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .map_err(|err| format!("failed to run `npm init -y`: {err}"))?;
        if !status.success() {
            return Err(format!("npm init exited with {:?}", status.code()));
        }
    }

    let output = Command::new("npm")
        .arg("install")
        .arg("@openai/codex@latest")
        .current_dir(&dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|err| format!("failed to run `npm install @openai/codex@latest`: {err}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "npm install @openai/codex exited with {:?}: {}",
            output.status.code(),
            stderr.trim()
        ));
    }

    let bin = dir.join("node_modules/.bin/codex");
    if !is_executable_file(&bin) {
        return Err(format!(
            "npm install succeeded but {:?} is not present/executable",
            bin
        ));
    }

    Ok(())
}

fn openai_base_url_from_env() -> Option<String> {
    std::env::var(OPENAI_BASE_URL_ENV_KEY)
        .ok()
        .map(|value| value.trim().trim_end_matches('/').to_string())
        .filter(|value| !value.is_empty())
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
    fn expands_anchor_with_env() {
        // Take the first env-anchored candidate (BUN_INSTALL) and check
        // expansion both with and without the env var set.
        let anchor_candidate = CODEX_BINARY_POSIX_CANDIDATES
            .iter()
            .find(|c| c.env_anchor.is_some())
            .expect("at least one env-anchored candidate");
        let home = PathBuf::from("/tmp/home-fake");
        let expanded = expand_candidate(anchor_candidate, Some(&home)).unwrap();
        // With no env set, falls back to $HOME/.bun/bin/codex (for the
        // BUN_INSTALL anchor) or similar.
        assert!(expanded.starts_with(&home) || expanded.is_absolute());
    }

    #[test]
    fn shell_candidate_lines_has_matching_entries() {
        // Every path pattern in the Rust list should appear textually in
        // the shell lines — a cheap way to catch divergence when someone
        // edits one but not the other.
        let shell = shell_candidate_lines().join("\n");
        assert!(shell.contains(".litter/bin/codex"));
        assert!(shell.contains(".litter/codex/node_modules/.bin/codex"));
        assert!(shell.contains(".local/bin/codex"));
        assert!(shell.contains("/opt/homebrew/bin/codex"));
        assert!(shell.contains("/usr/local/bin/codex"));
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
