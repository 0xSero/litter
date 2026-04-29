//! SSH bootstrap client for remote server setup.
//!
//! Pure Rust SSH2 client (via `russh`) that replaces platform-specific
//! SSH libraries (Citadel on iOS, JSch on Android).

use std::collections::HashMap;
use std::io;
#[cfg(unix)]
use std::os::unix::process::ExitStatusExt;
use std::process::ExitStatus;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::future::BoxFuture;
use russh::ChannelMsg;
use russh::ChannelStream;
use russh::ChannelWriteHalf;
use russh::Sig;
use russh::client::{self, Handle, Msg};
use russh::keys::HashAlg;
use russh::keys::PrivateKeyWithHashAlg;
use russh::keys::PublicKey;
use russh::keys::decode_secret_key;
use serde::Deserialize;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{Mutex, watch};
use tokio_tungstenite::connect_async;
use tracing::{debug, error, info, trace, warn};

use crate::logging::{LogLevelName, log_rust};
use base64::Engine;

const SSH_CHANNEL_WINDOW_SIZE: u32 = 16 * 1024 * 1024;
const SSH_MAX_PACKET_SIZE: u32 = 256 * 1024;
const SSH_CHANNEL_BUFFER_SIZE: usize = 512;

fn append_bridge_log(level: LogLevelName, line: &str) {
    log_rust(level, "ssh", "bridge", line.to_string(), None);
}

fn append_android_debug_log(line: &str) {
    append_bridge_log(LogLevelName::Debug, line);
}

fn append_bridge_info_log(line: &str) {
    append_bridge_log(LogLevelName::Info, line);
}

fn remote_shell_name(shell: RemoteShell) -> &'static str {
    match shell {
        RemoteShell::Posix => "posix",
        RemoteShell::PowerShell => "powershell",
    }
}

fn remote_platform_name(platform: RemotePlatform) -> &'static str {
    match platform {
        RemotePlatform::MacosArm64 => "macos-arm64",
        RemotePlatform::MacosX64 => "macos-x64",
        RemotePlatform::LinuxArm64 => "linux-arm64",
        RemotePlatform::LinuxX64 => "linux-x64",
        RemotePlatform::WindowsX64 => "windows-x64",
        RemotePlatform::WindowsArm64 => "windows-arm64",
    }
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Credentials for establishing an SSH connection.
#[derive(Clone)]
pub struct SshCredentials {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: SshAuth,
    pub unlock_macos_keychain: bool,
}

/// Authentication method.
#[derive(Clone)]
pub enum SshAuth {
    Password(String),
    PrivateKey {
        key_pem: String,
        passphrase: Option<String>,
    },
}

/// Result of a successful `bootstrap_codex_server` call.
#[derive(Debug, Clone)]
pub struct SshBootstrapResult {
    pub server_port: u16,
    pub tunnel_local_port: u16,
    pub server_version: Option<String>,
    pub pid: Option<u32>,
}

#[derive(Debug, Clone)]
pub(crate) struct ResolvedCodexRelease {
    pub tag_name: String,
    pub asset_name: String,
    pub binary_name: String,
    pub download_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemotePlatform {
    MacosArm64,
    MacosX64,
    LinuxArm64,
    LinuxX64,
    WindowsX64,
    WindowsArm64,
}

/// The remote host's shell type, detected after SSH connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteShell {
    Posix,
    PowerShell,
}

impl RemotePlatform {
    pub(crate) fn is_windows(self) -> bool {
        matches!(self, Self::WindowsX64 | Self::WindowsArm64)
    }
}

/// Outcome of running the Codex install/update flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CodexInstallOutcome {
    /// A new tag/version was downloaded or `npm install` ran.
    Installed,
    /// The tarball install saw `$HOME/.litter/codex/$tag/codex` already present;
    /// we just refreshed the symlink.
    AlreadyAtLatestTag,
}

/// Seconds before we re-check GitHub for a newer Codex release.
const CODEX_UPDATE_CHECK_INTERVAL_SECS: u64 = 24 * 60 * 60;

/// Outcome of running a remote command.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ExecResult {
    pub exit_code: u32,
    pub stdout: String,
    pub stderr: String,
}

pub type SshExecStdin = Box<dyn AsyncWrite + Send + Unpin>;
pub type SshExecStdout = Box<dyn AsyncRead + Send + Unpin>;
pub type SshExecStderr = Box<dyn AsyncRead + Send + Unpin>;

/// Streaming SSH exec child.
///
/// stdout/stderr are demultiplexed from russh channel messages into normal
/// async readers so bridge launchers can treat a remote process like a local
/// `tokio::process::Child`.
pub struct SshExecChild {
    stdin: Option<SshExecStdin>,
    stdout: Option<SshExecStdout>,
    stderr: Option<SshExecStderr>,
    exit_rx: watch::Receiver<Option<u32>>,
    write_half: Arc<Mutex<Option<ChannelWriteHalf<Msg>>>>,
}

impl SshExecChild {
    pub fn take_stdin(&mut self) -> Option<SshExecStdin> {
        self.stdin.take()
    }

    pub fn take_stdout(&mut self) -> Option<SshExecStdout> {
        self.stdout.take()
    }

    pub fn take_stderr(&mut self) -> Option<SshExecStderr> {
        self.stderr.take()
    }

    pub async fn wait(&mut self) -> io::Result<ExitStatus> {
        loop {
            if let Some(code) = *self.exit_rx.borrow() {
                return exit_status_from_code(code);
            }
            if self.exit_rx.changed().await.is_err() {
                if let Some(code) = *self.exit_rx.borrow() {
                    return exit_status_from_code(code);
                }
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "ssh exec channel closed without exit status",
                ));
            }
        }
    }

    pub async fn kill(&mut self) -> io::Result<()> {
        let Some(write_half) = self.write_half.lock().await.take() else {
            return Ok(());
        };
        let _ = write_half.signal(Sig::TERM).await;
        write_half
            .close()
            .await
            .map_err(|error| io::Error::new(io::ErrorKind::BrokenPipe, error.to_string()))
    }
}

#[cfg(unix)]
fn exit_status_from_code(code: u32) -> io::Result<ExitStatus> {
    Ok(ExitStatus::from_raw((code as i32) << 8))
}

#[cfg(not(unix))]
fn exit_status_from_code(_code: u32) -> io::Result<ExitStatus> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "ssh exec exit status conversion is only implemented on unix targets",
    ))
}

/// SSH-specific errors.
#[derive(Debug, thiserror::Error)]
pub enum SshError {
    #[error("connection failed: {0}")]
    ConnectionFailed(String),
    #[error("auth failed: {0}")]
    AuthFailed(String),
    #[error("host key verification failed: fingerprint {fingerprint}")]
    HostKeyVerification { fingerprint: String },
    #[error("command failed (exit {exit_code}): {stderr}")]
    ExecFailed { exit_code: u32, stderr: String },
    #[error("port forward failed: {0}")]
    PortForwardFailed(String),
    #[error("timeout")]
    Timeout,
    #[error("disconnected")]
    Disconnected,
}

// ---------------------------------------------------------------------------
// russh Handler (internal)
// ---------------------------------------------------------------------------

type HostKeyCallback = Arc<dyn Fn(&str) -> BoxFuture<'static, bool> + Send + Sync>;

struct ClientHandler {
    host_key_cb: HostKeyCallback,
    /// If the callback rejects the key we store the fingerprint so we can
    /// surface it in [`SshError::HostKeyVerification`].
    rejected_fingerprint: Arc<Mutex<Option<String>>>,
}

#[async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;

    fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> impl std::future::Future<Output = Result<bool, Self::Error>> + Send {
        let fp = format!("{}", server_public_key.fingerprint(HashAlg::Sha256));
        let rejected_fingerprint = Arc::clone(&self.rejected_fingerprint);
        let callback = Arc::clone(&self.host_key_cb);
        async move {
            let accepted = callback(&fp).await;
            if !accepted {
                *rejected_fingerprint.lock().await = Some(fp);
            }
            Ok(accepted)
        }
    }
}

// ---------------------------------------------------------------------------
// SshClient
// ---------------------------------------------------------------------------

/// A connected SSH session that can execute commands, upload files,
/// forward ports, and bootstrap a remote Codex server.
pub struct SshClient {
    /// The underlying russh handle, behind Arc<Mutex> so port-forwarding
    /// background tasks can open channels.
    handle: Arc<Mutex<Handle<ClientHandler>>>,
    /// Tracks forwarding background tasks so we can abort on disconnect.
    forward_tasks: Mutex<HashMap<u16, ForwardTask>>,
    /// Optional login password to reuse for unlocking the remote macOS
    /// login keychain before detached headless launches.
    macos_keychain_password: Option<String>,
}

struct ForwardTask {
    remote_host: String,
    remote_port: u16,
    task: tokio::task::JoinHandle<()>,
}

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const EXEC_TIMEOUT: Duration = Duration::from_secs(30);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(15);

/// Default base port for remote Codex server (matches Android).
const DEFAULT_REMOTE_PORT: u16 = 8390;
/// Number of candidate ports to try.
const PORT_CANDIDATES: u16 = 21;

impl SshClient {
    /// Open an SSH connection to `credentials.host:credentials.port`.
    ///
    /// `host_key_callback` is invoked with the SHA-256 fingerprint of the
    /// server's public key. Return `true` to accept, `false` to reject.
    pub async fn connect(
        credentials: SshCredentials,
        host_key_callback: Box<dyn Fn(&str) -> BoxFuture<'static, bool> + Send + Sync>,
    ) -> Result<Self, SshError> {
        let macos_keychain_password = if credentials.unlock_macos_keychain {
            match &credentials.auth {
                SshAuth::Password(password) => Some(password.clone()),
                SshAuth::PrivateKey { .. } => None,
            }
        } else {
            None
        };
        let auth_kind = match &credentials.auth {
            SshAuth::Password(_) => "password",
            SshAuth::PrivateKey { .. } => "key",
        };
        let rejected_fp = Arc::new(Mutex::new(None));

        let handler = ClientHandler {
            host_key_cb: Arc::from(host_key_callback),
            rejected_fingerprint: Arc::clone(&rejected_fp),
        };

        let config = client::Config {
            keepalive_interval: Some(KEEPALIVE_INTERVAL),
            keepalive_max: 3,
            inactivity_timeout: None,
            window_size: SSH_CHANNEL_WINDOW_SIZE,
            maximum_packet_size: SSH_MAX_PACKET_SIZE,
            channel_buffer_size: SSH_CHANNEL_BUFFER_SIZE,
            nodelay: true,
            ..Default::default()
        };

        let addr = format!("{}:{}", normalize_host(&credentials.host), credentials.port);
        info!(
            "SSH connect start addr={} username={} auth={} nodelay={} window_size={} maximum_packet_size={} channel_buffer_size={}",
            addr,
            credentials.username,
            auth_kind,
            config.nodelay,
            config.window_size,
            config.maximum_packet_size,
            config.channel_buffer_size
        );
        append_bridge_info_log(&format!(
            "ssh_connect_start addr={} username={} auth={} nodelay={} window_size={} maximum_packet_size={} channel_buffer_size={}",
            addr,
            credentials.username,
            auth_kind,
            config.nodelay,
            config.window_size,
            config.maximum_packet_size,
            config.channel_buffer_size
        ));

        let connect_result = tokio::time::timeout(
            CONNECT_TIMEOUT,
            client::connect(Arc::new(config), &*addr, handler),
        )
        .await;
        let mut handle = match connect_result {
            Ok(Ok(handle)) => handle,
            Ok(Err(error)) => {
                error!("SSH connect failed addr={} error={:?}", addr, error);
                append_bridge_info_log(&format!(
                    "ssh_connect_failed addr={} error_display={} error_debug={:?}",
                    addr, error, error
                ));
                return Err(SshError::ConnectionFailed(format!("{error}")));
            }
            Err(_) => {
                warn!("SSH connect timed out addr={}", addr);
                append_bridge_info_log(&format!("ssh_connect_timeout addr={}", addr));
                return Err(SshError::Timeout);
            }
        };

        // If the handler rejected the key, surface a specific error.
        if let Some(fp) = rejected_fp.lock().await.take() {
            warn!("SSH host key rejected addr={} fingerprint={}", addr, fp);
            append_bridge_info_log(&format!(
                "ssh_host_key_rejected addr={} fingerprint={}",
                addr, fp
            ));
            return Err(SshError::HostKeyVerification { fingerprint: fp });
        }

        // --- Authenticate -----------------------------------------------
        let auth_result = match &credentials.auth {
            SshAuth::Password(pw) => handle
                .authenticate_password(&credentials.username, pw)
                .await
                .map_err(|e| {
                    warn!("SSH password auth failed addr={} error={:?}", addr, e);
                    append_bridge_info_log(&format!(
                        "ssh_auth_failed addr={} method=password error_display={} error_debug={:?}",
                        addr, e, e
                    ));
                    SshError::AuthFailed(format!("{e}"))
                })?,
            SshAuth::PrivateKey {
                key_pem,
                passphrase,
            } => {
                let key = decode_secret_key(key_pem, passphrase.as_deref())
                    .map_err(|e| SshError::AuthFailed(format!("bad private key: {e}")))?;
                let key = PrivateKeyWithHashAlg::new(
                    Arc::new(key),
                    handle.best_supported_rsa_hash().await.map_err(|e| {
                        warn!("SSH RSA hash negotiation failed addr={} error={:?}", addr, e);
                        append_bridge_info_log(&format!(
                            "ssh_auth_failed addr={} method=key_hash error_display={} error_debug={:?}",
                            addr, e, e
                        ));
                        SshError::AuthFailed(format!("{e}"))
                    })?
                    .flatten(),
                );
                handle
                    .authenticate_publickey(&credentials.username, key)
                    .await
                    .map_err(|e| {
                        warn!("SSH key auth failed addr={} error={:?}", addr, e);
                        append_bridge_info_log(&format!(
                            "ssh_auth_failed addr={} method=key error_display={} error_debug={:?}",
                            addr, e, e
                        ));
                        SshError::AuthFailed(format!("{e}"))
                    })?
            }
        };

        if !auth_result.success() {
            warn!(
                "SSH auth rejected by server addr={} username={}",
                addr, credentials.username
            );
            append_bridge_info_log(&format!(
                "ssh_auth_rejected addr={} username={}",
                addr, credentials.username
            ));
            return Err(SshError::AuthFailed("server rejected credentials".into()));
        }

        info!("SSH connected and authenticated to {addr}");
        append_bridge_info_log(&format!(
            "ssh_connect_success addr={} username={}",
            addr, credentials.username
        ));

        Ok(Self {
            handle: Arc::new(Mutex::new(handle)),
            forward_tasks: Mutex::new(HashMap::new()),
            macos_keychain_password,
        })
    }

