use std::io;
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use alleycat_bridge_core::{
    ChildProcess, ChildStderr, ChildStdin, ChildStdout, ProcessLauncher, ProcessRole, ProcessSpec,
};
use futures::future::BoxFuture;

use crate::ssh::{RemoteShell, SshClient, SshExecChild, build_posix_exec_command, shell_quote};
use crate::ssh_launcher::{SshLauncher, build_remote_command};

static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
pub(crate) struct SshDetachedLauncher {
    ssh: Arc<SshClient>,
    shell: RemoteShell,
    ephemeral: SshLauncher,
}

impl SshDetachedLauncher {
    pub(crate) fn new(ssh: Arc<SshClient>, shell: RemoteShell) -> Self {
        Self {
            ephemeral: SshLauncher::new(Arc::clone(&ssh), shell),
            ssh,
            shell,
        }
    }
}

impl ProcessLauncher for SshDetachedLauncher {
    fn launch(&self, spec: ProcessSpec) -> BoxFuture<'_, io::Result<Box<dyn ChildProcess>>> {
        Box::pin(async move {
            if spec.role == ProcessRole::ToolCommand {
                return self.ephemeral.launch(spec).await;
            }
            let command = build_remote_command(&spec, self.shell)?;
            let session_id = next_session_id();
            let dirs = RemoteDetachedDirs::new(session_id);
            let agent_pid = spawn_detached_agent(&self.ssh, self.shell, &dirs, &command).await?;

            let mut stdin_child = self
                .ssh
                .open_exec_child_with_stdio(
                    &build_posix_exec_command(&format!("cat > {}", quote_remote_path(&dirs.input))),
                    true,
                    false,
                    false,
                )
                .await
                .map_err(io_from_ssh)?;
            let stdin = stdin_child.take_stdin();

            let mut stdout_child = self
                .ssh
                .open_exec_child_with_stdio(
                    &build_posix_exec_command(&tail_log_command(&dirs.out_log, &dirs.agent_pid)),
                    false,
                    true,
                    false,
                )
                .await
                .map_err(io_from_ssh)?;
            let stdout = stdout_child.take_stdout();

            let mut stderr_child = self
                .ssh
                .open_exec_child_with_stdio(
                    &build_posix_exec_command(&tail_log_command(&dirs.err_log, &dirs.agent_pid)),
                    false,
                    true,
                    false,
                )
                .await
                .map_err(io_from_ssh)?;
            let stderr = stderr_child.take_stdout();

            Ok(Box::new(SshDetachedChild {
                ssh: Arc::clone(&self.ssh),
                shell: self.shell,
                dirs,
                agent_pid,
                stdin,
                stdout,
                stderr,
                stdin_child,
                stdout_child,
                stderr_child,
            }) as Box<dyn ChildProcess>)
        })
    }
}

#[derive(Clone)]
struct RemoteDetachedDirs {
    root: String,
    input: String,
    out_log: String,
    err_log: String,
    keeper_pid: String,
    agent_pid: String,
}

impl RemoteDetachedDirs {
    fn new(session_id: String) -> Self {
        let root = format!("$HOME/.litter/sessions/{session_id}");
        Self {
            input: format!("{root}/in"),
            out_log: format!("{root}/out.log"),
            err_log: format!("{root}/err.log"),
            keeper_pid: format!("{root}/keeper.pid"),
            agent_pid: format!("{root}/agent.pid"),
            root,
        }
    }
}

struct SshDetachedChild {
    ssh: Arc<SshClient>,
    shell: RemoteShell,
    dirs: RemoteDetachedDirs,
    agent_pid: u32,
    stdin: Option<ChildStdin>,
    stdout: Option<ChildStdout>,
    stderr: Option<ChildStderr>,
    stdin_child: SshExecChild,
    stdout_child: SshExecChild,
    stderr_child: SshExecChild,
}

// Child handles are consumed only through `&mut self`. The bridge-core trait
// requires `Sync` because child processes are stored behind shared trait
// objects.
unsafe impl Sync for SshDetachedChild {}

impl ChildProcess for SshDetachedChild {
    fn take_stdin(&mut self) -> Option<ChildStdin> {
        self.stdin.take()
    }

    fn take_stdout(&mut self) -> Option<ChildStdout> {
        self.stdout.take()
    }

    fn take_stderr(&mut self) -> Option<ChildStderr> {
        self.stderr.take()
    }

    fn id(&self) -> Option<u32> {
        Some(self.agent_pid)
    }

