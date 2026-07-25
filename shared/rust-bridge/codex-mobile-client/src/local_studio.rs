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
    // `find_local_studio_runtime` returns the full agent_dir\tprogram\t... line
    // only when both the agent data directory and the Pi runtime binary resolve.
    // The probe consumer (`parse_agent_probe`) only checks whether the field is
    // non-empty to mark `Available`, so emit a constant `1` on success rather
    // than splitting the runtime line with a bash parameter expansion.
    format!(
        r#"{FIND_AGENT_DIR}
{FIND_RUNTIME}
if find_local_studio_runtime >/dev/null 2>&1; then
  printf 'local-studio\t1\n'
else
  printf 'local-studio\t\n'
fi"#,
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
    // `probe_remote_agents` runs its probe under `PROFILE_INIT`, so the PATH
    // fallback tier (`command -v pi-coding-agent || command -v pi`) can resolve
    // during discovery. Resolving without the same login profile here would
    // report Local Studio as available in the picker and then fail to launch it.
    let result = ssh
        .exec_shell(
            &format!("{PROFILE_INIT}\n{FIND_AGENT_DIR}\n{FIND_RUNTIME}\nfind_local_studio_runtime"),
            shell,
        )
        .await?;
    if result.exit_code != 0 {
        return Ok(None);
    }
    Ok(result.stdout.lines().find_map(parse_runtime))
}

