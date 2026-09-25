//! Detect the remote shell (POSIX vs. PowerShell).
//!
//! Shell detection is heuristic: `echo %OS%` returns `Windows_NT` only on
//! cmd.exe, while POSIX shells return the literal `%OS%`. A second probe
//! (`echo $env:OS`) covers OpenSSH-on-Windows configs whose default shell
//! is already PowerShell.

use tracing::info;

use super::{RemoteShell, SshClient, append_bridge_info_log};

impl SshClient {
    /// Remote shell, memoized per connection (and seedable from the
    /// persisted reconnect cache). Concurrent callers share one probe.
    pub(crate) async fn detect_remote_shell(&self) -> RemoteShell {
        if let Some(shell) = self.with_detection(|d| d.shell) {
            return shell;
        }
        let _guard = self.shell_probe.lock().await;
        if let Some(shell) = self.with_detection(|d| d.shell) {
            return shell;
        }
        let shell = self.detect_remote_shell_uncached().await;
        self.with_detection(|d| d.shell = Some(shell));
        shell
    }

    /// Run both shell probes concurrently (they are independent) instead of
    /// two serial round trips.
    pub(crate) async fn detect_remote_shell_uncached(&self) -> RemoteShell {
        let (cmd_probe, ps_probe) =
            tokio::join!(self.exec("echo %OS%"), self.exec("echo $env:OS"));
        if let Ok(result) = cmd_probe {
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
        if let Ok(result) = ps_probe {
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
}