    fn wait(&mut self) -> BoxFuture<'_, io::Result<ExitStatus>> {
        Box::pin(async move {
            loop {
                if !is_remote_process_alive(&self.ssh, self.shell, self.agent_pid).await? {
                    return exit_status_from_code(0);
                }
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            }
        })
    }

    fn kill(&mut self) -> BoxFuture<'_, io::Result<()>> {
        Box::pin(async move {
            let _ = self.stdin_child.kill().await;
            let _ = self.stdout_child.kill().await;
            let _ = self.stderr_child.kill().await;
            kill_detached_agent(&self.ssh, self.shell, &self.dirs).await
        })
    }
}

async fn spawn_detached_agent(
    ssh: &SshClient,
    shell: RemoteShell,
    dirs: &RemoteDetachedDirs,
    command: &str,
) -> io::Result<u32> {
    if shell == RemoteShell::PowerShell {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "detached SSH bridge launch is not implemented for PowerShell remotes",
        ));
    }
    let script = crate::ssh_scripts::render(
        crate::ssh_scripts::posix::DETACHED_SPAWN,
        &[
            ("ROOT", &quote_remote_path(&dirs.root)),
            ("INPUT", &quote_remote_path(&dirs.input)),
            ("OUT_LOG", &quote_remote_path(&dirs.out_log)),
            ("ERR_LOG", &quote_remote_path(&dirs.err_log)),
            ("KEEPER_PID", &quote_remote_path(&dirs.keeper_pid)),
            ("AGENT_PID", &quote_remote_path(&dirs.agent_pid)),
            ("COMMAND", &shell_quote(command)),
        ],
    );
    let result = ssh.exec_shell(&script, shell).await.map_err(io_from_ssh)?;
    if result.exit_code != 0 {
        return Err(io::Error::other(
            format!("detached launch failed: {}", result.stderr),
        ));
    }
    result
        .stdout
        .trim()
        .parse::<u32>()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))
}

fn tail_log_command(log_path: &str, pid_path: &str) -> String {
    format!(
        r#"log={log}; pid_file={pid_file}; while [ ! -f "$log" ]; do sleep 0.05; done; pid="$(cat "$pid_file" 2>/dev/null || true)"; tail -f -c +1 "$log" & tail_pid=$!; while [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; do sleep 0.5; done; sleep 0.2; kill "$tail_pid" >/dev/null 2>&1 || true; wait "$tail_pid" 2>/dev/null || true"#,
        log = quote_remote_path(log_path),
        pid_file = quote_remote_path(pid_path),
    )
}

async fn kill_detached_agent(
    ssh: &SshClient,
    shell: RemoteShell,
    dirs: &RemoteDetachedDirs,
) -> io::Result<()> {
    let script = crate::ssh_scripts::render(
        crate::ssh_scripts::posix::DETACHED_KILL,
        &[
            ("AGENT_PID", &quote_remote_path(&dirs.agent_pid)),
            ("KEEPER_PID", &quote_remote_path(&dirs.keeper_pid)),
            ("ROOT", &quote_remote_path(&dirs.root)),
        ],
    );
    ssh.exec_shell(&script, shell)
        .await
        .map(|_| ())
        .map_err(io_from_ssh)
}

async fn is_remote_process_alive(
    ssh: &SshClient,
    shell: RemoteShell,
    pid: u32,
) -> io::Result<bool> {
    let script = format!("kill -0 {pid} >/dev/null 2>&1 && echo alive || echo dead");
    let result = ssh.exec_shell(&script, shell).await.map_err(io_from_ssh)?;
    Ok(result.stdout.trim() == "alive")
}

fn next_session_id() -> String {
    let seq = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("agent-{now}-{seq}")
}

/// Quote a remote path for use in a POSIX shell. Paths that start with
/// `$HOME/` (everything emitted by `RemoteDetachedDirs::new`) are wrapped
/// in double quotes so `$HOME` expands at runtime; other paths are passed
/// through `shell_quote` and stay literal.
fn quote_remote_path(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("$HOME/") {
        format!("\"$HOME/{}\"", rest.replace('"', "\\\""))
    } else {
        shell_quote(path)
    }
}

fn io_from_ssh(error: crate::ssh::SshError) -> io::Error {
    io::Error::new(io::ErrorKind::ConnectionAborted, error)
}

#[cfg(unix)]
fn exit_status_from_code(code: u32) -> io::Result<ExitStatus> {
    use std::os::unix::process::ExitStatusExt;
    Ok(ExitStatus::from_raw((code as i32) << 8))
}

#[cfg(not(unix))]
fn exit_status_from_code(_code: u32) -> io::Result<ExitStatus> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "ssh detached exit status conversion is only implemented on unix targets",
    ))
}
