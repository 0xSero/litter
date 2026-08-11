//! Run a remote command and collect (or stream) its output.
//!
//! - [`SshClient::exec`] — buffered, with `EXEC_TIMEOUT`.
//! - [`SshClient::open_exec_child`] — streaming; returns an
//!   [`SshExecChild`] for caller-managed I/O.
//! - [`SshClient::exec_shell`] — picks the right shell wrapper. POSIX runs
//!   the command through `/usr/bin/env sh -c '…'`; PowerShell uses
//!   `-EncodedCommand` (UTF-16LE base64) to avoid every cmd.exe escaping
//!   pothole, then strips CLIXML noise from the response.
//! - [`SshClient::upload`] — write a file to the remote via `cat > path`,
//!   no SFTP dependency.

use std::sync::Arc;

use base64::Engine;
use russh::ChannelMsg;
use tokio::io::AsyncWriteExt;
use tokio::sync::{Mutex, watch};
use tracing::{trace, warn};

use crate::shell_quoting::posix_quote as shell_quote;

use super::{
    EXEC_TIMEOUT, ExecResult, RemoteShell, SshClient, SshError, SshExecChild, SshExecStderr,
    SshExecStdin, SshExecStdout, remote_shell_name, strip_clixml,
};

pub(crate) fn build_posix_exec_command(command: &str) -> String {
    format!("/usr/bin/env sh -c {}", shell_quote(command))
}

impl SshClient {
    /// Run a command on the remote host and collect its stdout/stderr.
    pub async fn exec(&self, command: &str) -> Result<ExecResult, SshError> {
        tokio::time::timeout(EXEC_TIMEOUT, self.exec_inner(command))
            .await
            .map_err(|_| SshError::Timeout)?
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

    /// Write `content` to a remote file at `remote_path` via `cat`. Avoids
    /// an SFTP dependency by piping stdin into a shell command.
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
            .data(content)
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

    pub(crate) async fn exec_posix(&self, command: &str) -> Result<ExecResult, SshError> {
        self.exec(&build_posix_exec_command(command)).await
    }
}