    // --------------------------------------------------------------------
    // exec
    // --------------------------------------------------------------------

    /// Run a command on the remote host and collect its stdout/stderr.
    pub async fn exec(&self, command: &str) -> Result<ExecResult, SshError> {
        append_android_debug_log(&format!(
            "ssh_exec_start command={}",
            redact_ssh_command_for_log(command)
        ));
        let result = tokio::time::timeout(EXEC_TIMEOUT, self.exec_inner(command))
            .await
            .map_err(|_| {
                append_bridge_info_log(&format!(
                    "ssh_exec_timeout command={}",
                    redact_ssh_command_for_log(command)
                ));
                SshError::Timeout
            })?;
        match &result {
            Ok(output) => append_android_debug_log(&format!(
                "ssh_exec_done exit={} stdout={} stderr={}",
                output.exit_code,
                log_preview(&output.stdout),
                log_preview(&output.stderr)
            )),
            Err(error) => append_bridge_info_log(&format!("ssh_exec_error error={error}")),
        }
        result
    }

    /// Open a streaming SSH exec channel.
    ///
    /// Unlike [`Self::exec`], this returns immediately after the remote exec
    /// request is accepted and leaves stdin/stdout/stderr open for the caller.
    pub async fn open_exec_child(&self, command: &str) -> Result<SshExecChild, SshError> {
        self.open_exec_child_with_stdio(command, true, true, true)
            .await
    }

