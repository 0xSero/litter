//! Locate an existing `codex` binary on the remote host. The search list
//! is shared with the Rust-native local resolver via
//! `crate::local_server::shell_candidate_lines` so the two cannot drift.
//!
//! `fetch_codex_resolver_diagnostics` powers the "codex not found" error:
//! it dumps PATH, env anchors, and per-candidate existence/executability
//! so failures are debuggable from a single log line.

use tracing::{info, trace, warn};

use super::{
    PACKAGE_MANAGER_PROBE, PROFILE_INIT, RemoteCodexBinary, RemoteShell, SshClient, SshError,
    remote_shell_name, resolve_codex_binary_script_posix, resolve_codex_binary_script_powershell,
};

impl SshClient {
    /// Locate the `codex` binary on the remote host.
    pub(crate) async fn resolve_codex_binary_optional(
        &self,
    ) -> Result<Option<RemoteCodexBinary>, SshError> {
        self.resolve_codex_binary_optional_with_shell(None).await
    }

    pub(crate) async fn resolve_codex_binary_optional_with_shell(
        &self,
        shell_hint: Option<RemoteShell>,
    ) -> Result<Option<RemoteCodexBinary>, SshError> {
        if let Some(path) = self.with_detection(|d| d.codex_path.clone()) {
            trace!("ssh resolve codex binary cached path={path}");
            return Ok(Some(RemoteCodexBinary::Codex(path)));
        }
        let shell = match shell_hint {
            Some(s) => s,
            None => self.detect_remote_shell().await,
        };
        let resolved = self.resolve_codex_binary_uncached(shell).await?;
        if let Some(binary) = resolved.as_ref() {
            let path = binary.path().to_string();
            self.with_detection(|d| d.codex_path = Some(path));
        }
        Ok(resolved)
    }

    pub(crate) async fn resolve_codex_binary_uncached(
        &self,
        shell: RemoteShell,
    ) -> Result<Option<RemoteCodexBinary>, SshError> {
        trace!(
            "ssh resolve codex binary shell={}",
            remote_shell_name(shell)
        );

        let script = match shell {
            RemoteShell::PowerShell => resolve_codex_binary_script_powershell(),
            RemoteShell::Posix => resolve_codex_binary_script_posix(),
        };

        let result = self.exec_shell(&script, shell).await?;
        let raw = result.stdout.trim();
        if raw.is_empty() {
            info!(
                "ssh resolve codex binary missing shell={}",
                remote_shell_name(shell)
            );
            return Ok(None);
        }
        if let Some(path) = raw.strip_prefix("codex:") {
            info!(
                "ssh resolve codex binary found selector=codex shell={} path={}",
                remote_shell_name(shell),
                path
            );
            return Ok(Some(RemoteCodexBinary::Codex(path.to_string())));
        }
        warn!(
            "ssh resolve codex binary unexpected selector shell={} raw={}",
            remote_shell_name(shell),
            raw
        );
        Err(SshError::ExecFailed {
            exit_code: 1,
            stderr: format!("unexpected remote codex binary selector: {raw}"),
        })
    }

    pub(super) async fn resolve_codex_binary(&self) -> Result<RemoteCodexBinary, SshError> {
        match self.resolve_codex_binary_optional().await? {
            Some(binary) => Ok(binary),
            None => {
                let diagnostics = self.fetch_codex_resolver_diagnostics().await;
                Err(SshError::ExecFailed {
                    exit_code: 1,
                    stderr: if diagnostics.is_empty() {
                        "codex not found on remote host".into()
                    } else {
                        format!(
                            "codex not found on remote host\nresolver diagnostics:\n{}",
                            diagnostics
                        )
                    },
                })
            }
        }
    }

    async fn fetch_codex_resolver_diagnostics(&self) -> String {
        let script = format!(
            r#"{profile_init}
{pkg_probe}
printf 'shell=%s\n' "${{SHELL:-}}"
printf 'path=%s\n' "${{PATH:-}}"
printf 'pnpm_home=%s\n' "${{PNPM_HOME:-}}"
printf 'nvm_bin=%s\n' "${{NVM_BIN:-}}"
printf 'npm_prefix=%s\n' "$_litter_npm_prefix"
printf 'bun_global_bin=%s\n' "$_litter_bun_global_bin"
printf 'pnpm_global_bin=%s\n' "$_litter_pnpm_global_bin"
printf 'npm_global_bin=%s\n' "$_litter_npm_global_bin"
printf 'whoami='; whoami 2>/dev/null || true
printf 'pwd='; pwd 2>/dev/null || true
printf 'command -v codex='
command -v codex 2>/dev/null || printf '<missing>'
	printf '\n'
	for candidate in \
	  "${{CODEX_HOME:-$HOME/.codex}}/packages/standalone/current/codex" \
	  "${{BUN_INSTALL:-$HOME/.bun}}/bin/codex" \
	  "$HOME/.volta/bin/codex" \
  "$HOME/.local/bin/codex" \
  "${{PNPM_HOME:-}}/codex" \
  "${{NVM_BIN:-}}/codex" \
  "${{VOLTA_HOME:+$VOLTA_HOME/bin/codex}}" \
  "${{CARGO_HOME:-$HOME/.cargo}}/bin/codex" \
  "$HOME/Applications/Codex.app/Contents/Resources/codex" \
  "/Applications/Codex.app/Contents/Resources/codex" \
  "${{_litter_bun_global_bin:-}}/codex" \
  "${{_litter_npm_global_bin:-}}/codex" \
  "${{_litter_pnpm_global_bin:-}}/codex" \
  "/opt/homebrew/bin/codex" \
  "/usr/local/bin/codex" \
  "/usr/bin/codex"
do
  if [ -e "$candidate" ]; then
    if [ -x "$candidate" ]; then
      printf 'candidate=%s [exists executable]\n' "$candidate"
    else
      printf 'candidate=%s [exists not-executable]\n' "$candidate"
    fi
  fi
done"#,
            profile_init = PROFILE_INIT,
            pkg_probe = PACKAGE_MANAGER_PROBE
        );

        match self.exec_posix(&script).await {
            Ok(result) => result.stdout.trim().to_string(),
            Err(error) => format!("failed to collect resolver diagnostics: {error}"),
        }
    }
}
