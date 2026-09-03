//! Cheap remote probes that bootstrap uses to decide what to do next:
//! "is this port already taken?", "did the spawned process die?", "what's
//! the tail of its log?".

use crate::shell_quoting::posix_quote as shell_quote;

use super::{ExecResult, RemoteShell, SshClient, SshError};

pub(crate) fn format_process_logs(stdout: &str, stderr: &str) -> String {
    match (stdout.trim(), stderr.trim()) {
        ("", "") => String::new(),
        ("", stderr) => format!("stderr:\n{stderr}"),
        (stdout, "") => stdout.to_string(),
        (stdout, stderr) => format!("stdout:\n{stdout}\n\nstderr:\n{stderr}"),
    }
}

impl SshClient {
    pub(crate) async fn is_port_listening_shell(&self, port: u16, shell: RemoteShell) -> bool {
        let port_str = port.to_string();
        let cmd =
            crate::ssh_scripts::render(shell.port_listening_template(), &[("PORT", &port_str)]);

        match self.exec_shell(&cmd, shell).await {
            Ok(r) => !r.stdout.trim().is_empty(),
            Err(_) => false,
        }
    }

    pub(super) async fn is_process_alive_shell(&self, pid: u32, shell: RemoteShell) -> bool {
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
        let port_str = port.to_string();
        let cmd =
            crate::ssh_scripts::render(shell.kill_port_listener_template(), &[("PORT", &port_str)]);

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

    pub(super) async fn fetch_process_log_tail_shell(
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
}