    pub(crate) async fn open_exec_child_with_stdio(
        &self,
        command: &str,
        stdin_piped: bool,
        stdout_piped: bool,
        stderr_piped: bool,
    ) -> Result<SshExecChild, SshError> {
        let handle = self.handle.lock().await;
        if handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("open session: {e}")))?;
        drop(handle);

        channel
            .exec(true, command)
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("exec: {e}")))?;

        let (mut read_half, write_half) = channel.split();
        let stdin = if stdin_piped {
            Some(Box::new(write_half.make_writer()) as SshExecStdin)
        } else {
            None
        };
        let write_half = Arc::new(Mutex::new(Some(write_half)));

        let (stdout, mut stdout_writer) = if stdout_piped {
            let (reader, writer) = tokio::io::duplex(64 * 1024);
            (Some(Box::new(reader) as SshExecStdout), Some(writer))
        } else {
            (None, None)
        };
        let (stderr, mut stderr_writer) = if stderr_piped {
            let (reader, writer) = tokio::io::duplex(64 * 1024);
            (Some(Box::new(reader) as SshExecStderr), Some(writer))
        } else {
            (None, None)
        };
        let (exit_tx, exit_rx) = watch::channel(None);

        tokio::spawn(async move {
            while let Some(message) = read_half.wait().await {
                match message {
                    ChannelMsg::Data { data } => {
                        if let Some(writer) = stdout_writer.as_mut() {
                            let _ = writer.write_all(&data).await;
                        }
                    }
                    ChannelMsg::ExtendedData { data, ext: 1 } => {
                        if let Some(writer) = stderr_writer.as_mut() {
                            let _ = writer.write_all(&data).await;
                        }
                        let text = String::from_utf8_lossy(&data);
                        for line in text.lines().filter(|line| !line.trim().is_empty()) {
                            warn!("ssh exec stderr: {line}");
                        }
                    }
                    ChannelMsg::ExitStatus { exit_status } => {
                        let _ = exit_tx.send(Some(exit_status));
                    }
                    ChannelMsg::Eof | ChannelMsg::Close => {}
                    _ => {}
                }
            }
        });

        Ok(SshExecChild {
            stdin,
            stdout,
            stderr,
            exit_rx,
            write_half,
        })
    }

    async fn exec_inner(&self, command: &str) -> Result<ExecResult, SshError> {
        let handle = self.handle.lock().await;
        if handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let mut channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("open session: {e}")))?;
        drop(handle);

        channel
            .exec(true, command)
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("exec: {e}")))?;

        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut exit_code: u32 = 0;

        loop {
            match channel.wait().await {
                Some(ChannelMsg::Data { data }) => {
                    stdout.extend_from_slice(&data);
                }
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    stderr.extend_from_slice(&data);
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    exit_code = exit_status;
                }
                Some(ChannelMsg::Eof | ChannelMsg::Close) => {
                    // Keep draining until the channel is fully closed.
                }
                None => break,
                _ => {}
            }
        }

        Ok(ExecResult {
            exit_code,
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
        })
    }

    // --------------------------------------------------------------------
    // upload
    // --------------------------------------------------------------------

    /// Write `content` to a remote file at `remote_path` via `cat`.
    ///
    /// This avoids an SFTP dependency — it pipes stdin into a shell command.
    pub async fn upload(&self, content: &[u8], remote_path: &str) -> Result<(), SshError> {
        let handle = self.handle.lock().await;
        if handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let mut channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("open session: {e}")))?;
        drop(handle);

        let cmd = format!("cat > {}", shell_quote(remote_path));
        channel
            .exec(true, cmd.as_bytes())
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("exec upload: {e}")))?;

        channel
            .data(&content[..])
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("upload data: {e}")))?;

        channel
            .eof()
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("upload eof: {e}")))?;

        let mut exit_code: u32 = 0;
        loop {
            match channel.wait().await {
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    exit_code = exit_status;
                }
                Some(ChannelMsg::Eof | ChannelMsg::Close) => {}
                None => break,
                _ => {}
            }
        }

        if exit_code != 0 {
            return Err(SshError::ExecFailed {
                exit_code,
                stderr: format!("upload to {remote_path} failed"),
            });
        }

        Ok(())
    }

    // --------------------------------------------------------------------
    // port forwarding
    // --------------------------------------------------------------------

    /// Set up local-to-remote TCP port forwarding.
    ///
    /// Binds a local TCP listener on `local_port` (use 0 for a random port)
    /// and forwards each accepted connection through the SSH tunnel to
    /// `127.0.0.1:remote_port` on the remote host.
    ///
    /// Returns the actual local port that was bound.
    ///
    /// Forwarding runs in background tokio tasks until [`disconnect`] is
    /// called.
    pub async fn forward_port(&self, local_port: u16, remote_port: u16) -> Result<u16, SshError> {
        self.forward_port_to(local_port, "127.0.0.1", remote_port)
            .await
    }

    /// Set up local-to-remote TCP port forwarding to an explicit remote host.
    pub async fn forward_port_to(
        &self,
        local_port: u16,
        remote_host: &str,
        remote_port: u16,
    ) -> Result<u16, SshError> {
        let (actual_port, task) = self
            .spawn_forward_port(local_port, remote_host, remote_port)
            .await?;
        self.forward_tasks.lock().await.insert(
            actual_port,
            ForwardTask {
                remote_host: remote_host.to_string(),
                remote_port,
                task,
            },
        );
        Ok(actual_port)
    }

    pub async fn ensure_forward_port_to(
        &self,
        local_port: u16,
        remote_host: &str,
        remote_port: u16,
    ) -> Result<u16, SshError> {
        {
            let tasks = self.forward_tasks.lock().await;
            if let Some(existing) = tasks.get(&local_port) {
                if existing.remote_host == remote_host && existing.remote_port == remote_port {
                    return Ok(local_port);
                }
                return Err(SshError::PortForwardFailed(format!(
                    "port {local_port} already forwarded to {}:{}",
                    existing.remote_host, existing.remote_port
                )));
            }
        }
        self.forward_port_to(local_port, remote_host, remote_port)
            .await
    }

    pub async fn abort_forward_port(&self, local_port: u16) -> bool {
        let mut tasks = self.forward_tasks.lock().await;
        if let Some(existing) = tasks.remove(&local_port) {
            existing.task.abort();
            true
        } else {
            false
        }
    }

    async fn spawn_forward_port(
        &self,
        local_port: u16,
        remote_host: &str,
        remote_port: u16,
    ) -> Result<(u16, tokio::task::JoinHandle<()>), SshError> {
        let listener = TcpListener::bind(format!("127.0.0.1:{local_port}"))
            .await
            .map_err(|e| SshError::PortForwardFailed(format!("bind: {e}")))?;

        let actual_port = listener
            .local_addr()
            .map_err(|e| SshError::PortForwardFailed(format!("local_addr: {e}")))?
            .port();

        info!("port forward: 127.0.0.1:{actual_port} -> remote {remote_host}:{remote_port}");

        let handle = Arc::clone(&self.handle);
        let remote_host = remote_host.to_string();

        let task = tokio::spawn(async move {
            loop {
                let (local_stream, peer_addr) = match listener.accept().await {
                    Ok(v) => v,
                    Err(e) => {
                        warn!("port forward accept error: {e}");
                        append_android_debug_log(&format!(
                            "ssh_forward_accept_error listen=127.0.0.1:{} remote={}:{} error={}",
                            actual_port, remote_host, remote_port, e
                        ));
                        break;
                    }
                };

                debug!("port forward: accepted connection from {peer_addr}");
                append_android_debug_log(&format!(
                    "ssh_forward_accept listen=127.0.0.1:{} remote={}:{} peer={}",
                    actual_port, remote_host, remote_port, peer_addr
                ));

                let handle = Arc::clone(&handle);
                let remote_host = remote_host.clone();

                tokio::spawn(async move {
                    let ssh_channel = {
                        let h = handle.lock().await;
                        match h
                            .channel_open_direct_tcpip(
                                &remote_host,
                                remote_port as u32,
                                "127.0.0.1",
                                actual_port as u32,
                            )
                            .await
                        {
                            Ok(ch) => ch,
                            Err(e) => {
                                error!("port forward: open direct-tcpip failed: {e}");
                                append_android_debug_log(&format!(
                                    "ssh_forward_direct_tcpip_failed listen=127.0.0.1:{} remote={}:{} peer={} error={}",
                                    actual_port, remote_host, remote_port, peer_addr, e
                                ));
                                return;
                            }
                        }
                    };

                    append_android_debug_log(&format!(
                        "ssh_forward_direct_tcpip_opened listen=127.0.0.1:{} remote={}:{} peer={}",
                        actual_port, remote_host, remote_port, peer_addr
                    ));

                    if let Err(e) = proxy_connection(
                        local_stream,
                        ssh_channel,
                        actual_port,
                        &remote_host,
                        remote_port,
                        peer_addr,
                    )
                    .await
                    {
                        debug!("port forward proxy ended: {e}");
                        append_android_debug_log(&format!(
                            "ssh_forward_proxy_error listen=127.0.0.1:{} remote={}:{} peer={} error={}",
                            actual_port, remote_host, remote_port, peer_addr, e
                        ));
                    }
                });
            }
        });

        Ok((actual_port, task))
    }

    /// Open a direct streamlocal channel to a remote Unix socket path.
    pub async fn open_streamlocal(
        &self,
        socket_path: &str,
    ) -> Result<ChannelStream<Msg>, SshError> {
        let handle = self.handle.lock().await;
        if handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let channel = handle
            .channel_open_direct_streamlocal(socket_path)
            .await
            .map_err(|e| {
                SshError::ConnectionFailed(format!("open direct-streamlocal {socket_path}: {e}"))
            })?;
        Ok(channel.into_stream())
    }

    /// Resolve the default remote Codex IPC socket path for the current SSH user.
    pub async fn resolve_remote_ipc_socket_path(&self) -> Result<String, SshError> {
        const SCRIPT: &str = r#"uid="$(id -u 2>/dev/null || printf '0')"
tmp="${TMPDIR:-${TMP:-/tmp}}"
tmp="${tmp%/}"
printf '%s/codex-ipc/ipc-%s.sock' "$tmp" "$uid""#;
        let result = self.exec_posix(SCRIPT).await?;
        let path = result.stdout.trim().to_string();
        if path.is_empty() {
            return Err(SshError::ExecFailed {
                exit_code: result.exit_code,
                stderr: "failed to resolve remote IPC socket path".to_string(),
            });
        }
        Ok(path)
    }

    /// Return the requested IPC socket path if it exists on the remote host.
    pub async fn remote_ipc_socket_if_present(
        &self,
        override_path: Option<&str>,
    ) -> Result<Option<String>, SshError> {
        let socket_path = match override_path {
            Some(path) if path.trim().is_empty() => return Ok(None),
            Some(path) => path.to_string(),
            None => self.resolve_remote_ipc_socket_path().await?,
        };
        let check = format!(
            "if [ -S {path} ]; then printf '%s' {path}; fi",
            path = shell_quote(&socket_path),
        );
        let result = self.exec_posix(&check).await?;
        if result.exit_code != 0 {
            return Err(SshError::ExecFailed {
                exit_code: result.exit_code,
                stderr: result.stderr,
            });
        }
        let resolved = result.stdout.trim();
        if resolved.is_empty() {
            Ok(None)
        } else {
            Ok(Some(resolved.to_string()))
        }
    }

    // --------------------------------------------------------------------
    // bootstrap
    // --------------------------------------------------------------------

    /// Bootstrap a remote Codex server and set up a local tunnel.
    pub async fn bootstrap_codex_server(
        &self,
        working_dir: Option<&str>,
        prefer_ipv6: bool,
    ) -> Result<SshBootstrapResult, SshError> {
        append_bridge_info_log(&format!(
            "ssh_bootstrap_start prefer_ipv6={} working_dir={}",
            prefer_ipv6,
            working_dir.unwrap_or("<none>")
        ));
        // --- 1. Locate codex binary -------------------------------------
        let codex_binary = self.resolve_codex_binary().await?;
        info!("remote codex binary: {}", codex_binary.path());
        append_bridge_info_log(&format!(
            "ssh_bootstrap_binary path={}",
            codex_binary.path()
        ));
        self.bootstrap_codex_server_with_binary(&codex_binary, working_dir, prefer_ipv6)
            .await
    }

    pub(crate) async fn bootstrap_codex_server_with_binary(
        &self,
        codex_binary: &RemoteCodexBinary,
        working_dir: Option<&str>,
        prefer_ipv6: bool,
    ) -> Result<SshBootstrapResult, SshError> {
        let shell = self.detect_remote_shell().await;
        self.bootstrap_codex_server_with_binary_and_shell(
            codex_binary,
            working_dir,
            prefer_ipv6,
            shell,
        )
        .await
    }

    pub(crate) async fn bootstrap_codex_server_with_binary_and_shell(
        &self,
        codex_binary: &RemoteCodexBinary,
        working_dir: Option<&str>,
        prefer_ipv6: bool,
        shell: RemoteShell,
    ) -> Result<SshBootstrapResult, SshError> {
        info!(
            "ssh bootstrap begin binary={} shell={} prefer_ipv6={} working_dir={}",
            codex_binary.path(),
            remote_shell_name(shell),
            prefer_ipv6,
            working_dir.unwrap_or("<none>")
        );
        self.log_macos_keychain_unlock_for_bootstrap(shell).await?;
        // --- 2. Try candidate ports until one works ---------------------
        let cd_prefix = match (shell, working_dir) {
            (RemoteShell::Posix, Some(dir)) => format!("cd {} && ", shell_quote(dir)),
            (RemoteShell::PowerShell, Some(dir)) => format!("Set-Location {}; ", ps_quote(dir)),
            _ => String::new(),
        };

        let remote_loopback = if prefer_ipv6 { "::1" } else { "127.0.0.1" };

        for offset in 0..PORT_CANDIDATES {
            let port = DEFAULT_REMOTE_PORT + offset;
            trace!(
                "ssh bootstrap port candidate shell={} port={} attempt={}",
                remote_shell_name(shell),
                port,
                offset + 1
            );
            append_bridge_info_log(&format!(
                "ssh_bootstrap_candidate port={} attempt={}",
                port,
                offset + 1
            ));

            if self.is_port_listening_shell(port, shell).await {
                info!("port {port} already listening, probing existing candidate");
                append_bridge_info_log(&format!("ssh_bootstrap_reuse_probe_start port={}", port));

                let local_port = self.forward_port_to(0, remote_loopback, port).await?;
                let null_path = match shell {
                    RemoteShell::Posix => "/dev/null",
                    RemoteShell::PowerShell => "NUL",
                };
                let websocket_ready = self
                    .wait_for_forwarded_websocket_ready(local_port, None, shell, null_path, None)
                    .await;

                match websocket_ready {
                    Ok(()) => {
                        let version = self
                            .read_server_version_shell(codex_binary.path(), shell)
                            .await;
                        append_bridge_info_log(&format!(
                            "ssh_bootstrap_reuse_success port={} local_port={} version={}",
                            port,
                            local_port,
                            version.clone().unwrap_or_else(|| "<unknown>".to_string())
                        ));
                        return Ok(SshBootstrapResult {
                            server_port: port,
                            tunnel_local_port: local_port,
                            server_version: version,
                            pid: None,
                        });
                    }
                    Err(error) => {
                        let _ = self.abort_forward_port(local_port).await;
                        warn!(
                            "occupied port {port} did not respond like a healthy app-server: {error}"
                        );
                        append_bridge_info_log(&format!(
                            "ssh_bootstrap_reuse_probe_failed port={} error={}",
                            port, error
                        ));
                        continue;
                    }
                }
            }

            let listen_addr = if prefer_ipv6 {
                format!("[::1]:{port}")
            } else {
                format!("127.0.0.1:{port}")
            };
            let (log_path, stderr_log_path) = match shell {
                RemoteShell::Posix => (format!("/tmp/codex-mobile-server-{port}.log"), None),
                // Resolved at command time via Join-Path, not in a quoted string.
                RemoteShell::PowerShell => (
                    format!("(Join-Path $env:TEMP 'codex-mobile-server-{port}.log')"),
                    Some(format!(
                        "(Join-Path $env:TEMP 'codex-mobile-server-{port}-err.log')"
                    )),
                ),
            };

            let launch_cmd = match shell {
                RemoteShell::Posix => format!(
                    "{profile_init} {cd_prefix}nohup {launch} \
                     </dev/null >{log} 2>&1 & echo $!",
                    profile_init = PROFILE_INIT,
                    cd_prefix = cd_prefix,
                    launch =
                        server_launch_command(&codex_binary, &format!("ws://{listen_addr}"), shell),
                    log = shell_quote(&log_path),
                ),
                RemoteShell::PowerShell => {
                    let (file_path, argument_list) =
                        windows_start_process_spec(codex_binary, &format!("ws://{listen_addr}"));
                    // Use -WindowStyle Hidden instead of -NoNewWindow because
                    // Windows OpenSSH sessions have no parent console to inherit.
                    // -NoNewWindow causes -RedirectStandardOutput/-Error to
                    // silently fail in console-less environments.
                    format!(
                        r#"{cd_prefix}$logFile = {log}; $errFile = {log_err}; $proc = Start-Process -WindowStyle Hidden -PassThru -RedirectStandardOutput $logFile -RedirectStandardError $errFile -FilePath {file_path} -ArgumentList {argument_list}; Write-Host $proc.Id"#,
                        cd_prefix = cd_prefix,
                        log = log_path,
                        log_err = stderr_log_path.as_deref().expect("windows stderr log path"),
                        file_path = file_path,
                        argument_list = argument_list,
                    )
                }
            };

            let launch_result = self.exec_shell(&launch_cmd, shell).await?;
            let pid: Option<u32> = launch_result.stdout.trim().parse().ok();
            info!(
                "ssh bootstrap launched shell={} port={} pid={:?} stdout_len={} stderr_len={}",
                remote_shell_name(shell),
                port,
                pid,
                launch_result.stdout.trim().len(),
                launch_result.stderr.trim().len()
            );
            append_bridge_info_log(&format!(
                "ssh_bootstrap_launch_result port={} pid={:?} stdout={} stderr={}",
                port,
                pid,
                launch_result.stdout.trim(),
                launch_result.stderr.trim()
            ));

            // --- 3. Wait for the server to start listening ---------------
            let mut started = false;
            for _attempt in 0..60 {
                if self.is_port_listening_shell(port, shell).await {
                    started = true;
                    break;
                }

                // If the process died, check logs for "address already in use".
                if let Some(p) = pid {
                    if !self.is_process_alive_shell(p, shell).await {
                        let tail = self
                            .fetch_process_log_tail_shell(
                                &log_path,
                                stderr_log_path.as_deref(),
                                shell,
                            )
                            .await;
                        if tail.to_ascii_lowercase().contains("address already in use") {
                            info!(
                                "ssh bootstrap process exited due to occupied port shell={} port={} pid={:?}",
                                remote_shell_name(shell),
                                port,
                                pid
                            );
                            break; // try next port
                        }
                        // If logs are empty, try running the command
                        // synchronously to capture the actual error output.
                        // Run through cmd.exe with 2>&1 to merge stderr, and
                        // also check node availability.
                        let tail = if tail.is_empty() && shell == RemoteShell::PowerShell {
                            warn!(
                                "ssh bootstrap logs empty, running sync probe shell={} port={}",
                                remote_shell_name(shell),
                                port
                            );
                            let diag_cmd = format!(
                                r#"$nodeVer = & $env:ComSpec /d /c 'node --version' 2>&1 | Out-String; Write-Output "node_version:$($nodeVer.Trim())"; $out = & $env:ComSpec /d /c '"{bin}" {sub_args}--listen ws://{listen_addr}' 2>&1 | Out-String; Write-Output "server_output:$($out.Trim())""#,
                                bin = cmd_quote(codex_binary.path()),
                                sub_args = match codex_binary {
                                    RemoteCodexBinary::Codex(_) => "app-server ",
                                },
                                listen_addr = listen_addr,
                            );
                            match tokio::time::timeout(
                                Duration::from_secs(8),
                                self.exec_shell(&diag_cmd, shell),
                            )
                            .await
                            {
                                Ok(Ok(r)) => {
                                    let combined = format!(
                                        "exit_code={}\nstdout:\n{}\nstderr:\n{}",
                                        r.exit_code,
                                        r.stdout.trim(),
                                        r.stderr.trim()
                                    );
                                    info!(
                                        "ssh bootstrap sync probe result shell={} port={} output={}",
                                        remote_shell_name(shell),
                                        port,
                                        combined
                                    );
                                    if r.stdout.trim().is_empty() && r.stderr.trim().is_empty() {
                                        format!(
                                            "server process exited immediately (exit code {})",
                                            r.exit_code
                                        )
                                    } else {
                                        combined
                                    }
                                }
                                Ok(Err(e)) => format!("sync probe failed: {e}"),
                                Err(_) => {
                                    // 8s timeout — the server probably started
                                    // fine but we can't tell from this path.
                                    "server process exited immediately".into()
                                }
                            }
                        } else {
                            tail
                        };
                        warn!(
                            "ssh bootstrap process exited before listen shell={} port={} pid={:?} tail={}",
                            remote_shell_name(shell),
                            port,
                            pid,
                            tail
                        );
                        return Err(SshError::ExecFailed {
                            exit_code: 1,
                            stderr: tail,
                        });
                    }
                }

                tokio::time::sleep(Duration::from_millis(500)).await;
            }

            if !started {
                let tail = self
                    .fetch_process_log_tail_shell(&log_path, stderr_log_path.as_deref(), shell)
                    .await;
                if tail.to_ascii_lowercase().contains("address already in use") {
                    info!(
                        "ssh bootstrap listen timeout due to occupied port shell={} port={}",
                        remote_shell_name(shell),
                        port
                    );
                    continue; // try next port
                }
                warn!(
                    "ssh bootstrap timed out waiting for listen shell={} port={} tail={}",
                    remote_shell_name(shell),
                    port,
                    tail
                );
                if offset == PORT_CANDIDATES - 1 {
                    return Err(SshError::ExecFailed {
                        exit_code: 1,
                        stderr: if tail.is_empty() {
                            "timed out waiting for remote server to start".into()
                        } else {
                            tail
                        },
                    });
                }
                continue;
            }

            // --- 4. Prove the websocket endpoint is actually ready -------
            let local_port = self.forward_port_to(0, remote_loopback, port).await?;
            let websocket_ready = self
                .wait_for_forwarded_websocket_ready(
                    local_port,
                    pid,
                    shell,
                    &log_path,
                    stderr_log_path.as_deref(),
                )
                .await;

            if let Err(error) = websocket_ready {
                let _ = self.abort_forward_port(local_port).await;
                warn!("remote websocket readiness probe failed on port {port}: {error}");
                append_bridge_info_log(&format!(
                    "ssh_bootstrap_probe_failed port={} error={}",
                    port, error
                ));
                if let Some(p) = pid {
                    let kill_cmd = match shell {
                        RemoteShell::Posix => format!("kill {p} 2>/dev/null"),
                        RemoteShell::PowerShell => {
                            format!("Stop-Process -Id {p} -Force -ErrorAction SilentlyContinue")
                        }
                    };
                    let _ = self.exec_shell(&kill_cmd, shell).await;
                }
                if offset == PORT_CANDIDATES - 1 {
                    return Err(SshError::ExecFailed {
                        exit_code: 1,
                        stderr: error,
                    });
                }
                continue;
            }

            // --- 6. Optionally read server version -----------------------
            let version = self
                .read_server_version_shell(codex_binary.path(), shell)
                .await;
            info!(
                "ssh bootstrap complete shell={} remote_port={} local_port={} pid={:?} version={}",
                remote_shell_name(shell),
                port,
                local_port,
                pid,
                version.clone().unwrap_or_else(|| "<unknown>".to_string())
            );
            append_bridge_info_log(&format!(
                "ssh_bootstrap_success port={} local_port={} pid={:?} version={}",
                port,
                local_port,
                pid,
                version.clone().unwrap_or_else(|| "<unknown>".to_string())
            ));

            return Ok(SshBootstrapResult {
                server_port: port,
                tunnel_local_port: local_port,
                server_version: version,
                pid,
            });
        }

        Err(SshError::ExecFailed {
            exit_code: 1,
            stderr: "exhausted all candidate ports".into(),
        })
    }

    /// Whether the SSH session appears to still be connected.
    pub fn is_connected(&self) -> bool {
        match self.handle.try_lock() {
            Ok(h) => !h.is_closed(),
            Err(_) => true, // locked = in use = presumably connected
        }
    }

    /// Disconnect the SSH session, aborting any port forwards.
    pub async fn disconnect(&self) {
        // Abort all forwarding tasks.
        let mut tasks = self.forward_tasks.lock().await;
        for (_, task) in tasks.drain() {
            task.task.abort();
        }
        drop(tasks);

        let handle = self.handle.lock().await;
        let _ = handle
            .disconnect(russh::Disconnect::ByApplication, "bye", "en")
            .await;
    }

    // --------------------------------------------------------------------
    // Private helpers
    // --------------------------------------------------------------------

    /// Locate the `codex` binary on the remote host.
    pub(crate) async fn resolve_codex_binary_optional(
        &self,
    ) -> Result<Option<RemoteCodexBinary>, SshError> {
        self.resolve_codex_binary_optional_with_shell(None).await
    }

    pub(crate) async fn resolve_codex_binary_optional_with_shell(
        &self,
        shell_hint: Option<RemoteShell>,
    ) -> Result<Option<RemoteCodexBinary>, SshError> {
        let shell = match shell_hint {
            Some(s) => s,
            None => self.detect_remote_shell().await,
        };
        trace!(
            "ssh resolve codex binary shell={}",
            remote_shell_name(shell)
        );

        let script = match shell {
            RemoteShell::PowerShell => resolve_codex_binary_script_powershell(),
            RemoteShell::Posix => resolve_codex_binary_script_posix(),
        };

        let result = self.exec_shell(&script, shell).await?;
        let raw = result.stdout.trim();
        if raw.is_empty() {
            info!(
                "ssh resolve codex binary missing shell={}",
                remote_shell_name(shell)
            );
            return Ok(None);
        }
        if let Some(path) = raw.strip_prefix("codex:") {
            info!(
                "ssh resolve codex binary found selector=codex shell={} path={}",
                remote_shell_name(shell),
                path
            );
            return Ok(Some(RemoteCodexBinary::Codex(path.to_string())));
        }
        warn!(
            "ssh resolve codex binary unexpected selector shell={} raw={}",
            remote_shell_name(shell),
            raw
        );
        Err(SshError::ExecFailed {
            exit_code: 1,
            stderr: format!("unexpected remote codex binary selector: {raw}"),
        })
    }

    async fn resolve_codex_binary(&self) -> Result<RemoteCodexBinary, SshError> {
        match self.resolve_codex_binary_optional().await? {
            Some(binary) => Ok(binary),
            None => {
                let diagnostics = self.fetch_codex_resolver_diagnostics().await;
                Err(SshError::ExecFailed {
                    exit_code: 1,
                    stderr: if diagnostics.is_empty() {
                        "codex not found on remote host".into()
                    } else {
                        format!(
                            "codex not found on remote host\nresolver diagnostics:\n{}",
                            diagnostics
                        )
                    },
                })
            }
        }
    }

    async fn fetch_codex_resolver_diagnostics(&self) -> String {
        let script = format!(
            r#"{profile_init}
{pkg_probe}
printf 'shell=%s\n' "${{SHELL:-}}"
printf 'path=%s\n' "${{PATH:-}}"
printf 'pnpm_home=%s\n' "${{PNPM_HOME:-}}"
printf 'nvm_bin=%s\n' "${{NVM_BIN:-}}"
printf 'npm_prefix=%s\n' "$_litter_npm_prefix"
printf 'bun_global_bin=%s\n' "$_litter_bun_global_bin"
printf 'pnpm_global_bin=%s\n' "$_litter_pnpm_global_bin"
printf 'npm_global_bin=%s\n' "$_litter_npm_global_bin"
printf 'whoami='; whoami 2>/dev/null || true
printf 'pwd='; pwd 2>/dev/null || true
printf 'command -v codex='
command -v codex 2>/dev/null || printf '<missing>'
printf '\n'
for candidate in \
  "$HOME/.litter/bin/codex" \
  "$HOME/.litter/codex/node_modules/.bin/codex" \
  "${{BUN_INSTALL:-$HOME/.bun}}/bin/codex" \
  "$HOME/.volta/bin/codex" \
  "$HOME/.local/bin/codex" \
  "${{PNPM_HOME:-}}/codex" \
  "${{NVM_BIN:-}}/codex" \
  "${{VOLTA_HOME:+$VOLTA_HOME/bin/codex}}" \
  "${{CARGO_HOME:-$HOME/.cargo}}/bin/codex" \
  "${{_litter_bun_global_bin:-}}/codex" \
  "${{_litter_npm_global_bin:-}}/codex" \
  "${{_litter_pnpm_global_bin:-}}/codex" \
  "/opt/homebrew/bin/codex" \
  "/usr/local/bin/codex" 
do
  if [ -e "$candidate" ]; then
    if [ -x "$candidate" ]; then
      printf 'candidate=%s [exists executable]\n' "$candidate"
    else
      printf 'candidate=%s [exists not-executable]\n' "$candidate"
    fi
  fi
done"#,
            profile_init = PROFILE_INIT,
            pkg_probe = PACKAGE_MANAGER_PROBE
        );

        match self.exec_posix(&script).await {
            Ok(result) => result.stdout.trim().to_string(),
            Err(error) => format!("failed to collect resolver diagnostics: {error}"),
        }
    }

    async fn is_port_listening_shell(&self, port: u16, shell: RemoteShell) -> bool {
        let cmd = match shell {
            RemoteShell::Posix => format!(
                r#"if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP:{port} -sTCP:LISTEN -t 2>/dev/null | head -n 1
elif command -v ss >/dev/null 2>&1; then
  ss -ltn "sport = :{port}" 2>/dev/null | tail -n +2 | head -n 1
elif command -v netstat >/dev/null 2>&1; then
  netstat -ltn 2>/dev/null | awk '{{print $4}}' | grep -E '[:\.]{port}$' | head -n 1
fi"#
            ),
            RemoteShell::PowerShell => format!(
                r#"Get-NetTCPConnection -LocalPort {port} -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty LocalPort"#
            ),
        };

        match self.exec_shell(&cmd, shell).await {
            Ok(r) => !r.stdout.trim().is_empty(),
            Err(_) => false,
        }
    }

    async fn is_process_alive_shell(&self, pid: u32, shell: RemoteShell) -> bool {
        let cmd = match shell {
            RemoteShell::Posix => {
                format!("kill -0 {pid} >/dev/null 2>&1 && echo alive || echo dead")
            }
            RemoteShell::PowerShell => format!(
                r#"if (Get-Process -Id {pid} -ErrorAction SilentlyContinue) {{ Write-Host 'alive' }} else {{ Write-Host 'dead' }}"#
            ),
        };
        match self.exec_shell(&cmd, shell).await {
            Ok(r) => r.stdout.trim() == "alive",
            Err(_) => false,
        }
    }

    pub(crate) async fn kill_listener_on_port(&self, port: u16) -> Result<ExecResult, SshError> {
        let shell = self.detect_remote_shell().await;
        self.kill_listener_on_port_shell(port, shell).await
    }

    async fn kill_listener_on_port_shell(
        &self,
        port: u16,
        shell: RemoteShell,
    ) -> Result<ExecResult, SshError> {
        let cmd = match shell {
            RemoteShell::Posix => format!(
                r#"pids=""
if command -v lsof >/dev/null 2>&1; then
  pids="$(lsof -nP -iTCP:{port} -sTCP:LISTEN -t 2>/dev/null | sort -u)"
fi
if [ -z "$pids" ] && command -v fuser >/dev/null 2>&1; then
  pids="$(fuser {port}/tcp 2>/dev/null | tr ' ' '\n' | sort -u)"
fi
if [ -z "$pids" ]; then
  printf 'litter_restart_app_server no_listener port={port}\n'
  exit 0
fi
printf 'litter_restart_app_server killing port={port} pids=%s\n' "$pids"
kill $pids 2>/dev/null || true
sleep 1
alive=""
for pid in $pids; do
  if kill -0 "$pid" 2>/dev/null; then
    alive="$alive $pid"
  fi
done
if [ -n "$alive" ]; then
  kill -9 $alive 2>/dev/null || true
  printf 'litter_restart_app_server force_killed port={port} pids=%s\n' "$alive"
else
  printf 'litter_restart_app_server stopped port={port}\n'
fi"#
            ),
            RemoteShell::PowerShell => format!(
                r#"$connections = Get-NetTCPConnection -LocalPort {port} -State Listen -ErrorAction SilentlyContinue
$pids = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
if ($pids.Count -eq 0) {{
  Write-Host 'litter_restart_app_server no_listener port={port}'
  exit 0
}}
Write-Host "litter_restart_app_server killing port={port} pids=$($pids -join ',')"
foreach ($processId in $pids) {{
  Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
}}
Write-Host 'litter_restart_app_server stopped port={port}'"#
            ),
        };

        self.exec_shell(&cmd, shell).await
    }

    async fn fetch_log_tail_shell(&self, log_path: &str, shell: RemoteShell) -> String {
        let cmd = match shell {
            RemoteShell::Posix => {
                format!("tail -n 25 {} 2>/dev/null", shell_quote(log_path))
            }
            RemoteShell::PowerShell => {
                // log_path may be a PS expression like (Join-Path $env:TEMP '...'),
                // so resolve it into $p first.
                format!(
                    "$p = {lp}; if (Test-Path $p) {{ Get-Content -Path $p -Tail 25 }}",
                    lp = log_path
                )
            }
        };
        match self.exec_shell(&cmd, shell).await {
            Ok(r) => r.stdout.trim().to_string(),
            Err(_) => String::new(),
        }
    }

    async fn fetch_process_log_tail_shell(
        &self,
        stdout_log_path: &str,
        stderr_log_path: Option<&str>,
        shell: RemoteShell,
    ) -> String {
        let stdout_tail = self.fetch_log_tail_shell(stdout_log_path, shell).await;
        let stderr_tail = match stderr_log_path {
            Some(path) => self.fetch_log_tail_shell(path, shell).await,
            None => String::new(),
        };
        format_process_logs(&stdout_tail, &stderr_tail)
    }

    async fn wait_for_forwarded_websocket_ready(
        &self,
        local_port: u16,
        pid: Option<u32>,
        shell: RemoteShell,
        stdout_log_path: &str,
        stderr_log_path: Option<&str>,
    ) -> Result<(), String> {
        let websocket_url = format!("ws://127.0.0.1:{local_port}");
        let mut last_error = String::new();

        for attempt in 0..20 {
            match connect_async(&websocket_url).await {
                Ok((mut websocket, _)) => {
                    let _ = websocket.close(None).await;
                    append_bridge_info_log(&format!(
                        "ssh_bootstrap_probe_success url={} attempt={}",
                        websocket_url,
                        attempt + 1
                    ));
                    return Ok(());
                }
                Err(error) => {
                    last_error = error.to_string();
                    if attempt == 0 || attempt == 19 {
                        append_bridge_info_log(&format!(
                            "ssh_bootstrap_probe_retry url={} attempt={} error={}",
                            websocket_url,
                            attempt + 1,
                            last_error
                        ));
                    }
                }
            }

            if let Some(p) = pid {
                if !self.is_process_alive_shell(p, shell).await {
                    let tail = self
                        .fetch_process_log_tail_shell(stdout_log_path, stderr_log_path, shell)
                        .await;
                    return Err(if tail.is_empty() { last_error } else { tail });
                }
            }

            tokio::time::sleep(Duration::from_millis(250)).await;
        }

        let tail = self
            .fetch_process_log_tail_shell(stdout_log_path, stderr_log_path, shell)
            .await;
        Err(if tail.is_empty() {
            format!("websocket readiness probe failed: {last_error}")
        } else if last_error.is_empty() {
            tail
        } else {
            format!("{tail}\nwebsocket readiness probe failed: {last_error}")
        })
    }

    async fn read_server_version_shell(
        &self,
        codex_path: &str,
        shell: RemoteShell,
    ) -> Option<String> {
        let cmd = match shell {
            RemoteShell::Posix => format!(
                "{} {} --version 2>/dev/null",
                PROFILE_INIT,
                shell_quote(codex_path)
            ),
            RemoteShell::PowerShell => format!("& {} --version 2>$null", ps_quote(codex_path)),
        };
        match self.exec_shell(&cmd, shell).await {
            Ok(r) if r.exit_code == 0 => {
                let v = r.stdout.trim().to_string();
                if v.is_empty() { None } else { Some(v) }
            }
            _ => None,
        }
    }

    pub(crate) async fn detect_remote_shell(&self) -> RemoteShell {
        // cmd.exe: `echo %OS%` → "Windows_NT"
        // PowerShell: `echo %OS%` → "%OS%" (literal)
        // bash: `echo %OS%` → "%OS%" (literal)
        if let Ok(result) = self.exec("echo %OS%").await {
            let out = result.stdout.trim();
            append_bridge_info_log(&format!(
                "ssh_detect_shell cmd_probe out={:?} exit={}",
                out, result.exit_code
            ));
            if out == "Windows_NT" {
                info!("ssh detect shell result=powershell via=cmd_probe");
                return RemoteShell::PowerShell;
            }
        }
        // Also try PowerShell syntax in case the default shell IS PowerShell.
        if let Ok(result) = self.exec("echo $env:OS").await {
            let out = result.stdout.trim();
            append_bridge_info_log(&format!(
                "ssh_detect_shell ps_probe out={:?} exit={}",
                out, result.exit_code
            ));
            if out.contains("Windows") {
                info!("ssh detect shell result=powershell via=ps_probe");
                return RemoteShell::PowerShell;
            }
        }
        append_bridge_info_log("ssh_detect_shell result=Posix");
        info!("ssh detect shell result=posix");
        RemoteShell::Posix
    }

    /// Execute a command using the appropriate shell. For PowerShell commands,
    /// wraps in `powershell -NoProfile -Command "..."` since Windows OpenSSH
    /// defaults to cmd.exe.
    pub(crate) async fn exec_shell(
        &self,
        command: &str,
        shell: RemoteShell,
    ) -> Result<ExecResult, SshError> {
        trace!(
            "ssh exec shell={} command_len={}",
            remote_shell_name(shell),
            command.len()
        );
        append_android_debug_log(&format!(
            "ssh_exec_shell shell={} command={}",
            remote_shell_name(shell),
            redact_ssh_command_for_log(command)
        ));
        match shell {
            // Force bootstrap scripts through a POSIX shell even when the
            // account's login shell is fish or another non-POSIX shell.
            RemoteShell::Posix => self.exec_posix(command).await,
            RemoteShell::PowerShell => {
                // Use -EncodedCommand to avoid all escaping issues between
                // cmd.exe and PowerShell. The encoded command is a UTF-16LE
                // base64 string that PowerShell decodes directly.
                let utf16: Vec<u8> = command
                    .encode_utf16()
                    .flat_map(|c| c.to_le_bytes())
                    .collect();
                let encoded = base64::engine::general_purpose::STANDARD.encode(&utf16);
                let mut result = self
                    .exec(&format!(
                        "powershell -NoProfile -NonInteractive -EncodedCommand {}",
                        encoded
                    ))
                    .await?;
                // Strip CLIXML noise that PowerShell emits over SSH.
                result.stdout = strip_clixml(&result.stdout);
                result.stderr = strip_clixml(&result.stderr);
                Ok(result)
            }
        }
    }

    async fn exec_posix(&self, command: &str) -> Result<ExecResult, SshError> {
        self.exec(&build_posix_exec_command(command)).await
    }

    pub(crate) async fn detect_remote_platform_with_shell(
        &self,
        shell_hint: Option<RemoteShell>,
    ) -> Result<RemotePlatform, SshError> {
        let shell = match shell_hint {
            Some(s) => s,
            None => self.detect_remote_shell().await,
        };
        info!(
            "ssh detect platform start shell={}",
            remote_shell_name(shell)
        );

        match shell {
            RemoteShell::PowerShell => {
                let result = self
                    .exec_shell(
                        r#"Write-Output "$env:OS"; Write-Output "$env:PROCESSOR_ARCHITECTURE""#,
                        shell,
                    )
                    .await?;
                let mut lines = result.stdout.lines();
                let os = lines.next().unwrap_or_default().trim();
                let arch = lines.next().unwrap_or_default().trim();
                let platform = match (os, arch) {
                    ("Windows_NT", "AMD64") | ("Windows_NT", "x86_64") => {
                        Ok(RemotePlatform::WindowsX64)
                    }
                    ("Windows_NT", "ARM64") | ("Windows_NT", "aarch64") => {
                        Ok(RemotePlatform::WindowsArm64)
                    }
                    _ => Err(SshError::ExecFailed {
                        exit_code: 1,
                        stderr: format!("unsupported Windows platform: os={os} arch={arch}"),
                    }),
                }?;
                info!(
                    "ssh detect platform result shell={} os={} arch={} platform={}",
                    remote_shell_name(shell),
                    os,
                    arch,
                    remote_platform_name(platform)
                );
                Ok(platform)
            }
            RemoteShell::Posix => {
                let result = self
                    .exec_posix(
                        r#"uname_s="$(uname -s 2>/dev/null || true)"; uname_m="$(uname -m 2>/dev/null || true)"; printf '%s\n%s' "$uname_s" "$uname_m""#,
                    )
                    .await?;
                let mut lines = result.stdout.lines();
                let os = lines.next().unwrap_or_default().trim();
                let arch = lines.next().unwrap_or_default().trim();
                let platform = match (os, arch) {
                    ("Darwin", "arm64") | ("Darwin", "aarch64") => Ok(RemotePlatform::MacosArm64),
                    ("Darwin", "x86_64") | ("Darwin", "amd64") => Ok(RemotePlatform::MacosX64),
                    ("Linux", "aarch64") | ("Linux", "arm64") => Ok(RemotePlatform::LinuxArm64),
                    ("Linux", "x86_64") | ("Linux", "amd64") => Ok(RemotePlatform::LinuxX64),
                    _ => Err(SshError::ExecFailed {
                        exit_code: 1,
                        stderr: format!("unsupported remote platform: os={os} arch={arch}"),
                    }),
                }?;
                info!(
                    "ssh detect platform result shell={} os={} arch={} platform={}",
                    remote_shell_name(shell),
                    os,
                    arch,
                    remote_platform_name(platform)
                );
                Ok(platform)
            }
        }
    }

    pub(crate) async fn install_latest_stable_codex(
        &self,
        platform: RemotePlatform,
    ) -> Result<(RemoteCodexBinary, CodexInstallOutcome), SshError> {
        info!(
            "ssh install codex start platform={}",
            remote_platform_name(platform)
        );
        if platform.is_windows() {
            info!(
                "ssh install codex using npm platform={}",
                remote_platform_name(platform)
            );
            return self.install_codex_via_npm(RemoteShell::PowerShell).await;
        }
        let release = fetch_latest_stable_codex_release(platform).await?;
        info!(
            "ssh install codex using release platform={} tag={} asset={}",
            remote_platform_name(platform),
            release.tag_name,
            release.asset_name
        );
        let install_script = format!(
            r#"set -e
tag={tag}
asset_name={asset_name}
binary_name={binary_name}
download_url={download_url}
dest_dir="$HOME/.litter/codex/$tag"
dest_bin="$dest_dir/codex"
stable_bin="$HOME/.litter/bin/codex"
tmpdir="$(mktemp -d "${{TMPDIR:-/tmp}}/litter-codex.XXXXXX")"
cleanup() {{
  rm -rf "$tmpdir"
}}
trap cleanup EXIT
mkdir -p "$dest_dir" "$HOME/.litter/bin"
status="up-to-date"
if [ ! -x "$dest_bin" ]; then
  status="installed"
  archive_path="$tmpdir/$asset_name"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$download_url" -o "$archive_path"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$archive_path" "$download_url"
  else
    echo "curl or wget is required to install Codex" >&2
    exit 1
  fi
  tar -xzf "$archive_path" -C "$tmpdir"
  extracted="$tmpdir/$binary_name"
  if [ ! -f "$extracted" ]; then
    echo "expected binary '$binary_name' not found in release archive" >&2
    exit 1
  fi
  if command -v install >/dev/null 2>&1; then
    install -m 0755 "$extracted" "$dest_bin"
  else
    cp "$extracted" "$dest_bin"
    chmod 0755 "$dest_bin"
  fi
fi
ln -sf "$dest_bin" "$stable_bin"
printf 'STATUS:%s\nPATH:%s\n' "$status" "$stable_bin""#,
            tag = shell_quote(&release.tag_name),
            asset_name = shell_quote(&release.asset_name),
            binary_name = shell_quote(&release.binary_name),
            download_url = shell_quote(&release.download_url),
        );
        let result = self.exec_posix(&install_script).await?;
        if result.exit_code != 0 {
            return Err(SshError::ExecFailed {
                exit_code: result.exit_code,
                stderr: if result.stderr.trim().is_empty() {
                    "failed to install Codex".to_string()
                } else {
                    result.stderr
                },
            });
        }
        let (status, installed_path) = parse_install_status_and_path(&result.stdout);
        let outcome = match status.as_deref() {
            Some("up-to-date") => CodexInstallOutcome::AlreadyAtLatestTag,
            _ => CodexInstallOutcome::Installed,
        };
        let path = installed_path.unwrap_or_else(|| "$HOME/.litter/bin/codex".to_string());
        info!(
            "ssh install codex completed platform={} path={} outcome={:?}",
            remote_platform_name(platform),
            path,
            outcome
        );
        Ok((RemoteCodexBinary::Codex(path), outcome))
    }

    /// Install Codex via npm into `~/.litter/codex/` (works on Windows and
    /// as a POSIX fallback when no binary release is available).
    pub(crate) async fn install_codex_via_npm(
        &self,
        shell: RemoteShell,
    ) -> Result<(RemoteCodexBinary, CodexInstallOutcome), SshError> {
        info!(
            "ssh npm install codex start shell={}",
            remote_shell_name(shell)
        );
        let script = match shell {
            RemoteShell::PowerShell => {
                // `@openai/codex@latest` forces npm past any semver range left
                // in package.json from a previous install, so re-running this
                // script reliably bumps to the newest published version.
                r#"$ErrorActionPreference = 'Stop'
$litterDir = Join-Path $env:USERPROFILE '.litter\codex'
if (-not (Test-Path $litterDir)) { New-Item -ItemType Directory -Path $litterDir -Force | Out-Null }
Set-Location $litterDir
if (-not (Test-Path 'package.json')) { npm init -y 2>$null | Out-Null }
npm install @openai/codex@latest 2>$null | Out-Null
$bin = Join-Path $litterDir 'node_modules\.bin\codex.cmd'
if (Test-Path $bin) { Write-Output "CODEX_PATH:$bin" } else { Write-Error 'codex.cmd not found after install'; exit 1 }"#.to_string()
            }
            RemoteShell::Posix => {
                format!(
                    r#"{profile_init}
set -e
litter_dir="$HOME/.litter/codex"
mkdir -p "$litter_dir"
cd "$litter_dir"
[ -f package.json ] || npm init -y >/dev/null 2>&1
npm install @openai/codex@latest >/dev/null 2>&1
bin="$litter_dir/node_modules/.bin/codex"
if [ -x "$bin" ]; then printf 'CODEX_PATH:%s' "$bin"; else echo "codex not found after install" >&2; exit 1; fi"#,
                    profile_init = PROFILE_INIT
                )
            }
        };

        let result = self.exec_shell(&script, shell).await?;
        if result.exit_code != 0 {
            warn!(
                "ssh npm install codex failed shell={} exit_code={} stderr={}",
                remote_shell_name(shell),
                result.exit_code,
                result.stderr.trim()
            );
            return Err(SshError::ExecFailed {
                exit_code: result.exit_code,
                stderr: if result.stderr.trim().is_empty() {
                    "npm install @openai/codex failed".to_string()
                } else {
                    result.stderr
                },
            });
        }
        let installed_path = result
            .stdout
            .lines()
            .find_map(|line| line.trim().strip_prefix("CODEX_PATH:"))
            .map(|p| p.trim().to_string());
        match installed_path {
            Some(path) if !path.is_empty() => {
                info!(
                    "ssh npm install codex completed shell={} path={}",
                    remote_shell_name(shell),
                    path
                );
                Ok((
                    RemoteCodexBinary::Codex(path),
                    CodexInstallOutcome::Installed,
                ))
            }
            _ => {
                append_bridge_info_log(&format!(
                    "ssh_npm_install_no_path stdout={:?} stderr={:?}",
                    result.stdout, result.stderr
                ));
                Err(SshError::ExecFailed {
                    exit_code: 1,
                    stderr: format!(
                        "codex binary path not returned after npm install. stdout: {}",
                        result.stdout.chars().take(200).collect::<String>()
                    ),
                })
            }
        }
    }

    /// Best-effort: if `binary` was installed by us under `~/.litter/` and
    /// the update sentinel is older than 24h, check for a newer release and
    /// install it. Any failure along the way is swallowed and logged — the
    /// caller continues to use the previously-resolved binary.
    pub(crate) async fn maybe_update_managed_codex(
        &self,
        binary: &RemoteCodexBinary,
        shell: RemoteShell,
    ) -> Option<(RemoteCodexBinary, CodexInstallOutcome)> {
        let path = binary.path();
        let is_managed = path.contains("/.litter/") || path.contains(r"\.litter\");
        if !is_managed {
            trace!("ssh codex update check: skipping non-managed path={}", path);
            return None;
        }

        match self.is_codex_update_check_due(shell).await {
            Ok(true) => {}
            Ok(false) => {
                trace!("ssh codex update check: sentinel fresh, skipping");
                return None;
            }
            Err(err) => {
                warn!("ssh codex update check: sentinel check failed: {err}");
                return None;
            }
        }

        info!(
            "ssh codex update check: probing for newer release path={} shell={}",
            path,
            remote_shell_name(shell)
        );

        let is_windows_shell = matches!(shell, RemoteShell::PowerShell);
        let looks_like_npm =
            path.contains("node_modules/.bin/codex") || path.contains(r"node_modules\.bin\codex");

        let result: Result<(RemoteCodexBinary, CodexInstallOutcome), SshError> =
            if looks_like_npm || is_windows_shell {
                self.install_codex_via_npm(shell).await
            } else {
                match self.detect_remote_platform_with_shell(Some(shell)).await {
                    Ok(platform) => self.install_latest_stable_codex(platform).await,
                    Err(err) => Err(err),
                }
            };

        // Always touch the sentinel — success, "up to date", or failure —
        // so we don't re-hit GitHub/npm on every reconnect within 24h.
        if let Err(err) = self.touch_codex_update_sentinel(shell).await {
            warn!("ssh codex update check: sentinel touch failed: {err}");
        }

        match result {
            Ok((new_binary, outcome)) => {
                info!(
                    "ssh codex update check: completed outcome={:?} path={}",
                    outcome,
                    new_binary.path()
                );
                Some((new_binary, outcome))
            }
            Err(err) => {
                warn!(
                    "ssh codex update check: update attempt failed, continuing with existing binary: {err}"
                );
                None
            }
        }
    }

    async fn is_codex_update_check_due(&self, shell: RemoteShell) -> Result<bool, SshError> {
        let script = match shell {
            RemoteShell::Posix => format!(
                r#"sentinel="$HOME/.litter/codex/.last-update-check"
if [ -f "$sentinel" ]; then
  now=$(date +%s 2>/dev/null || echo 0)
  last=$(stat -c %Y "$sentinel" 2>/dev/null || stat -f %m "$sentinel" 2>/dev/null || echo 0)
  if [ "$last" -gt 0 ] && [ "$now" -gt 0 ]; then
    age=$((now - last))
    if [ "$age" -lt {interval} ]; then
      printf 'FRESH'
      exit 0
    fi
  fi
fi
printf 'STALE'"#,
                interval = CODEX_UPDATE_CHECK_INTERVAL_SECS
            ),
            RemoteShell::PowerShell => format!(
                r#"$sentinel = Join-Path $env:USERPROFILE '.litter\codex\.last-update-check'
if (Test-Path $sentinel) {{
  $age = (Get-Date) - (Get-Item $sentinel).LastWriteTime
  if ($age.TotalSeconds -lt {interval}) {{ Write-Output 'FRESH'; exit 0 }}
}}
Write-Output 'STALE'"#,
                interval = CODEX_UPDATE_CHECK_INTERVAL_SECS
            ),
        };
        let result = self.exec_shell(&script, shell).await?;
        Ok(!result.stdout.trim().eq_ignore_ascii_case("FRESH"))
    }

    async fn touch_codex_update_sentinel(&self, shell: RemoteShell) -> Result<(), SshError> {
        let script = match shell {
            RemoteShell::Posix => r#"mkdir -p "$HOME/.litter/codex" 2>/dev/null || true
touch "$HOME/.litter/codex/.last-update-check" 2>/dev/null || true"#
                .to_string(),
            RemoteShell::PowerShell => {
                r#"$dir = Join-Path $env:USERPROFILE '.litter\codex'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$sentinel = Join-Path $dir '.last-update-check'
if (Test-Path $sentinel) { (Get-Item $sentinel).LastWriteTime = Get-Date } else { Set-Content -Path $sentinel -Value '' }"#
                    .to_string()
            }
        };
        self.exec_shell(&script, shell).await?;
        Ok(())
    }

    async fn log_macos_keychain_unlock_for_bootstrap(
        &self,
        shell: RemoteShell,
    ) -> Result<(), SshError> {
        if shell != RemoteShell::Posix {
            append_bridge_info_log(&format!(
                "ssh_bootstrap_keychain_unlock skipped shell={}",
                remote_shell_name(shell)
            ));
            return Ok(());
        }

        let Some(command) = self.posix_macos_keychain_unlock_command() else {
            append_bridge_info_log("ssh_bootstrap_keychain_unlock skipped reason=disabled");
            return Ok(());
        };

        let result = self.exec_shell(&command, shell).await?;
        let output = result.stderr.trim();
        if output.is_empty() {
            info!(
                "ssh bootstrap keychain unlock output shell={} exit_code={} <empty>",
                remote_shell_name(shell),
                result.exit_code
            );
        } else {
            info!(
                "ssh bootstrap keychain unlock output shell={} exit_code={} {}",
                remote_shell_name(shell),
                result.exit_code,
                output
            );
        }
        append_bridge_info_log(&format!(
            "ssh_bootstrap_keychain_unlock exit_code={} stderr={}",
            result.exit_code, output
        ));
        Ok(())
    }

    fn posix_macos_keychain_unlock_command(&self) -> Option<String> {
        let password = self.macos_keychain_password.as_deref()?;

        Some(format!(
            r#"if command -v security >/dev/null 2>&1 && [ -e "$HOME/Library/Keychains/login.keychain-db" ]; then _litter_kc_path="$HOME/Library/Keychains/login.keychain-db"; printf 'litter_keychain_unlock start path=%s\n' "$_litter_kc_path" >&2; _litter_kc_output="$(security unlock-keychain -p {password} "$_litter_kc_path" 2>&1 >/dev/null)"; _litter_kc_status=$?; _litter_kc_output="$(printf '%s' "$_litter_kc_output" | tr '\n' ' ')"; printf 'litter_keychain_unlock result status=%s stderr=%s\n' "$_litter_kc_status" "$_litter_kc_output" >&2; exit 0; else printf 'litter_keychain_unlock skipped reason=security_or_login_keychain_missing\n' >&2; exit 0; fi"#,
            password = shell_quote(password),
        ))
    }
}

