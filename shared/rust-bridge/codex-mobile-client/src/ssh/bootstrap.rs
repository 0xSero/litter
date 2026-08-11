//! Bootstrap a remote `codex app-server` and connect Litter to it.
//!
//! The flow:
//!   1. Resolve a user-installed `codex` binary on the remote.
//!   2. On POSIX remotes with `codex app-server proxy`, prefer the upstream
//!      Unix-socket app-server transport: start the upstream app-server daemon
//!      when available, probe an existing socket, otherwise launch
//!      `codex app-server --listen unix://`, then connect each client via
//!      `codex app-server proxy`.
//!   3. Fallback: try `PORT_CANDIDATES` consecutive remote ports starting at
//!      `DEFAULT_REMOTE_PORT`. If a port is already listening and answers a
//!      websocket probe, reuse it. Otherwise launch a new server.
//!   4. Wait `LISTEN_POLL_ATTEMPTS × LISTEN_POLL_INTERVAL` for the new
//!      server to start listening; if it dies first, scrape its logs for
//!      "address already in use" (skip to next port) or surface the error.
//!   5. Forward a local TCP port to the remote port and wait for the
//!      websocket to accept connections via the tunnel.
//!   6. Read back the server version and return all of it.

use tracing::{info, trace, warn};

use crate::shell_quoting::{cmd_quote, posix_quote as shell_quote, powershell_quote as ps_quote};

use super::{
    DEFAULT_REMOTE_PORT, LISTEN_POLL_ATTEMPTS, LISTEN_POLL_INTERVAL, PORT_CANDIDATES, PROFILE_INIT,
    RemoteCodexBinary, RemoteShell, SYNC_DIAG_TIMEOUT, SshBootstrapResult, SshBootstrapTransport,
    SshClient, SshError, TUNNEL_HEALTH_ATTEMPTS, TUNNEL_HEALTH_INTERVAL, append_bridge_info_log,
    remote_shell_name, server_launch_command, windows_start_process_spec,
};

const APP_SERVER_PROXY_WEBSOCKET_URL: &str = "ws://codex-app-server-proxy.localhost/rpc";

impl SshClient {
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
        if shell == RemoteShell::Posix {
            match self
                .bootstrap_codex_app_server_proxy_with_binary_and_shell(
                    codex_binary,
                    working_dir,
                    shell,
                )
                .await
            {
                Ok(result) => return Ok(result),
                Err(error) => {
                    warn!(
                        "ssh app-server proxy bootstrap unavailable; falling back to websocket tunnel: {}",
                        error
                    );
                    append_bridge_info_log(&format!(
                        "ssh_app_server_proxy_bootstrap_fallback error={}",
                        error
                    ));
                }
            }
        }