fn parse_runtime(line: &str) -> Option<Runtime> {
    let mut fields = line.splitn(4, '\t');
    let agent_dir = fields.next()?.trim();
    let program = fields.next()?.trim();
    let prefix_arg = fields.next()?.trim();
    if agent_dir.is_empty() || program.is_empty() {
        return None;
    }
    Some(Runtime {
        agent_dir: agent_dir.to_owned(),
        program: program.to_owned(),
        prefix_arg: (!prefix_arg.is_empty()).then(|| prefix_arg.to_owned()),
        electron_node: fields.next()?.trim() == "1",
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
    use std::sync::Mutex;

    /// Captures the [`ProcessSpec`] it is handed and always fails the launch.
    /// The decorator's contract is the spec rewrite, not the spawn.
    struct CapturingLauncher {
        captured: Mutex<Option<ProcessSpec>>,
    }

    impl CapturingLauncher {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                captured: Mutex::new(None),
            })
        }

        fn take(&self) -> ProcessSpec {
            self.captured
                .lock()
                .expect("capture mutex poisoned")
                .take()
                .expect("launcher was never invoked")
        }
    }

    impl ProcessLauncher for CapturingLauncher {
        fn launch(
            &self,
            spec: ProcessSpec,
        ) -> BoxFuture<'_, std::io::Result<Box<dyn ChildProcess>>> {
            *self.captured.lock().expect("capture mutex poisoned") = Some(spec);
            Box::pin(async {
                Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    "capturing launcher does not spawn",
                ))
            })
        }
    }

    fn bundled_runtime() -> Runtime {
        Runtime {
            agent_dir: "/Users/test/Library/Application Support/Local Studio/pi-agent".to_owned(),
            program: "/Applications/Local Studio.app/Contents/MacOS/Local Studio".to_owned(),
            prefix_arg: Some("/Applications/Local Studio.app/Contents/Resources/pi cli.js".to_owned()),
            electron_node: true,
        }
    }

    fn env_value<'a>(spec: &'a ProcessSpec, key: &str) -> Option<&'a OsStr> {
        spec.env
            .iter()
            .find(|(candidate, _)| candidate == key)
            .map(|(_, value)| value.as_os_str())
    }

    async fn launch_capturing(runtime: &Runtime, spec: ProcessSpec) -> ProcessSpec {
        let inner = CapturingLauncher::new();
        let decorated = launcher(Arc::clone(&inner) as Arc<dyn ProcessLauncher>, runtime);
        let _ = decorated.launch(spec).await;
        inner.take()
    }

    #[tokio::test]
    async fn agent_launch_uses_the_bundled_electron_runtime() {
        let runtime = bundled_runtime();
        let mut spec = ProcessSpec::new("/usr/bin/pi");
        spec.role = alleycat_bridge_core::ProcessRole::Agent;
        spec.args = vec![OsString::from("--mode"), OsString::from("rpc")];

        let launched = launch_capturing(&runtime, spec).await;

        assert_eq!(
            launched.program.to_str(),
            Some("/Applications/Local Studio.app/Contents/MacOS/Local Studio"),
            "the agent program must be replaced by the Local Studio runtime"
        );
        assert_eq!(
            launched.args.first().and_then(|arg| arg.to_str()),
            Some("/Applications/Local Studio.app/Contents/Resources/pi cli.js"),
            "the bundled CLI must be prepended ahead of the original args"
        );
        assert_eq!(
            launched.args.iter().filter_map(|arg| arg.to_str()).collect::<Vec<_>>(),
            vec![
                "/Applications/Local Studio.app/Contents/Resources/pi cli.js",
                "--mode",
                "rpc"
            ],
            "original args must be preserved after the prefix"
        );
        assert_eq!(
            env_value(&launched, "ELECTRON_RUN_AS_NODE"),
            Some(OsStr::new("1"))
        );
        assert_eq!(
            env_value(&launched, "PI_CODING_AGENT_DIR"),
            Some(OsStr::new(
                "/Users/test/Library/Application Support/Local Studio/pi-agent"
            ))
        );
    }

    #[tokio::test]
    async fn tool_commands_get_the_agent_dir_but_keep_their_program() {
        let runtime = bundled_runtime();
        let mut spec = ProcessSpec::new("/bin/sh");
        spec.role = alleycat_bridge_core::ProcessRole::ToolCommand;
        spec.args = vec![OsString::from("-c"), OsString::from("pwd")];

        let launched = launch_capturing(&runtime, spec).await;

        assert_eq!(
            launched.program.to_str(),
            Some("/bin/sh"),
            "tool commands must not be rewritten to the agent runtime"
        );
        assert_eq!(
            launched.args.iter().filter_map(|arg| arg.to_str()).collect::<Vec<_>>(),
            vec!["-c", "pwd"],
            "tool command args must not gain the CLI prefix"
        );
        assert_eq!(
            env_value(&launched, "PI_CODING_AGENT_DIR"),
            Some(OsStr::new(
                "/Users/test/Library/Application Support/Local Studio/pi-agent"
            )),
            "tool commands still need to resolve Local Studio's Pi home"
        );
        assert!(
            env_value(&launched, "ELECTRON_RUN_AS_NODE").is_none(),
            "ELECTRON_RUN_AS_NODE is an agent-only concern"
        );
    }

    #[tokio::test]
    async fn an_explicit_agent_dir_is_never_overridden() {
        let runtime = bundled_runtime();
        let mut spec = ProcessSpec::new("/usr/bin/pi");
        spec.role = alleycat_bridge_core::ProcessRole::Agent;
        spec.env.push((
            OsString::from("PI_CODING_AGENT_DIR"),
            OsString::from("/explicit/override"),
        ));

        let launched = launch_capturing(&runtime, spec).await;

        assert_eq!(
            env_value(&launched, "PI_CODING_AGENT_DIR"),
            Some(OsStr::new("/explicit/override"))
        );
        assert_eq!(
            launched
                .env
                .iter()
                .filter(|(key, _)| key == "PI_CODING_AGENT_DIR")
                .count(),
            1,
            "the decorator must not append a duplicate agent-dir entry"
        );
    }

    #[tokio::test]
    async fn path_fallback_runtime_adds_no_prefix_or_electron_flag() {
        let runtime = Runtime {
            agent_dir: "/home/test/.local-studio/pi-agent".to_owned(),
            program: "/usr/bin/pi".to_owned(),
            prefix_arg: None,
            electron_node: false,
        };
        let mut spec = ProcessSpec::new("/somewhere/else/pi");
        spec.role = alleycat_bridge_core::ProcessRole::Agent;
        spec.args = vec![OsString::from("--mode"), OsString::from("rpc")];

        let launched = launch_capturing(&runtime, spec).await;

        assert_eq!(launched.program.to_str(), Some("/usr/bin/pi"));
        assert_eq!(
            launched.args.iter().filter_map(|arg| arg.to_str()).collect::<Vec<_>>(),
            vec!["--mode", "rpc"]
        );
        assert!(env_value(&launched, "ELECTRON_RUN_AS_NODE").is_none());
    }

    #[test]
    fn probe_script_reports_only_the_agent_dir() {
        let script = probe_script();
        assert!(
            script.contains("printf 'local-studio\\t%s\\n'"),
            "probe must emit the agent-probe wire line"
        );
        assert!(
            script.contains("${runtime%%\t*}"),
            "probe must report the first tab-separated field (agent dir) only"
        );
        assert!(
            script.contains("printf 'local-studio\\t\\n'"),
            "probe must still emit an unavailable line when no runtime resolves"
        );
    }

    #[test]
    fn session_scan_prefix_quotes_directories_with_spaces() {
        let prefix =
            session_scan_prefix("/Users/test/Library/Application Support/Local Studio/pi-agent");
        assert!(
            prefix.contains("'/Users/test/Library/Application Support/Local Studio/pi-agent'"),
            "agent dir must be POSIX-quoted, got: {prefix}"
        );
        assert!(prefix.contains("export PI_CODING_AGENT_DIR"));
    }

    #[test]
    fn parse_runtime_rejects_incomplete_lines() {
        assert!(parse_runtime("").is_none());
        assert!(parse_runtime("\t/usr/bin/pi\t\t0").is_none(), "empty agent dir");
        assert!(parse_runtime("/agent/dir\t\t\t0").is_none(), "empty program");
        assert!(parse_runtime("/agent/dir").is_none(), "missing fields");
    }

    #[test]
    fn parses_bundled_runtime_with_spaces() {
        let runtime = parse_runtime(
            "/Users/test/Library/Application Support/Local Studio/pi-agent\t\
             /Applications/Local Studio.app/Contents/MacOS/Local Studio\t\
             /Applications/Local Studio.app/Contents/Resources/pi cli.js\t1",
        )
        .unwrap();
        assert_eq!(runtime.agent_dir, "/Users/test/Library/Application Support/Local Studio/pi-agent");
        assert_eq!(runtime.prefix_arg.as_deref(), Some("/Applications/Local Studio.app/Contents/Resources/pi cli.js"));
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