/// Parse the `STATUS:...` / `PATH:...` lines emitted by the tarball install
/// script. Either may be missing (older script output / truncation) —
/// callers must handle `None` gracefully.
fn parse_install_status_and_path(stdout: &str) -> (Option<String>, Option<String>) {
    let mut status = None;
    let mut path = None;
    for line in stdout.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("STATUS:") {
            status = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("PATH:") {
            path = Some(rest.trim().to_string());
        }
    }
    // Backcompat: if neither prefix was emitted, treat entire trimmed stdout
    // as the path (matches pre-STATUS format).
    if status.is_none() && path.is_none() {
        let trimmed = stdout.trim();
        if !trimmed.is_empty() {
            path = Some(trimmed.to_string());
        }
    }
    (status, path)
}

// ---------------------------------------------------------------------------
// Port-forward proxy
// ---------------------------------------------------------------------------

/// Bidirectionally proxy data between a local TCP stream and an SSH channel.
///
/// Uses `make_writer()` to obtain an independent write handle (which clones
/// internal channel senders), then spawns local-to-remote copying in a separate
/// task while the current task handles remote-to-local via `channel.wait()`.
async fn proxy_connection(
    local: tokio::net::TcpStream,
    mut ssh_channel: russh::Channel<Msg>,
    local_port: u16,
    remote_host: &str,
    remote_port: u16,
    peer_addr: std::net::SocketAddr,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let remote_host = remote_host.to_string();

    // `make_writer` clones internal senders so it can be used independently
    // from `channel.wait()` which takes `&mut self`.
    let mut ssh_writer = ssh_channel.make_writer();

    // `into_split` gives us owned halves that are `Send + 'static`.
    let (mut local_read, mut local_write) = local.into_split();

    // Spawn local -> remote copying.
    let local_to_remote_remote_host = remote_host.clone();
    let local_to_remote = tokio::spawn(async move {
        let mut buf = vec![0u8; 32768];
        loop {
            match local_read.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if ssh_writer.write_all(&buf[..n]).await.is_err() {
                        append_android_debug_log(&format!(
                            "ssh_forward_local_to_remote_write_failed listen=127.0.0.1:{} remote={}:{} peer={}",
                            local_port, local_to_remote_remote_host, remote_port, peer_addr
                        ));
                        break;
                    }
                }
                Err(error) => {
                    append_android_debug_log(&format!(
                        "ssh_forward_local_read_error listen=127.0.0.1:{} remote={}:{} peer={} error={}",
                        local_port, local_to_remote_remote_host, remote_port, peer_addr, error
                    ));
                    break;
                }
            }
        }
        // Dropping ssh_writer signals we are done writing to the channel.
    });

    // Remote -> local: drain channel messages on the current task.
    loop {
        match ssh_channel.wait().await {
            Some(ChannelMsg::Data { data }) => {
                if local_write.write_all(&data).await.is_err() {
                    append_android_debug_log(&format!(
                        "ssh_forward_local_write_failed listen=127.0.0.1:{} remote={}:{} peer={}",
                        local_port, remote_host, remote_port, peer_addr
                    ));
                    break;
                }
            }
            Some(ChannelMsg::Eof) => {
                append_android_debug_log(&format!(
                    "ssh_forward_channel_eof listen=127.0.0.1:{} remote={}:{} peer={}",
                    local_port, remote_host, remote_port, peer_addr
                ));
                break;
            }
            Some(ChannelMsg::Close) => {
                append_android_debug_log(&format!(
                    "ssh_forward_channel_close listen=127.0.0.1:{} remote={}:{} peer={}",
                    local_port, remote_host, remote_port, peer_addr
                ));
                break;
            }
            None => {
                append_android_debug_log(&format!(
                    "ssh_forward_channel_ended listen=127.0.0.1:{} remote={}:{} peer={}",
                    local_port, remote_host, remote_port, peer_addr
                ));
                break;
            }
            _ => {}
        }
    }

    local_to_remote.abort();
    let _ = ssh_channel.close().await;

    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Shell snippet that sources common profile files to pick up PATH additions.
