use std::ffi::{OsStr, OsString};
use std::sync::Arc;

use alleycat_bridge_core::{ChildProcess, ProcessLauncher, ProcessSpec};
use futures::future::BoxFuture;

use crate::ssh::{RemoteShell, SshClient, SshError};

pub(crate) const RUNTIME_KIND: &str = "local-studio";

const FIND_AGENT_DIR: &str = r#"find_local_studio_agent_dir() {
  for candidate in \
    "${LOCAL_STUDIO_DATA_DIR:+$LOCAL_STUDIO_DATA_DIR/pi-agent}" \
    "$HOME/Library/Application Support/Local Studio/pi-agent" \
    "$HOME/.vllm-studio/pi-agent" \
    "$HOME/.local-studio/pi-agent"
  do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate/models.json" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}"#;

pub(crate) fn probe_script() -> String {
    format!(
        r#"{FIND_AGENT_DIR}
agent_dir=$(find_local_studio_agent_dir 2>/dev/null || true)
pi_bin=$(command -v pi-coding-agent 2>/dev/null || command -v pi 2>/dev/null || true)
if [ -n "$agent_dir" ] && [ -n "$pi_bin" ]; then
  printf 'local-studio\t%s\n' "$agent_dir"
else
  printf 'local-studio\t\n'
fi"#
    )
}

pub(crate) async fn resolve_agent_dir(
    ssh: &SshClient,
    shell: RemoteShell,
) -> Result<Option<String>, SshError> {
    let result = ssh
        .exec_shell(
            &format!("{FIND_AGENT_DIR}\nfind_local_studio_agent_dir"),
            shell,
        )
        .await?;
    if result.exit_code != 0 {
        return Ok(None);
    }
    Ok(result
        .stdout
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(ToOwned::to_owned))
}

pub(crate) fn session_scan_prefix(agent_dir: &str) -> String {
    format!(
        "PI_CODING_AGENT_DIR={}\nexport PI_CODING_AGENT_DIR",
        crate::ssh::shell_quote(agent_dir)
    )
}

pub(crate) fn launcher(
    inner: Arc<dyn ProcessLauncher>,
    agent_dir: &str,
) -> Arc<dyn ProcessLauncher> {
    Arc::new(EnvironmentOverlayLauncher {
        inner,
        key: OsString::from("PI_CODING_AGENT_DIR"),
        value: OsStr::new(agent_dir).to_os_string(),
    })
}

#[derive(Clone)]
struct EnvironmentOverlayLauncher {
    inner: Arc<dyn ProcessLauncher>,
    key: OsString,
    value: OsString,
}

impl ProcessLauncher for EnvironmentOverlayLauncher {
    fn launch(
        &self,
        mut spec: ProcessSpec,
    ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
        let key = self.key.clone();
        let value = self.value.clone();
        Box::pin(async move {
            if !spec.env.iter().any(|(candidate, _)| candidate == &key) {
                spec.env.push((key, value));
            }
            self.inner.launch(spec).await
        })
    }
}
