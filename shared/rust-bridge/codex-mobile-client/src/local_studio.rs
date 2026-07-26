use std::ffi::{OsStr, OsString};
use std::sync::Arc;

use alleycat_bridge_core::{ChildProcess, ProcessLauncher, ProcessSpec};
use futures::future::BoxFuture;

use crate::ssh::{PROFILE_INIT, RemoteShell, SshClient, SshError};

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

const FIND_RUNTIME: &str = r#"find_local_studio_runtime() {
  agent_dir=$(find_local_studio_agent_dir 2>/dev/null || true)
  [ -n "$agent_dir" ] || return 1
  for app in "/Applications/Local Studio.app" "$HOME/Applications/Local Studio.app"; do
    program="$app/Contents/MacOS/Local Studio"
    cli="$app/Contents/Resources/app/frontend/.next/standalone/frontend/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
    if [ -x "$program" ] && [ -f "$cli" ]; then
      printf '%s\t%s\t%s\t1\n' "$agent_dir" "$program" "$cli"
      return 0
    fi
  done
  metadata="${agent_dir%/pi-agent}/litter-bridge.json"
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$metadata" 2>/dev/null | head -n 1)
  if [ -n "$pid" ] && [ -x "/proc/$pid/exe" ]; then
    program=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
    for cli in \
      "$cwd/../../frontend/node_modules/@earendil-works/pi-coding-agent/dist/cli.js" \
      "$cwd/frontend/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
    do
      if [ -x "$program" ] && [ -f "$cli" ]; then
        printf '%s\t%s\t%s\t0\n' "$agent_dir" "$program" "$cli"
        return 0
      fi
    done
  fi
  program=$(command -v pi-coding-agent 2>/dev/null || command -v pi 2>/dev/null || true)
  [ -n "$program" ] || return 1
  printf '%s\t%s\t\t0\n' "$agent_dir" "$program"
}"#;

pub(crate) fn probe_script() -> String {
    format!(
        r#"{FIND_AGENT_DIR}
{FIND_RUNTIME}
runtime=$(find_local_studio_runtime 2>/dev/null || true)
if [ -n "$runtime" ]; then
  printf 'local-studio\t%s\n' "${{runtime%%	*}}"
else
  printf 'local-studio\t\n'
fi"#
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Runtime {
    pub agent_dir: String,
    pub program: String,
    pub prefix_arg: Option<String>,
    pub electron_node: bool,
}

pub(crate) async fn resolve_runtime(
    ssh: &SshClient,
    shell: RemoteShell,
) -> Result<Option<Runtime>, SshError> {
    let result = ssh
        .exec_shell(
            &format!("{PROFILE_INIT}\n{FIND_AGENT_DIR}\n{FIND_RUNTIME}\nfind_local_studio_runtime"),
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
        .and_then(parse_runtime))
}

fn parse_runtime(line: &str) -> Option<Runtime> {
    let mut fields = line.splitn(4, '\t');
    let agent_dir = fields.next()?.trim();
    let program = fields.next()?.trim();
    let prefix_arg = fields.next()?.trim();
    let electron_node = fields.next()?.trim() == "1";
    if agent_dir.is_empty() || program.is_empty() {
        return None;
    }
    Some(Runtime {
        agent_dir: agent_dir.to_owned(),
        program: program.to_owned(),
        prefix_arg: (!prefix_arg.is_empty()).then(|| prefix_arg.to_owned()),
        electron_node,
    })
}

pub(crate) fn session_scan_prefix(agent_dir: &str) -> String {
    format!(
        "PI_CODING_AGENT_DIR={}\nexport PI_CODING_AGENT_DIR",
        crate::ssh::shell_quote(agent_dir)
    )
}

pub(crate) fn launcher(
    inner: Arc<dyn ProcessLauncher>,
    runtime: &Runtime,
) -> Arc<dyn ProcessLauncher> {
    Arc::new(RuntimeLauncher {
        inner,
        runtime: runtime.clone(),
    })
}

#[derive(Clone)]
struct RuntimeLauncher {
    inner: Arc<dyn ProcessLauncher>,
    runtime: Runtime,
}

impl ProcessLauncher for RuntimeLauncher {
    fn launch(
        &self,
        mut spec: ProcessSpec,
    ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
        let runtime = self.runtime.clone();
        Box::pin(async move {
            if !spec.env.iter().any(|(key, _)| key == "PI_CODING_AGENT_DIR") {
                spec.env.push((
                    OsString::from("PI_CODING_AGENT_DIR"),
                    OsStr::new(&runtime.agent_dir).to_os_string(),
                ));
            }
            if spec.role == alleycat_bridge_core::ProcessRole::Agent {
                spec.program = runtime.program.into();
                if let Some(prefix) = runtime.prefix_arg {
                    spec.args.insert(0, prefix.into());
                }
                if runtime.electron_node {
                    spec.env
                        .push((OsString::from("ELECTRON_RUN_AS_NODE"), OsString::from("1")));
                }
            }
            self.inner.launch(spec).await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bundled_runtime_with_spaces() {
        let runtime = parse_runtime(
            "/Users/test/Library/Application Support/Local Studio/pi-agent\t\
             /Applications/Local Studio.app/Contents/MacOS/Local Studio\t\
             /Applications/Local Studio.app/Contents/Resources/pi cli.js\t1",
        )
        .unwrap();
        assert_eq!(
            runtime.agent_dir,
            "/Users/test/Library/Application Support/Local Studio/pi-agent"
        );
        assert_eq!(
            runtime.prefix_arg.as_deref(),
            Some("/Applications/Local Studio.app/Contents/Resources/pi cli.js")
        );
        assert!(runtime.electron_node);
    }

    #[test]
    fn parses_global_fallback_without_prefix() {
        let runtime = parse_runtime("/home/test/.local-studio/pi-agent\t/usr/bin/pi\t\t0").unwrap();
        assert_eq!(runtime.program, "/usr/bin/pi");
        assert_eq!(runtime.prefix_arg, None);
        assert!(!runtime.electron_node);
    }
}