/// Runs each file in a subshell so shell-specific syntax cannot crash the
/// parent `/bin/sh` process, then imports the resulting PATH into the current
/// shell via a temp file. SSH non-login commands on macOS often start with a
/// minimal PATH, so append common user/package-manager bin directories too.
pub(crate) const PROFILE_INIT: &str = r#"_litter_pf="/tmp/.litter_path_$$"; if [ -n "$SHELL" ] && [ -x "$SHELL" ]; then "$SHELL" -lc 'printf %s "$PATH"' > "$_litter_pf" 2>/dev/null && [ -s "$_litter_pf" ] && PATH="$(cat "$_litter_pf")"; fi; for f in "$HOME/.zshenv" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do [ -f "$f" ] && (. "$f" 2>/dev/null; echo "$PATH") > "$_litter_pf" 2>/dev/null && PATH="$(cat "$_litter_pf")" ; done; rm -f "$_litter_pf" 2>/dev/null; _litter_add_path() { case ":$PATH:" in *":$1:"*) ;; *) [ -d "$1" ] && PATH="$1:$PATH" ;; esac; }; _litter_add_path "$NVM_BIN"; _litter_nvm_dir="${NVM_DIR:-$HOME/.nvm}"; for d in "$_litter_nvm_dir"/versions/node/*/bin; do _litter_add_path "$d"; done; _litter_add_path "$ASDF_DATA_DIR/shims"; _litter_add_path "$HOME/.asdf/shims"; _litter_add_path "${BUN_INSTALL:-$HOME/.bun}/bin"; _litter_add_path "$HOME/.volta/bin"; _litter_add_path "$HOME/.local/bin"; _litter_add_path "${CARGO_HOME:-$HOME/.cargo}/bin"; _litter_add_path "/opt/homebrew/opt/node/bin"; _litter_add_path "/opt/homebrew/bin"; _litter_add_path "/usr/local/opt/node/bin"; _litter_add_path "/usr/local/bin"; export PATH;"#;

