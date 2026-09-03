//! Shell scripts that run on remote hosts during SSH bootstrap, agent spawn,
//! and supporting probes. Each script is checked in as a real `.sh` / `.ps1`
//! file so editors give it syntax highlighting and `shellcheck` runs on it
//! as part of `make rust-test`. The files are embedded at compile time via
//! [`include_str!`].
//!
//! Templates use `{{KEY}}` placeholders. [`render`] does plain text
//! substitution — there is no escape syntax. Pass shell-quoted values via
//! [`crate::shell_quoting::posix_quote`] / `powershell_quote`. Including
//! one script inside another (e.g. POSIX scripts that need
//! [`PROFILE_INIT`]) is done by passing the included script's text as a
//! `{{PROFILE_INIT}}` substitution.

/// POSIX-shell snippets.
pub(crate) mod posix {
    /// Source common shell rc files into `$PATH`. Inline this at the top of
    /// any POSIX script that calls user-installed binaries.
    pub(crate) const PROFILE_INIT: &str = include_str!("posix/profile_init.sh");

    /// Probe `npm` / `pnpm` / `bun` for their global bin directories. Sets
    /// `$_litter_npm_global_bin`, `$_litter_pnpm_global_bin`,
    /// `$_litter_bun_global_bin`. Requires `PROFILE_INIT` first.
    pub(crate) const PACKAGE_MANAGER_PROBE: &str = include_str!("posix/package_manager_probe.sh");

    /// Find the newest existing `codex` binary on the remote. Placeholders:
    /// `{{PROFILE_INIT}}`, `{{PACKAGE_MANAGER_PROBE}}`, `{{SHARED_LINES}}`.
    pub(crate) const RESOLVE_CODEX_BINARY: &str =
        alleycat_bridge_core::codex_resolver::POSIX_RESOLVE_CODEX_BINARY;

    /// Detect whether anything is listening on TCP `{{PORT}}` using lsof,
    /// then ss, then netstat (whichever is present).
    pub(crate) const PORT_LISTENING: &str = include_str!("posix/port_listening.sh");

    /// Kill any listener on TCP `{{PORT}}`. Tries SIGTERM, waits, escalates
    /// to SIGKILL.
    pub(crate) const KILL_PORT_LISTENER: &str = include_str!("posix/kill_port_listener.sh");

    /// Spawn a remote opencode agent in a per-session directory. Placeholders:
    /// `{{PROFILE_INIT}}`, `{{SESSION_ID}}`, `{{BIN}}` (shell-quoted),
    /// `{{PORT}}`.
    pub(crate) const OPENCODE_SPAWN: &str = include_str!("posix/opencode_spawn.sh");

    /// Poll `/global/health` on a remote opencode until it reports healthy
    /// or the underlying process dies. Placeholders: `{{PROFILE_INIT}}`,
    /// `{{SESSION_ID}}`, `{{PORT}}`.
    pub(crate) const OPENCODE_HEALTH_WAIT: &str = include_str!("posix/opencode_health_wait.sh");

    /// Tail the out/err logs from a remote opencode session. Placeholders:
    /// `{{PROFILE_INIT}}`, `{{SESSION_ID}}`.
    pub(crate) const OPENCODE_LOGS: &str = include_str!("posix/opencode_logs.sh");

    /// Stop a remote opencode session by the pid saved at spawn time.
    /// Placeholders: `{{PROFILE_INIT}}`, `{{SESSION_ID}}`.
    pub(crate) const OPENCODE_CLEANUP: &str = include_str!("posix/opencode_cleanup.sh");

    /// Scan `~/.claude/projects` for thread/session metadata.
    pub(crate) const CLAUDE_SESSION_SCAN: &str = include_str!("posix/claude_session_scan.sh");

    /// Scan `~/.pi/agent/sessions` for thread/session metadata.
    pub(crate) const PI_SESSION_SCAN: &str = include_str!("posix/pi_session_scan.sh");

    /// Spawn a long-running detached agent behind a stdin keeper FIFO.
    /// Placeholders: `{{ROOT}}`, `{{INPUT}}`, `{{OUT_LOG}}`, `{{ERR_LOG}}`,
    /// `{{KEEPER_PID}}`, `{{AGENT_PID}}` (all caller-quoted), `{{COMMAND}}`
    /// (shell-quoted).
    pub(crate) const DETACHED_SPAWN: &str = include_str!("posix/detached_spawn.sh");

    /// Tear down a detached agent: SIGTERM the child, SIGTERM the keeper,
    /// `rm -rf` the session directory. Placeholders: `{{ROOT}}`,
    /// `{{KEEPER_PID}}`, `{{AGENT_PID}}` (caller-quoted).
    pub(crate) const DETACHED_KILL: &str = include_str!("posix/detached_kill.sh");
}

/// PowerShell snippets.
pub(crate) mod powershell {
    /// Find the newest existing `codex` executable on the remote.
    pub(crate) const RESOLVE_CODEX_BINARY: &str =
        alleycat_bridge_core::codex_resolver::POWERSHELL_RESOLVE_CODEX_BINARY;

    /// Detect whether anything is listening on TCP `{{PORT}}`.
    pub(crate) const PORT_LISTENING: &str = include_str!("powershell/port_listening.ps1");

    /// Kill the process(es) holding TCP `{{PORT}}`.
    pub(crate) const KILL_PORT_LISTENER: &str = include_str!("powershell/kill_port_listener.ps1");
}

/// Render `template` by replacing each `{{KEY}}` placeholder with its value.
/// Walks `template` left-to-right exactly once; substituted values are not
/// re-scanned, so a value containing `{{X}}` stays literal even if `X` is
/// also in `vars`. Unknown keys pass through untouched.
pub(crate) fn render(template: &str, vars: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find("{{") {
        out.push_str(&rest[..start]);
        let after_open = &rest[start + 2..];
        let Some(end) = after_open.find("}}") else {
            out.push_str("{{");
            rest = after_open;
            break;
        };
        let key = &after_open[..end];
        match vars.iter().find(|(k, _)| *k == key) {
            Some((_, val)) => out.push_str(val),
            None => {
                out.push_str("{{");
                out.push_str(key);
                out.push_str("}}");
            }
        }
        rest = &after_open[end + 2..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_substitutes_placeholders() {
        assert_eq!(
            render(
                "hello {{NAME}}, port {{PORT}}",
                &[("NAME", "world"), ("PORT", "42")]
            ),
            "hello world, port 42"
        );
    }

    #[test]
    fn render_repeats_substitutions() {
        assert_eq!(render("{{X}} and {{X}}", &[("X", "ok")]), "ok and ok");
    }

    #[test]
    fn render_leaves_unknown_keys_untouched() {
        assert_eq!(
            render("a {{UNUSED}} b", &[("OTHER", "x")]),
            "a {{UNUSED}} b"
        );
    }

    #[test]
    fn render_does_not_re_expand_substituted_values() {
        // {{INNER}} appears inside the *value* of OUTER. We do not recursively
        // expand, so it stays literal.
        assert_eq!(
            render("{{OUTER}}", &[("OUTER", "{{INNER}}"), ("INNER", "x")]),
            "{{INNER}}"
        );
    }
}
