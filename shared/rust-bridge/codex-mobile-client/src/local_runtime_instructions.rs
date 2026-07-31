use crate::MobileClient;

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
const IOS_LOCAL_RUNTIME_SENTINEL: &str =
    "You are running inside Litter's local Codex runtime on iOS.";

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
pub(crate) const IOS_LOCAL_RUNTIME_DEVELOPER_INSTRUCTIONS: &str = r#"You are running inside Litter's local Codex runtime on iOS.

The shell tool is backed by a persistent iSH Alpine Linux fakefs, not the iOS host filesystem or ios_system. Treat paths, packages, and command behavior as Alpine Linux inside iSH.

- The default home and working directory is `/root` inside the iSH fakefs.
- Use POSIX `/bin/sh` and Alpine/BusyBox userland expectations. Bash, zsh, and macOS tools may be absent unless installed in the fakefs.
- Use Alpine's `apk` package manager when installing packages is necessary and permitted.
- The iSH fakefs cannot see iOS app sandbox paths such as `/var`, `/private`, `/Users`, `/Library`, `/System`, or `/Applications`. Work under fakefs paths such as `/root` unless the user gives a known reachable path.
- Do not assume ios_system-specific behavior for local commands."#;

pub(crate) fn splice_local_runtime_developer_instructions(
    client: &MobileClient,
    server_id: &str,
    existing: Option<String>,
) -> Option<String> {
    if !should_apply_local_runtime_instructions(client, server_id) {
        return existing;
    }

    let Some((sentinel, instructions)) = platform_local_runtime_instructions() else {
        return existing;
    };

    if existing
        .as_deref()
        .is_some_and(|value| value.contains(sentinel))
    {
        return existing;
    }

    Some(match existing {
        Some(previous) if !previous.trim().is_empty() => {
            format!("{instructions}\n\n{previous}")
        }
        _ => instructions.to_string(),
    })
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
fn should_apply_local_runtime_instructions(client: &MobileClient, server_id: &str) -> bool {
    client
        .app_store
        .snapshot()
        .servers
        .get(server_id)
        .is_some_and(|server| server.is_local)
}

#[cfg(not(any(all(target_os = "ios", not(target_abi = "macabi")), test)))]
fn should_apply_local_runtime_instructions(_client: &MobileClient, _server_id: &str) -> bool {
    false
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
fn platform_local_runtime_instructions() -> Option<(&'static str, &'static str)> {
    Some((
        IOS_LOCAL_RUNTIME_SENTINEL,
        IOS_LOCAL_RUNTIME_DEVELOPER_INSTRUCTIONS,
    ))
}

#[cfg(not(any(all(target_os = "ios", not(target_abi = "macabi")), test)))]
fn platform_local_runtime_instructions() -> Option<(&'static str, &'static str)> {
    None
}

#[cfg(test)]
mod tests {
    use super::{
        IOS_LOCAL_RUNTIME_DEVELOPER_INSTRUCTIONS, splice_local_runtime_developer_instructions,
    };
    use crate::MobileClient;
    use crate::session::connection::ServerConfig;
    use crate::store::ServerHealthSnapshot;

    fn server_config(server_id: &str, is_local: bool) -> ServerConfig {
        ServerConfig {
            server_id: server_id.to_string(),
            display_name: server_id.to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            websocket_url: None,
            is_local,
            tls: false,
        }
    }

    #[test]
    fn prepends_for_local_server() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &server_config("local", true),
            ServerHealthSnapshot::Connected,
        );

        let result = splice_local_runtime_developer_instructions(
            &client,
            "local",
            Some("keep this".to_string()),
        )
        .expect("instructions");

        assert!(result.starts_with(IOS_LOCAL_RUNTIME_DEVELOPER_INSTRUCTIONS));
        assert!(result.ends_with("keep this"));
    }

    #[test]
    fn skips_remote_server() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &server_config("remote", false),
            ServerHealthSnapshot::Connected,
        );

        let result = splice_local_runtime_developer_instructions(
            &client,
            "remote",
            Some("keep this".to_string()),
        );

        assert_eq!(result.as_deref(), Some("keep this"));
    }

    #[test]
    fn does_not_duplicate_existing_preamble() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &server_config("local", true),
            ServerHealthSnapshot::Connected,
        );
        let existing = IOS_LOCAL_RUNTIME_DEVELOPER_INSTRUCTIONS.to_string();

        let result = splice_local_runtime_developer_instructions(&client, "local", Some(existing));

        assert_eq!(
            result.as_deref(),
            Some(IOS_LOCAL_RUNTIME_DEVELOPER_INSTRUCTIONS)
        );
    }
}