/// Shell snippet that probes npm/pnpm for their global binary directories.
/// Sets `_litter_npm_prefix`, `_litter_npm_global_bin`,
/// `_litter_pnpm_global_bin`, and `_litter_bun_global_bin`.
const PACKAGE_MANAGER_PROBE: &str = r#"_litter_npm_prefix=""
_litter_npm_global_bin=""
_litter_pnpm_global_bin=""
_litter_bun_global_bin=""
if command -v npm >/dev/null 2>&1; then
  _litter_npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  case "$_litter_npm_prefix" in
    "" | "undefined" | "null")
      _litter_npm_prefix=""
      ;;
    *)
      _litter_npm_global_bin="$_litter_npm_prefix/bin"
      ;;
  esac
fi
if command -v pnpm >/dev/null 2>&1; then
  _litter_pnpm_global_bin="$(pnpm bin -g 2>/dev/null || true)"
fi
if command -v bun >/dev/null 2>&1; then
  _litter_bun_global_bin="$(bun pm bin -g 2>/dev/null || true)"
fi"#;

fn resolve_codex_binary_script_posix() -> String {
    // Candidate list is shared with the Rust-native local resolver in
    // `crate::local_server` so the two resolvers cannot drift.
    let shared_lines = crate::local_server::shell_candidate_lines().join("\n");
    format!(
        r#"{profile_init}
_litter_emit_candidate() {{
  _litter_selector="$1"
  _litter_path="$2"
  if [ -n "$_litter_path" ] && [ -f "$_litter_path" ] && [ -x "$_litter_path" ]; then
    printf '%s:%s' "$_litter_selector" "$_litter_path"
    exit 0
  fi
}}
_litter_emit_from_dir() {{
  _litter_selector="$1"
  _litter_name="$2"
  _litter_dir="$3"
  if [ -n "$_litter_dir" ]; then
    _litter_emit_candidate "$_litter_selector" "$_litter_dir/$_litter_name"
  fi
}}
{shared_lines}
{pkg_probe}
_litter_emit_from_dir codex codex "$_litter_bun_global_bin"
_litter_emit_from_dir codex codex "$_litter_npm_global_bin"
_litter_emit_from_dir codex codex "$_litter_pnpm_global_bin""#,
        profile_init = PROFILE_INIT,
        pkg_probe = PACKAGE_MANAGER_PROBE,
        shared_lines = shared_lines,
    )
}

