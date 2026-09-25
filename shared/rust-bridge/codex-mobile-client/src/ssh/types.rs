//! Public and crate-visible types for the SSH bootstrap flow. Kept apart
//! from the giant `SshClient` impl so reading `mod.rs` doesn't require
//! scrolling past every record/enum first.

use std::io;
#[cfg(unix)]
use std::os::unix::process::ExitStatusExt;
use std::pin::Pin;
use std::process::ExitStatus;
use std::sync::Arc;
use std::task::{Context, Poll};

use russh::ChannelWriteHalf;
use russh::Sig;
use russh::client::Msg;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{Mutex, watch};

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
    /// Legacy TCP app-server port. Socket/proxy based bootstraps use 0.
    pub server_port: u16,
    /// Legacy local tunnel port. Socket/proxy based bootstraps use 0.
    pub tunnel_local_port: u16,
    pub server_version: Option<String>,
    pub pid: Option<u32>,
    pub(crate) codex_path: String,
    pub(crate) shell: RemoteShell,
    pub(crate) transport: SshBootstrapTransport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SshBootstrapTransport {
    AppServerProxy,
    WebSocketTunnel,
}

/// The remote host's shell type, detected after SSH connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) enum RemoteShell {
    Posix,
    PowerShell,
}

impl RemoteShell {
    /// Short name used in log lines (`"posix"` / `"powershell"`).
    pub(crate) fn name(self) -> &'static str {
        match self {
            RemoteShell::Posix => "posix",
            RemoteShell::PowerShell => "powershell",
        }
    }

    /// `/dev/null` on POSIX, `NUL` on PowerShell.
    pub(crate) fn null_device(self) -> &'static str {
        match self {
            RemoteShell::Posix => "/dev/null",
            RemoteShell::PowerShell => "NUL",
        }
    }

    /// Template for "is anything listening on TCP {{PORT}}".
    pub(crate) fn port_listening_template(self) -> &'static str {
        match self {
            RemoteShell::Posix => crate::ssh_scripts::posix::PORT_LISTENING,
            RemoteShell::PowerShell => crate::ssh_scripts::powershell::PORT_LISTENING,
        }
    }

    /// Template for "kill any listener on TCP {{PORT}}".
    pub(crate) fn kill_port_listener_template(self) -> &'static str {
        match self {
            RemoteShell::Posix => crate::ssh_scripts::posix::KILL_PORT_LISTENER,
            RemoteShell::PowerShell => crate::ssh_scripts::powershell::KILL_PORT_LISTENER,
        }
    }
}

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

/// Bidirectional stream backed by a remote exec child's stdout/stdin.
pub struct SshExecIo {
    stdout: SshExecStdout,
    stdin: SshExecStdin,
}

impl SshExecIo {
    pub(crate) fn new(stdout: SshExecStdout, stdin: SshExecStdin) -> Self {
        Self { stdout, stdin }
    }
}

impl AsyncRead for SshExecIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdout).poll_read(cx, buf)
    }
}

impl AsyncWrite for SshExecIo {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stdin).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdin).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdin).poll_shutdown(cx)
    }
}

/// Streaming SSH exec child.
///
/// stdout/stderr are demultiplexed from russh channel messages into normal
/// async readers so bridge launchers can treat a remote process like a local
/// `tokio::process::Child`.
pub struct SshExecChild {
    pub(super) stdin: Option<SshExecStdin>,
    pub(super) stdout: Option<SshExecStdout>,
    pub(super) stderr: Option<SshExecStderr>,
    pub(super) exit_rx: watch::Receiver<Option<u32>>,
    pub(super) write_half: Arc<Mutex<Option<ChannelWriteHalf<Msg>>>>,
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

    pub async fn close_stdin(&mut self) -> io::Result<()> {
        self.stdin.take();
        let write_half = self.write_half.lock().await;
        let Some(write_half) = write_half.as_ref() else {
            return Ok(());
        };
        write_half
            .eof()
            .await
            .map_err(|error| io::Error::new(io::ErrorKind::BrokenPipe, error.to_string()))
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
pub(crate) fn exit_status_from_code(code: u32) -> io::Result<ExitStatus> {
    Ok(ExitStatus::from_raw((code as i32) << 8))
}

#[cfg(not(unix))]
pub(crate) fn exit_status_from_code(_code: u32) -> io::Result<ExitStatus> {
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