        self.bootstrap_codex_websocket_server_with_binary_and_shell(
            codex_binary,
            working_dir,
            prefer_ipv6,
            shell,
        )
        .await
    }

    pub(crate) async fn bootstrap_codex_app_server_proxy_with_binary_and_shell(
        &self,
        codex_binary: &RemoteCodexBinary,
        working_dir: Option<&str>,
        shell: RemoteShell,
    ) -> Result<SshBootstrapResult, SshError> {
        if shell != RemoteShell::Posix {
            return Err(SshError::ExecFailed {
                exit_code: 1,
                stderr: "app-server proxy bootstrap requires a POSIX remote shell".to_string(),
            });
        }

        if !self.app_server_proxy_supported(codex_binary, shell).await? {
            return Err(SshError::ExecFailed {
                exit_code: 1,
                stderr: "`codex app-server proxy` is not supported by the remote Codex CLI"
                    .to_string(),
            });
        }

        if self
            .app_server_daemon_supported(codex_binary, shell)
            .await?
        {
            match self
                .start_codex_app_server_daemon(codex_binary, shell)
                .await
            {
                Ok(()) => {
                    self.probe_app_server_proxy(codex_binary, shell)
                        .await
                        .map_err(|stderr| SshError::ExecFailed {
                            exit_code: 1,
                            stderr,
                        })?;
                    let version = self
                        .read_server_version_shell(codex_binary.path(), shell)
                        .await;
                    info!(
                        "ssh app-server proxy bootstrap started upstream daemon binary={} version={}",
                        codex_binary.path(),
                        version.clone().unwrap_or_else(|| "<unknown>".to_string())
                    );
                    append_bridge_info_log(&format!(
                        "ssh_app_server_daemon_start_success version={}",
                        version.clone().unwrap_or_else(|| "<unknown>".to_string())
                    ));
                    return Ok(SshBootstrapResult {
                        server_port: 0,
                        tunnel_local_port: 0,
                        server_version: version,
                        pid: None,
                        codex_path: codex_binary.path().to_string(),
                        shell,
                        transport: SshBootstrapTransport::AppServerProxy,
                    });
                }
                Err(error) => {
                    warn!(
                        "ssh app-server daemon start failed; falling back to legacy unix app-server launch: {}",
                        error
                    );
                    append_bridge_info_log(&format!(
                        "ssh_app_server_daemon_start_fallback error={}",
                        error
                    ));
                }
            }
        }

        if self
            .probe_app_server_proxy(codex_binary, shell)
            .await
            .is_ok()
        {
            let version = self
                .read_server_version_shell(codex_binary.path(), shell)
                .await;
            info!(
                "ssh app-server proxy bootstrap reused existing socket binary={} version={}",
                codex_binary.path(),
                version.clone().unwrap_or_else(|| "<unknown>".to_string())
            );
            append_bridge_info_log(&format!(
                "ssh_app_server_proxy_reuse_success version={}",
                version.clone().unwrap_or_else(|| "<unknown>".to_string())
            ));
            return Ok(SshBootstrapResult {
                server_port: 0,
                tunnel_local_port: 0,
                server_version: version,
                pid: None,
                codex_path: codex_binary.path().to_string(),
                shell,
                transport: SshBootstrapTransport::AppServerProxy,
            });
        }

        self.log_macos_keychain_unlock_for_bootstrap(shell).await?;
        let (pid, log_path) = self
            .launch_codex_app_server_unix(codex_binary, working_dir, shell)
            .await?;
        self.wait_for_app_server_proxy_ready(codex_binary, shell, pid, &log_path)
            .await
            .map_err(|stderr| SshError::ExecFailed {
                exit_code: 1,
                stderr,
            })?;

        let version = self
            .read_server_version_shell(codex_binary.path(), shell)
            .await;
        info!(
            "ssh app-server proxy bootstrap launched unix app-server pid={:?} version={}",
            pid,
            version.clone().unwrap_or_else(|| "<unknown>".to_string())
        );
        append_bridge_info_log(&format!(
            "ssh_app_server_proxy_bootstrap_success pid={:?} version={}",
            pid,
            version.clone().unwrap_or_else(|| "<unknown>".to_string())
        ));
        Ok(SshBootstrapResult {
            server_port: 0,
            tunnel_local_port: 0,
            server_version: version,
            pid,
            codex_path: codex_binary.path().to_string(),
            shell,
            transport: SshBootstrapTransport::AppServerProxy,
        })
    }

    async fn app_server_proxy_supported(
        &self,
        codex_binary: &RemoteCodexBinary,
        shell: RemoteShell,
    ) -> Result<bool, SshError> {
        let command = match shell {
            RemoteShell::Posix => format!(
                "{profile_init}\n{bin} app-server proxy --help >/dev/null 2>&1",
                profile_init = PROFILE_INIT,
                bin = shell_quote(codex_binary.path()),
            ),
            RemoteShell::PowerShell => format!(
                "& {} app-server proxy --help *> $null",
                ps_quote(codex_binary.path())
            ),
        };
        let result = self.exec_shell(&command, shell).await?;
        Ok(result.exit_code == 0)
    }

    async fn app_server_daemon_supported(
        &self,
        codex_binary: &RemoteCodexBinary,
        shell: RemoteShell,
    ) -> Result<bool, SshError> {
        let command = match shell {
            RemoteShell::Posix => format!(
                "{profile_init}\n{bin} app-server daemon --help >/dev/null 2>&1",
                profile_init = PROFILE_INIT,
                bin = shell_quote(codex_binary.path()),
            ),
            RemoteShell::PowerShell => format!(
                "& {} app-server daemon --help *> $null",
                ps_quote(codex_binary.path())
            ),
        };
        let result = self.exec_shell(&command, shell).await?;
        Ok(result.exit_code == 0)
    }

    async fn start_codex_app_server_daemon(
        &self,
        codex_binary: &RemoteCodexBinary,
        shell: RemoteShell,
    ) -> Result<(), SshError> {
        let command = match shell {
            RemoteShell::Posix => format!(
                "{profile_init}\n{bin} app-server daemon start",
                profile_init = PROFILE_INIT,
                bin = shell_quote(codex_binary.path()),
            ),
            RemoteShell::PowerShell => format!(
                "& {} app-server daemon start",
                ps_quote(codex_binary.path())
            ),
        };
        let result = self.exec_shell(&command, shell).await?;
        if result.exit_code != 0 {
            return Err(SshError::ExecFailed {
                exit_code: result.exit_code,
                stderr: format!(
                    "codex app-server daemon start failed: stdout={} stderr={}",
                    result.stdout.trim(),
                    result.stderr.trim()
                ),
            });
        }

        append_bridge_info_log(&format!(
            "ssh_app_server_daemon_start_output stdout={} stderr={}",
            result.stdout.trim(),
            result.stderr.trim()
        ));
        Ok(())
    }

    async fn launch_codex_app_server_unix(
        &self,
        codex_binary: &RemoteCodexBinary,
        working_dir: Option<&str>,
        shell: RemoteShell,
    ) -> Result<(Option<u32>, String), SshError> {
        let cd_prefix = match (shell, working_dir) {
            (RemoteShell::Posix, Some(dir)) => format!("cd {} && ", shell_quote(dir)),
            (RemoteShell::PowerShell, Some(dir)) => format!("Set-Location {}; ", ps_quote(dir)),
            _ => String::new(),
        };
        let log_path = "/tmp/codex-mobile-app-server-unix.log".to_string();
        let launch_cmd = match shell {
            RemoteShell::Posix => format!(
                "{profile_init} {cd_prefix}nohup {launch} \
                 </dev/null >{log} 2>&1 & echo $!",
                profile_init = PROFILE_INIT,
                cd_prefix = cd_prefix,
                launch = server_launch_command(codex_binary, "unix://", shell),
                log = shell_quote(&log_path),
            ),
            RemoteShell::PowerShell => {
                return Err(SshError::ExecFailed {
                    exit_code: 1,
                    stderr: "unix app-server launch is not supported on PowerShell remotes"
                        .to_string(),
                });
            }
        };
        let launch_result = self.exec_shell(&launch_cmd, shell).await?;
        let pid: Option<u32> = launch_result.stdout.trim().parse().ok();
        info!(
            "ssh app-server proxy launched unix app-server pid={:?} stdout={} stderr={}",
            pid,
            launch_result.stdout.trim(),
            launch_result.stderr.trim()
        );
        append_bridge_info_log(&format!(
            "ssh_app_server_proxy_launch_result pid={:?} stdout={} stderr={}",
            pid,
            launch_result.stdout.trim(),
            launch_result.stderr.trim()
        ));
        Ok((pid, log_path))
    }

    async fn wait_for_app_server_proxy_ready(
        &self,
        codex_binary: &RemoteCodexBinary,
        shell: RemoteShell,
        pid: Option<u32>,
        stdout_log_path: &str,
    ) -> Result<(), String> {
        let mut last_error = String::new();
        for attempt in 0..TUNNEL_HEALTH_ATTEMPTS {
            match self.probe_app_server_proxy(codex_binary, shell).await {
                Ok(()) => {
                    append_bridge_info_log(&format!(
                        "ssh_app_server_proxy_probe_success attempt={}",
                        attempt + 1
                    ));
                    return Ok(());
                }
                Err(error) => {
                    last_error = error;
                    if attempt == 0 || attempt == TUNNEL_HEALTH_ATTEMPTS - 1 {
                        append_bridge_info_log(&format!(
                            "ssh_app_server_proxy_probe_retry attempt={} error={}",
                            attempt + 1,
                            last_error
                        ));
                    }
                }
            }

            if let Some(p) = pid
                && !self.is_process_alive_shell(p, shell).await {
                    let tail = self
                        .fetch_process_log_tail_shell(stdout_log_path, None, shell)
                        .await;
                    return Err(if tail.is_empty() { last_error } else { tail });
                }

            tokio::time::sleep(TUNNEL_HEALTH_INTERVAL).await;
        }

        let tail = self
            .fetch_process_log_tail_shell(stdout_log_path, None, shell)
            .await;
        Err(if tail.is_empty() {
            format!("app-server proxy readiness probe failed: {last_error}")
        } else if last_error.is_empty() {
            tail
        } else {
            format!("{tail}\napp-server proxy readiness probe failed: {last_error}")
        })
    }

    async fn probe_app_server_proxy(
        &self,
        codex_binary: &RemoteCodexBinary,
        shell: RemoteShell,
    ) -> Result<(), String> {
        let stream = self
            .open_app_server_proxy_stream(codex_binary.path(), shell, None)
            .await
            .map_err(|error| error.to_string())?;
        let (mut websocket, _) = tokio::time::timeout(
            TUNNEL_HEALTH_INTERVAL * TUNNEL_HEALTH_ATTEMPTS,
            tokio_tungstenite::client_async(APP_SERVER_PROXY_WEBSOCKET_URL, stream),
        )
        .await
        .map_err(|_| "timed out opening websocket over app-server proxy".to_string())?
        .map_err(|error| format!("app-server proxy websocket handshake failed: {error}"))?;
        let _ = websocket.close(None).await;
        Ok(())
    }

    pub(crate) async fn bootstrap_codex_websocket_server_with_binary_and_shell(
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
                let websocket_ready = self
                    .wait_for_forwarded_websocket_ready(
                        local_port,
                        None,
                        shell,
                        shell.null_device(),
                        None,
                    )
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
                            codex_path: codex_binary.path().to_string(),
                            shell,
                            transport: SshBootstrapTransport::WebSocketTunnel,
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
                        server_launch_command(codex_binary, &format!("ws://{listen_addr}"), shell),
                    log = shell_quote(&log_path),
                ),
                RemoteShell::PowerShell => {
                    let (file_path, argument_list) =
                        windows_start_process_spec(codex_binary, &format!("ws://{listen_addr}"));
                    // -WindowStyle Hidden instead of -NoNewWindow because Windows
                    // OpenSSH sessions have no parent console; -NoNewWindow makes
                    // -RedirectStandard{Output,Error} silently fail in that mode.
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

            let mut started = false;
            for _attempt in 0..LISTEN_POLL_ATTEMPTS {
                if self.is_port_listening_shell(port, shell).await {
                    started = true;
                    break;
                }

                if let Some(p) = pid
                    && !self.is_process_alive_shell(p, shell).await {
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
                            break;
                        }
                        // If logs are empty, run the server synchronously to capture
                        // its actual exit reason (e.g. node not on PATH).
                        let tail = if tail.is_empty() {
                            warn!(
                                "ssh bootstrap logs empty, running sync probe shell={} port={}",
                                remote_shell_name(shell),
                                port
                            );
                            let diag_cmd = match shell {
                                RemoteShell::PowerShell => format!(
                                    r#"$nodeVer = & $env:ComSpec /d /c 'node --version' 2>&1 | Out-String; Write-Output "node_version:$($nodeVer.Trim())"; $out = & $env:ComSpec /d /c '"{bin}" {sub_args}--listen ws://{listen_addr}' 2>&1 | Out-String; Write-Output "server_output:$($out.Trim())""#,
                                    bin = cmd_quote(codex_binary.path()),
                                    sub_args = match codex_binary {
                                        RemoteCodexBinary::Codex(_) => "app-server ",
                                    },
                                    listen_addr = listen_addr,
                                ),
                                RemoteShell::Posix => format!(
                                    "{profile_init}\n\
                                     node_ver=\"$(node --version 2>&1)\" || node_ver='(node not found on PATH)'\n\
                                     printf 'node_version:%s\\n' \"$node_ver\"\n\
                                     out=\"$({bin} app-server --listen ws://{listen_addr} 2>&1)\"\n\
                                     printf 'server_output:%s\\n' \"$out\"",
                                    profile_init = PROFILE_INIT,
                                    bin = shell_quote(codex_binary.path()),
                                    listen_addr = listen_addr,
                                ),
                            };
                            match tokio::time::timeout(
                                SYNC_DIAG_TIMEOUT,
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
                                Err(_) => "server process exited immediately".into(),
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

                tokio::time::sleep(LISTEN_POLL_INTERVAL).await;
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
                    continue;
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
                codex_path: codex_binary.path().to_string(),
                shell,
                transport: SshBootstrapTransport::WebSocketTunnel,
            });
        }

        Err(SshError::ExecFailed {
            exit_code: 1,
            stderr: "exhausted all candidate ports".into(),
        })
    }

    pub(super) async fn wait_for_forwarded_websocket_ready(
        &self,
        local_port: u16,
        pid: Option<u32>,
        shell: RemoteShell,
        stdout_log_path: &str,
        stderr_log_path: Option<&str>,
    ) -> Result<(), String> {
        let websocket_url = format!("ws://127.0.0.1:{local_port}");
        let mut last_error = String::new();

        for attempt in 0..TUNNEL_HEALTH_ATTEMPTS {
            match tokio_tungstenite::connect_async(&websocket_url).await {
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
                    if attempt == 0 || attempt == TUNNEL_HEALTH_ATTEMPTS - 1 {
                        append_bridge_info_log(&format!(
                            "ssh_bootstrap_probe_retry url={} attempt={} error={}",
                            websocket_url,
                            attempt + 1,
                            last_error
                        ));
                    }
                }
            }

            if let Some(p) = pid
                && !self.is_process_alive_shell(p, shell).await {
                    let tail = self
                        .fetch_process_log_tail_shell(stdout_log_path, stderr_log_path, shell)
                        .await;
                    return Err(if tail.is_empty() { last_error } else { tail });
                }

            tokio::time::sleep(TUNNEL_HEALTH_INTERVAL).await;
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

    pub(super) async fn read_server_version_shell(
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
}