fn resolve_codex_binary_script_powershell() -> String {
    r#"$litterBin = Join-Path $env:USERPROFILE '.litter\bin\codex.cmd'
if (Test-Path $litterBin) { Write-Output "codex:$litterBin"; exit 0 }
$litterNpm = Join-Path $env:USERPROFILE '.litter\codex\node_modules\.bin\codex.cmd'
if (Test-Path $litterNpm) { Write-Output "codex:$litterNpm"; exit 0 }
$found = Get-Command codex -ErrorAction SilentlyContinue
if ($found) { Write-Output "codex:$($found.Source)"; exit 0 }"#
        .to_string()
}

#[derive(Debug, Clone)]
pub(crate) enum RemoteCodexBinary {
    Codex(String),
}

impl RemoteCodexBinary {
    pub(crate) fn path(&self) -> &str {
        match self {
            Self::Codex(path) => path,
        }
    }
}

fn windows_start_process_spec(binary: &RemoteCodexBinary, listen_url: &str) -> (String, String) {
    let args = match binary {
        RemoteCodexBinary::Codex(_) => vec![
            ps_quote("app-server"),
            ps_quote("--listen"),
            ps_quote(listen_url),
        ],
    };

    if is_windows_cmd_script(binary.path()) {
        let command = match binary {
            RemoteCodexBinary::Codex(path) => {
                format!(
                    r#""{}" app-server --listen {}"#,
                    cmd_quote(path),
                    listen_url
                )
            }
        };
        (
            "$env:ComSpec".to_string(),
            format!("@('/d', '/c', {})", ps_quote(&format!(r#""{command}""#))),
        )
    } else {
        (ps_quote(binary.path()), format!("@({})", args.join(", ")))
    }
}

fn server_launch_command(
    binary: &RemoteCodexBinary,
    listen_url: &str,
    shell: RemoteShell,
) -> String {
    match shell {
        RemoteShell::Posix => match binary {
            RemoteCodexBinary::Codex(path) => format!(
                "{} app-server --listen {}",
                shell_quote(path),
                shell_quote(listen_url)
            ),
        },
        RemoteShell::PowerShell => match binary {
            RemoteCodexBinary::Codex(path) => format!(
                "{} app-server --listen {}",
                ps_quote(path),
                ps_quote(listen_url)
            ),
        },
    }
}

fn redact_ssh_command_for_log(command: &str) -> String {
    if command.contains("security unlock-keychain -p") {
        return "<redacted macOS keychain unlock command>".to_string();
    }
    log_preview(command)
}

fn log_preview(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return "<empty>".to_string();
    }
    const LIMIT: usize = 1200;
    let mut preview = String::new();
    for (index, ch) in trimmed.chars().enumerate() {
        if index == LIMIT {
            preview.push_str("...");
            return preview.replace('\n', "\\n");
        }
        preview.push(ch);
    }
    preview.replace('\n', "\\n")
}

fn format_process_logs(stdout: &str, stderr: &str) -> String {
    match (stdout.trim(), stderr.trim()) {
        ("", "") => String::new(),
        ("", stderr) => format!("stderr:\n{stderr}"),
        (stdout, "") => stdout.to_string(),
        (stdout, stderr) => format!("stdout:\n{stdout}\n\nstderr:\n{stderr}"),
    }
}

fn normalize_host(host: &str) -> String {
    let mut h = host.trim().trim_matches('[').trim_matches(']').to_string();
    h = h.replace("%25", "%");
    if !h.contains(':') {
        if let Some(idx) = h.find('%') {
            h.truncate(idx);
        }
    }
    h
}

pub(crate) fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\"'\"'"))
}

/// Process PowerShell CLIXML in SSH output.
///
/// PowerShell over SSH wraps error/progress streams in CLIXML format:
/// ```text
/// #< CLIXML
/// <Objs Version="1.1.0.1" xmlns="..."><S S="Error">'node' is not recognized…</S></Objs>
/// ```
///
/// Instead of discarding these lines, we extract the text content from
/// `<S>` tags so error messages are preserved.
fn strip_clixml(output: &str) -> String {
    let mut result_lines: Vec<&str> = Vec::new();
    let mut extracted: Vec<String> = Vec::new();

    for line in output.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("#< CLIXML") {
            continue;
        }
        if trimmed.starts_with("<Objs ") || trimmed.starts_with("<Objs>") {
            let text = extract_clixml_text(trimmed);
            if !text.is_empty() {
                extracted.push(text);
            }
            continue;
        }
        result_lines.push(line);
    }

    let mut out = result_lines.join("\n");
    if !extracted.is_empty() {
        let joined = extracted.join("\n");
        if out.is_empty() {
            out = joined;
        } else {
            out.push('\n');
            out.push_str(&joined);
        }
    }
    out
}

/// Extract human-readable text from a CLIXML `<Objs>` line.
///
/// Parses `<S S="...">text</S>` tags and decodes CLIXML escape sequences
/// like `_x000D__x000A_` (CRLF).
fn extract_clixml_text(clixml: &str) -> String {
    let mut texts = Vec::new();
    let mut remaining = clixml;
    while let Some(s_start) = remaining.find("<S ") {
        let after = &remaining[s_start..];
        // Find the end of the opening tag `>`
        let Some(tag_end) = after.find('>') else {
            break;
        };
        let content_start = &after[tag_end + 1..];
        // Find the closing `</S>`
        let Some(close) = content_start.find("</S>") else {
            break;
        };
        let raw = &content_start[..close];
        // Decode CLIXML entities
        let decoded = raw
            .replace("_x000D__x000A_", "\n")
            .replace("_x000A_", "\n")
            .replace("_x000D_", "")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
            .replace("&quot;", "\"")
            .replace("&apos;", "'");
        let trimmed = decoded.trim();
        if !trimmed.is_empty() {
            texts.push(trimmed.to_string());
        }
        remaining = &content_start[close + 4..];
    }
    texts.join("\n")
}

/// Quote a string for PowerShell (single-quoted, no variable expansion).
fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

fn cmd_quote(s: &str) -> String {
    s.replace('"', "\"\"")
}

fn is_windows_cmd_script(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".cmd") || lower.ends_with(".bat")
}

#[derive(Debug, Deserialize)]
struct GithubReleaseAsset {
    name: String,
    browser_download_url: String,
}

#[derive(Debug, Deserialize)]
struct GithubRelease {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<GithubReleaseAsset>,
}

fn platform_asset_name(platform: RemotePlatform) -> Option<&'static str> {
    match platform {
        RemotePlatform::MacosArm64 => Some("codex-aarch64-apple-darwin.tar.gz"),
        RemotePlatform::MacosX64 => Some("codex-x86_64-apple-darwin.tar.gz"),
        RemotePlatform::LinuxArm64 => Some("codex-aarch64-unknown-linux-musl.tar.gz"),
        RemotePlatform::LinuxX64 => Some("codex-x86_64-unknown-linux-musl.tar.gz"),
        // Windows uses npm install, not binary release assets.
        RemotePlatform::WindowsX64 | RemotePlatform::WindowsArm64 => None,
    }
}

