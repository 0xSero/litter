use super::probes::format_process_logs;
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
    // Detailed contract lives in shell_quoting; this guards the re-export wiring.
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
        "'/usr/local/bin/codex' --enable goals app-server --listen 'ws://127.0.0.1:8390'"
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
        r#"@('/d', '/c', '""C:\Users\me\AppData\Roaming\npm\codex.cmd" --enable goals app-server --listen ws://127.0.0.1:8390"')"#
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
        "@('--enable', 'goals', 'app-server', '--listen', 'ws://127.0.0.1:8390')"
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
    assert_eq!(shell_quote("it's"), "'it'\\''s'");
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
        "/usr/bin/env sh -c 'echo '\\''hi'\\'' && printf '\\''%s'\\'' \"$HOME\"'"
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
            key_pem: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
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
        codex_path: "/usr/local/bin/codex".into(),
        shell: RemoteShell::Posix,
        transport: SshBootstrapTransport::WebSocketTunnel,
    };
    let r2 = r.clone();
    assert_eq!(r2.server_port, 8390);
    assert_eq!(r2.tunnel_local_port, 12345);
    assert_eq!(r2.server_version.as_deref(), Some("1.0.0"));
    assert_eq!(r2.pid, Some(42));
}

#[test]
fn test_profile_init_adds_common_node_manager_bins() {
    assert!(PROFILE_INIT.contains("$NVM_BIN"));
    assert!(PROFILE_INIT.contains("ASDF_DATA_DIR"));
    assert!(PROFILE_INIT.contains("/opt/homebrew/opt/node/bin"));
    assert!(PROFILE_INIT.contains("/opt/homebrew/bin"));
    assert!(PROFILE_INIT.contains("/usr/local/opt/node/bin"));
    assert!(PROFILE_INIT.contains("/usr/local/bin"));
    assert!(PROFILE_INIT.contains("$HOME/.volta/bin"));
    assert!(PROFILE_INIT.contains("$HOME/.bun/bin"));
    assert!(PROFILE_INIT.contains("NVM_DIR"));
    assert!(PROFILE_INIT.contains(".nvm"));
    assert!(PROFILE_INIT.contains(".fnm/node-versions"));
    assert!(PROFILE_INIT.contains(".asdf/shims"));
    assert!(PROFILE_INIT.contains(".local/share/mise/shims"));
    assert!(PROFILE_INIT.contains(".nix-profile/bin"));
    assert!(PROFILE_INIT.contains(".local/state}/nix/profile/bin"));
    assert!(PROFILE_INIT.contains("/etc/profiles/per-user/$USER/bin"));
    assert!(PROFILE_INIT.contains("/nix/var/nix/profiles/default/bin"));
    assert!(PROFILE_INIT.contains("/run/current-system/sw/bin"));
    assert!(PROFILE_INIT.contains("export PATH"));
}

#[cfg(unix)]
fn run_profile_init(home: &std::path::Path, shell: &std::path::Path) -> String {
    let script = format!("{PROFILE_INIT}\nprintf '__litter_test_path__%s\\n' \"$PATH\"");
    let output = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .env_clear()
        .env("HOME", home)
        .env("USER", "litter-test")
        .env("SHELL", shell)
        .env("PATH", "/usr/bin:/bin")
        .output()
        .expect("profile init should run under /bin/sh");
    assert!(
        output.status.success(),
        "profile init failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("profile output should be UTF-8")
        .lines()
        .find_map(|line| line.strip_prefix("__litter_test_path__"))
        .expect("profile init should print its final PATH")
        .to_owned()
}

#[cfg(unix)]
fn path_contains(path: &str, expected: &std::path::Path) -> bool {
    path.split(':')
        .any(|entry| std::path::Path::new(entry) == expected)
}

#[cfg(unix)]
#[test]
fn test_profile_init_never_executes_startup_files_or_login_shell() {
    use std::os::unix::fs::PermissionsExt;

    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let side_effect = "printf launched > \"$HOME/unwanted-terminal\"\n";
    for file in [
        ".profile",
        ".bash_profile",
        ".bashrc",
        ".zshenv",
        ".zprofile",
        ".zshrc",
    ] {
        std::fs::write(home.join(file), side_effect).unwrap();
    }
    let fish = home.join("fish");
    std::fs::write(&fish, format!("#!/bin/sh\n{side_effect}")).unwrap();
    std::fs::set_permissions(&fish, std::fs::Permissions::from_mode(0o755)).unwrap();
    let bin = home.join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();

    let path = run_profile_init(home, &fish);

    assert!(!home.join("unwanted-terminal").exists());
    assert!(path_contains(&path, &bin));
    assert!(path_contains(&path, std::path::Path::new("/usr/bin")));
    assert!(path_contains(&path, std::path::Path::new("/bin")));
}

#[cfg(unix)]
#[test]
fn test_profile_init_adds_user_nix_profile_bins_without_shell_config() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let legacy_nix_bin = home.join(".nix-profile/bin");
    let modern_nix_bin = home.join(".local/state/nix/profile/bin");
    std::fs::create_dir_all(&legacy_nix_bin).unwrap();
    std::fs::create_dir_all(&modern_nix_bin).unwrap();

    let path = run_profile_init(home, std::path::Path::new("/bin/sh"));

    assert!(path_contains(&path, &legacy_nix_bin));
    assert!(path_contains(&path, &modern_nix_bin));
}

#[test]
fn test_posix_resolver_probes_package_manager_bins() {
    let script = resolve_codex_binary_script_posix();
    assert!(script.contains("npm config get prefix"));
    assert!(script.contains("pnpm bin -g"));
    assert!(script.contains("bun pm bin -g"));
    assert!(script.contains("packages/standalone/current/codex"));
    assert!(script.contains("${BUN_INSTALL:-$HOME/.bun}/bin/codex"));
    assert!(script.contains("PNPM_HOME"));
    assert!(script.contains("NVM_BIN"));
    assert!(script.contains("$HOME/.volta/bin/codex"));
    assert!(script.contains("$HOME/.local/bin/codex"));
    assert!(script.contains("Codex.app/Contents/Resources/codex"));
    assert!(script.contains("/opt/homebrew/bin/codex"));
    assert!(script.contains("/usr/local/bin/codex"));
    assert!(script.contains("/usr/bin/codex"));
    assert!(
        script.find("_litter_consider_path_candidates codex codex") < script.find("pnpm bin -g")
    );
    assert!(script.contains("_litter_best_path"));
    assert!(!script.contains("codex-app-server"));
}

#[test]
fn test_powershell_resolver_prefers_latest_version() {
    let script = resolve_codex_binary_script_powershell();
    assert!(script.contains("Get-Command codex -All"));
    assert!(script.contains("packages\\standalone\\current\\codex.exe"));
    assert!(script.contains("AppData\\Roaming\\npm\\codex.cmd"));
    assert!(script.contains("$bestVersion"));
    assert!(script.contains("CompareTo"));
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