fn platform_binary_name(platform: RemotePlatform) -> Option<&'static str> {
    match platform {
        RemotePlatform::MacosArm64 => Some("codex-aarch64-apple-darwin"),
        RemotePlatform::MacosX64 => Some("codex-x86_64-apple-darwin"),
        RemotePlatform::LinuxArm64 => Some("codex-aarch64-unknown-linux-musl"),
        RemotePlatform::LinuxX64 => Some("codex-x86_64-unknown-linux-musl"),
        RemotePlatform::WindowsX64 | RemotePlatform::WindowsArm64 => None,
    }
}

fn resolve_release_from_listing(
    releases: &[GithubRelease],
    platform: RemotePlatform,
) -> Result<ResolvedCodexRelease, SshError> {
    let asset_name = platform_asset_name(platform).ok_or_else(|| SshError::ExecFailed {
        exit_code: 1,
        stderr: "no binary release asset for this platform (use npm install)".to_string(),
    })?;
    let binary_name = platform_binary_name(platform).ok_or_else(|| SshError::ExecFailed {
        exit_code: 1,
        stderr: "no binary name for this platform (use npm install)".to_string(),
    })?;
    let release = releases
        .iter()
        .find(|release| !release.draft && !release.prerelease)
        .ok_or_else(|| SshError::ExecFailed {
            exit_code: 1,
            stderr: "no stable Codex release available".to_string(),
        })?;
    let asset = release
        .assets
        .iter()
        .find(|asset| asset.name == asset_name)
        .ok_or_else(|| SshError::ExecFailed {
            exit_code: 1,
            stderr: format!(
                "stable Codex release {} is missing asset {}",
                release.tag_name, asset_name
            ),
        })?;
    Ok(ResolvedCodexRelease {
        tag_name: release.tag_name.clone(),
        asset_name: asset.name.clone(),
        binary_name: binary_name.to_string(),
        download_url: asset.browser_download_url.clone(),
    })
}

pub(crate) fn build_posix_exec_command(command: &str) -> String {
    format!("/bin/sh -c {}", shell_quote(command))
}

async fn fetch_latest_stable_codex_release(
    platform: RemotePlatform,
) -> Result<ResolvedCodexRelease, SshError> {
    let releases = reqwest::Client::new()
        .get("https://api.github.com/repos/openai/codex/releases?per_page=30")
        .header(reqwest::header::USER_AGENT, "litter-codex-mobile")
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await
        .map_err(|error| SshError::ExecFailed {
            exit_code: 1,
            stderr: format!("failed to query Codex releases: {error}"),
        })?
        .error_for_status()
        .map_err(|error| SshError::ExecFailed {
            exit_code: 1,
            stderr: format!("Codex releases API returned error: {error}"),
        })?
        .json::<Vec<GithubRelease>>()
        .await
        .map_err(|error| SshError::ExecFailed {
            exit_code: 1,
            stderr: format!("failed to parse Codex releases response: {error}"),
        })?;
    resolve_release_from_listing(&releases, platform)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_host_simple() {
        assert_eq!(normalize_host("example.com"), "example.com");
    }

    #[test]
    fn test_normalize_host_trimming() {
        assert_eq!(normalize_host("  example.com  "), "example.com");
    }

    #[test]
    fn test_normalize_host_ipv6_brackets() {
        assert_eq!(normalize_host("[::1]"), "::1");
    }

    #[test]
    fn test_normalize_host_percent_encoding() {
        assert_eq!(normalize_host("fe80::1%25eth0"), "fe80::1%eth0");
    }

    #[test]
    fn test_normalize_host_zone_id_removal() {
        // Non-IPv6 host with a zone id should have it stripped.
        assert_eq!(normalize_host("192.168.1.1%eth0"), "192.168.1.1");
    }

    #[test]
    fn test_shell_quote_simple() {
        assert_eq!(shell_quote("hello"), "'hello'");
    }

    #[test]
    fn test_server_launch_command_for_codex() {
        let command = server_launch_command(
            &RemoteCodexBinary::Codex("/usr/local/bin/codex".into()),
            "ws://127.0.0.1:8390",
            RemoteShell::Posix,
        );
        assert_eq!(
            command,
            "'/usr/local/bin/codex' app-server --listen 'ws://127.0.0.1:8390'"
        );
    }

    #[test]
    fn test_windows_start_process_spec_for_cmd_shim() {
        let (file_path, argument_list) = windows_start_process_spec(
            &RemoteCodexBinary::Codex(r#"C:\Users\me\AppData\Roaming\npm\codex.cmd"#.into()),
            "ws://127.0.0.1:8390",
        );
        assert_eq!(file_path, "$env:ComSpec");
        assert_eq!(
            argument_list,
            r#"@('/d', '/c', '""C:\Users\me\AppData\Roaming\npm\codex.cmd" app-server --listen ws://127.0.0.1:8390"')"#
        );
    }

    #[test]
    fn test_windows_start_process_spec_for_exe() {
        let (file_path, argument_list) = windows_start_process_spec(
            &RemoteCodexBinary::Codex(r#"C:\Program Files\Codex\codex.exe"#.into()),
            "ws://127.0.0.1:8390",
        );
        assert_eq!(file_path, r#"'C:\Program Files\Codex\codex.exe'"#);
        assert_eq!(
            argument_list,
            "@('app-server', '--listen', 'ws://127.0.0.1:8390')"
        );
    }

    #[test]
    fn test_format_process_logs_includes_stderr() {
        assert_eq!(
            format_process_logs("stdout line", "stderr line"),
            "stdout:\nstdout line\n\nstderr:\nstderr line"
        );
        assert_eq!(
            format_process_logs("", "stderr line"),
            "stderr:\nstderr line"
        );
    }

    #[test]
    fn test_shell_quote_with_single_quote() {
        assert_eq!(shell_quote("it's"), "'it'\"'\"'s'");
    }

    #[test]
    fn test_shell_quote_path() {
        assert_eq!(
            shell_quote("/home/user/my file.txt"),
            "'/home/user/my file.txt'"
        );
    }

    #[test]
    fn test_build_posix_exec_command_uses_non_login_sh() {
        assert_eq!(
            build_posix_exec_command("echo 'hi' && printf '%s' \"$HOME\""),
            "/bin/sh -c 'echo '\"'\"'hi'\"'\"' && printf '\"'\"'%s'\"'\"' \"$HOME\"'"
        );
    }

    #[test]
    fn test_exec_result_default() {
        let r = ExecResult {
            exit_code: 0,
            stdout: "hello\n".into(),
            stderr: String::new(),
        };
        assert_eq!(r.exit_code, 0);
        assert_eq!(r.stdout.trim(), "hello");
    }

    #[test]
    fn test_ssh_error_display() {
        let e = SshError::ConnectionFailed("refused".into());
        assert_eq!(e.to_string(), "connection failed: refused");

        let e = SshError::HostKeyVerification {
            fingerprint: "SHA256:abc".into(),
        };
        assert!(e.to_string().contains("SHA256:abc"));

        let e = SshError::ExecFailed {
            exit_code: 127,
            stderr: "not found".into(),
        };
        assert!(e.to_string().contains("127"));
        assert!(e.to_string().contains("not found"));

        assert_eq!(SshError::Timeout.to_string(), "timeout");
        assert_eq!(SshError::Disconnected.to_string(), "disconnected");
    }

    #[test]
    fn test_ssh_credentials_construction() {
        let creds = SshCredentials {
            host: "example.com".into(),
            port: 22,
            username: "user".into(),
            auth: SshAuth::Password("pass".into()),
            unlock_macos_keychain: false,
        };
        assert_eq!(creds.port, 22);
        assert_eq!(creds.username, "user");

        let creds_key = SshCredentials {
            host: "example.com".into(),
            port: 2222,
            username: "deploy".into(),
            auth: SshAuth::PrivateKey {
                key_pem:
                    "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
                        .into(),
                passphrase: None,
            },
            unlock_macos_keychain: false,
        };
        assert_eq!(creds_key.port, 2222);
    }

    #[test]
    fn test_bootstrap_result_clone() {
        let r = SshBootstrapResult {
            server_port: 8390,
            tunnel_local_port: 12345,
            server_version: Some("1.0.0".into()),
            pid: Some(42),
        };
        let r2 = r.clone();
        assert_eq!(r2.server_port, 8390);
        assert_eq!(r2.tunnel_local_port, 12345);
        assert_eq!(r2.server_version.as_deref(), Some("1.0.0"));
        assert_eq!(r2.pid, Some(42));
    }

    #[test]
    fn test_profile_init_sources_common_files() {
        // Verify the profile init string references the expected shell config files.
        assert!(PROFILE_INIT.contains(".profile"));
        assert!(PROFILE_INIT.contains(".bash_profile"));
        assert!(PROFILE_INIT.contains(".bashrc"));
        assert!(PROFILE_INIT.contains(".zshenv"));
        assert!(PROFILE_INIT.contains(".zprofile"));
        assert!(PROFILE_INIT.contains(".zshrc"));
        assert!(PROFILE_INIT.contains("\"$SHELL\" -lc"));
        assert!(!PROFILE_INIT.contains("-ic 'printf %s \"$PATH\"'"));
    }

    #[test]
    fn test_profile_init_adds_common_node_paths() {
        assert!(PROFILE_INIT.contains("_litter_add_path"));
        assert!(PROFILE_INIT.contains("$NVM_BIN"));
        assert!(PROFILE_INIT.contains("${NVM_DIR:-$HOME/.nvm}"));
        assert!(PROFILE_INIT.contains("/versions/node/*/bin"));
        assert!(PROFILE_INIT.contains("$ASDF_DATA_DIR/shims"));
        assert!(PROFILE_INIT.contains("$HOME/.asdf/shims"));
        assert!(PROFILE_INIT.contains("${BUN_INSTALL:-$HOME/.bun}/bin"));
        assert!(PROFILE_INIT.contains("$HOME/.volta/bin"));
        assert!(PROFILE_INIT.contains("$HOME/.local/bin"));
        assert!(PROFILE_INIT.contains("${CARGO_HOME:-$HOME/.cargo}/bin"));
        assert!(PROFILE_INIT.contains("/opt/homebrew/opt/node/bin"));
        assert!(PROFILE_INIT.contains("/opt/homebrew/bin"));
        assert!(PROFILE_INIT.contains("/usr/local/opt/node/bin"));
        assert!(PROFILE_INIT.contains("/usr/local/bin"));
        assert!(PROFILE_INIT.contains("export PATH"));
    }

    #[test]
    fn test_posix_launch_runs_after_profile_init() {
        let command = format!(
            "{profile_init} nohup {launch} </dev/null >/tmp/codex.log 2>&1 & echo $!",
            profile_init = PROFILE_INIT,
            launch = server_launch_command(
                &RemoteCodexBinary::Codex("/opt/homebrew/bin/codex".into()),
                "ws://127.0.0.1:8390",
                RemoteShell::Posix,
            )
        );

        assert!(command.starts_with(PROFILE_INIT));
        assert!(command.contains("/opt/homebrew/bin"));
        assert!(command.contains("nohup '/opt/homebrew/bin/codex' app-server"));
    }

    #[test]
    fn test_posix_resolver_probes_package_manager_bins() {
        let script = resolve_codex_binary_script_posix();
        assert!(script.contains("npm config get prefix"));
        assert!(script.contains("pnpm bin -g"));
        assert!(script.contains("bun pm bin -g"));
        assert!(script.contains("${BUN_INSTALL:-$HOME/.bun}/bin/codex"));
        assert!(script.contains("PNPM_HOME"));
        assert!(script.contains("NVM_BIN"));
        assert!(script.contains("$HOME/.volta/bin/codex"));
        assert!(script.contains("$HOME/.local/bin/codex"));
        assert!(script.contains("/opt/homebrew/bin/codex"));
        assert!(script.contains("/usr/local/bin/codex"));
        assert!(script.find("command -v codex 2>/dev/null || true") < script.find("pnpm bin -g"));
        assert!(!script.contains("codex-app-server"));
    }

    #[test]
    fn test_default_remote_port() {
        assert_eq!(DEFAULT_REMOTE_PORT, 8390);
    }

    #[test]
    fn test_port_candidates_range() {
        let ports: Vec<u16> = (0..PORT_CANDIDATES)
            .map(|i| DEFAULT_REMOTE_PORT + i)
            .collect();
        assert_eq!(ports.len(), 21);
        assert_eq!(*ports.first().unwrap(), 8390);
        assert_eq!(*ports.last().unwrap(), 8410);
    }
}
