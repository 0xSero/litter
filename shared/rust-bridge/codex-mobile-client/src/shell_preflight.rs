//! Normalize local mobile shell argv before the local codex shell tool
//! forks/execs.
//!
//! Android app sandboxes have no real `/tmp` — attempts to `cat /tmp/foo`
//! or `echo x > /tmp/foo` hit `ENOENT/EACCES`. But model-emitted shell
//! commands routinely hardcode `/tmp/...` paths, so Android rewrites those
//! tokens to its real app temp dir.
//!
//! - Well-behaved tools pick up `$TMPDIR`, which each platform sets at boot
//!   (Android: `filesDir/litter-tmp`; iOS iSH commands get `TMPDIR=/tmp`).
//! - Literal `/tmp` and `/tmp/*` Android path tokens in argv, including
//!   inside recognized shell-wrapper scripts, are rewritten here to the
//!   `$TMPDIR` target so `cat /tmp/foo` ends up reading the real temp.
//!
//! iOS is intentionally excluded from `/tmp` rewriting. Its local shell runs
//! inside iSH's Alpine fakefs, where `/tmp` is a real writable fakefs path.
//! Rewriting it to the native iOS container TMPDIR produces paths that iSH
//! cannot traverse.
//!
//! Only mutates exact `/tmp` and `/tmp/...` absolute path boundaries. Other
//! absolute paths pass through unchanged. Only fires for **local** codex shell
//! invocations — SSH/WebSocket remote execution never enters this function.

use codex_shell_command::parse_command::extract_shell_command;
use std::path::Path;

/// Normalize argv for the mobile local executor. This is installed as the
/// single preflight hook called by upstream Codex immediately before exec.
pub(crate) fn prepare_mobile_exec_argv(argv: &mut Vec<String>) {
    prepare_mobile_exec_argv_inner(argv, should_rewrite_tmp_paths_for_platform());
}

fn prepare_mobile_exec_argv_inner(argv: &mut Vec<String>, rewrite_tmp_paths_enabled: bool) {
    normalize_shell_invocation(argv);
    if rewrite_tmp_paths_enabled {
        rewrite_tmp_paths(argv);
    }
}

#[cfg(target_os = "android")]
fn should_rewrite_tmp_paths_for_platform() -> bool {
    true
}

#[cfg(not(target_os = "android"))]
fn should_rewrite_tmp_paths_for_platform() -> bool {
    false
}

fn normalize_shell_invocation(argv: &mut Vec<String>) {
    let Some((_, script)) = extract_shell_command(argv) else {
        return;
    };
    // Reuse the same shell-wrapper parser used for command display, then run
    // the extracted script through the bundled mobile `sh -c`. iSH's
    // /bin/sh supports `-c` like any POSIX shell.
    *argv = vec!["sh".to_string(), "-c".to_string(), script.to_string()];
}

/// Walk argv; rewrite any token that equals `/tmp` or starts with `/tmp/`
/// to the platform's real tmp root (from `$TMPDIR`). No-op if `$TMPDIR`
/// is unset.
pub(crate) fn rewrite_tmp_paths(argv: &mut [String]) {
    let Some(real_tmp) = std::env::var_os("TMPDIR") else {
        return;
    };
    let real_tmp = Path::new(&real_tmp);
    // Trim trailing slash so joining `tmp/"a.txt"` and `tmp/"/a.txt"` both
    // produce a clean `tmp/a.txt`.
    let trimmed: &str = real_tmp
        .to_str()
        .map(|s| s.trim_end_matches('/'))
        .unwrap_or_default();
    if trimmed.is_empty() {
        return;
    }
    for token in argv.iter_mut() {
        if let Some(rewritten) = rewrite_tmp_boundaries(token, trimmed) {
            *token = rewritten;
        }
    }

    if argv.len() >= 3
        && extract_shell_command(argv).is_some()
        && let Some(rewritten) = rewrite_tmp_boundaries(&argv[2], trimmed)
    {
        argv[2] = rewritten;
    }
}

fn rewrite_tmp_boundaries(value: &str, real_tmp: &str) -> Option<String> {
    let mut rewritten = String::with_capacity(value.len());
    let mut changed = false;
    let mut index = 0;
    while index < value.len() {
        let rest = &value[index..];
        let prev_is_path = index > 0
            && value
                .as_bytes()
                .get(index - 1)
                .is_some_and(|prev| is_path_component_continuation(*prev));
        if !prev_is_path
            && rest.starts_with("/tmp")
            && rest
                .as_bytes()
                .get(4)
                .is_none_or(|next| *next == b'/' || !is_path_component_continuation(*next))
        {
            rewritten.push_str(real_tmp);
            index += 4;
            changed = true;
        } else {
            let ch = rest.chars().next().expect("non-empty rest");
            rewritten.push(ch);
            index += ch.len_utf8();
        }
    }

    changed.then_some(rewritten)
}

fn is_path_component_continuation(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.')
}

/// Install the mobile exec preflight. Safe to call multiple times; the
/// underlying `OnceLock` accepts only the first registration.
#[cfg(any(
    all(target_os = "ios", not(target_abi = "macabi")),
    target_os = "android"
))]
pub fn install() {
    codex_core::exec::set_mobile_exec_preflight(prepare_mobile_exec_argv);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_tmpdir<F: FnOnce()>(value: &str, f: F) {
        let _guard = ENV_LOCK.lock().expect("env lock poisoned");
        // SAFETY: tests are single-threaded within this module.
        unsafe {
            std::env::set_var("TMPDIR", value);
        }
        f();
        unsafe {
            std::env::remove_var("TMPDIR");
        }
    }

    #[test]
    fn rewrites_exact_slash_tmp() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec!["cat".into(), "/tmp".into()];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(argv, vec!["cat".to_string(), "/real/tmp".to_string()]);
        });
    }

    #[test]
    fn rewrites_slash_tmp_prefix() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec!["cat".into(), "/tmp/a.txt".into()];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(argv, vec!["cat".to_string(), "/real/tmp/a.txt".to_string()]);
        });
    }

    #[test]
    fn does_not_rewrite_slash_tmpfoo_boundary() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec!["cat".into(), "/tmpfoo".into()];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(argv, vec!["cat".to_string(), "/tmpfoo".to_string()]);
        });
    }

    #[test]
    fn rewrites_slash_tmp_inside_shell_script() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec![
                "sh".into(),
                "-c".into(),
                "test -d /tmp && printf ok > /tmp/file".into(),
            ];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(
                argv,
                vec![
                    "sh".to_string(),
                    "-c".to_string(),
                    "test -d /real/tmp && printf ok > /real/tmp/file".to_string(),
                ]
            );
        });
    }

    #[test]
    fn does_not_rewrite_slash_tmpfoo_inside_shell_script() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec!["sh".into(), "-c".into(), "printf /tmpfoo".into()];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(
                argv,
                vec![
                    "sh".to_string(),
                    "-c".to_string(),
                    "printf /tmpfoo".to_string(),
                ]
            );
        });
    }

    #[test]
    fn does_not_rewrite_non_root_tmp_path_inside_shell_script() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec!["sh".into(), "-c".into(), "printf /var/tmp".into()];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(
                argv,
                vec![
                    "sh".to_string(),
                    "-c".to_string(),
                    "printf /var/tmp".to_string(),
                ]
            );
        });
    }

    #[test]
    fn normalizes_login_shell_to_plain_sh_c() {
        let mut argv = vec!["/bin/zsh".into(), "-lc".into(), "echo hello".into()];
        prepare_mobile_exec_argv(&mut argv);
        assert_eq!(
            argv,
            vec!["sh".to_string(), "-c".to_string(), "echo hello".to_string()]
        );
    }

    #[test]
    fn normalizes_bash_wrapper_with_same_parser_as_display_command() {
        let mut argv = vec!["/bin/bash".into(), "-lc".into(), "echo hello".into()];
        prepare_mobile_exec_argv(&mut argv);
        assert_eq!(
            argv,
            vec!["sh".to_string(), "-c".to_string(), "echo hello".to_string()]
        );
    }

    #[test]
    fn prepare_can_leave_slash_tmp_for_ish_fakefs() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec![
                "sh".into(),
                "-c".into(),
                "printf ok > /tmp/preflight-test".into(),
            ];
            prepare_mobile_exec_argv_inner(&mut argv, false);
            assert_eq!(
                argv,
                vec![
                    "sh".to_string(),
                    "-c".to_string(),
                    "printf ok > /tmp/preflight-test".to_string(),
                ]
            );
        });
    }

    #[test]
    fn prepare_rewrites_slash_tmp_when_enabled_for_android() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec![
                "sh".into(),
                "-c".into(),
                "printf ok > /tmp/preflight-test".into(),
            ];
            prepare_mobile_exec_argv_inner(&mut argv, true);
            assert_eq!(
                argv,
                vec![
                    "sh".to_string(),
                    "-c".to_string(),
                    "printf ok > /real/tmp/preflight-test".to_string(),
                ]
            );
        });
    }

    #[test]
    fn preserves_tokens_without_slash_tmp() {
        with_tmpdir("/real/tmp", || {
            let mut argv = vec!["cat".into(), "/var/log/foo".into(), "-n".into()];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(
                argv,
                vec![
                    "cat".to_string(),
                    "/var/log/foo".to_string(),
                    "-n".to_string(),
                ]
            );
        });
    }

    #[test]
    fn noop_when_tmpdir_unset() {
        let _guard = ENV_LOCK.lock().expect("env lock poisoned");
        // Defensive: ensure removal.
        unsafe {
            std::env::remove_var("TMPDIR");
        }
        let original = vec!["cat".to_string(), "/tmp/x".to_string()];
        let mut argv = original.clone();
        rewrite_tmp_paths(&mut argv);
        assert_eq!(argv, original);
    }

    #[test]
    fn empty_argv_is_fine() {
        with_tmpdir("/real/tmp", || {
            let mut argv: Vec<String> = Vec::new();
            rewrite_tmp_paths(&mut argv);
            assert!(argv.is_empty());
        });
    }

    #[test]
    fn strips_trailing_slash_on_tmpdir() {
        with_tmpdir("/real/tmp/", || {
            let mut argv = vec!["cat".into(), "/tmp/a.txt".into()];
            rewrite_tmp_paths(&mut argv);
            assert_eq!(argv, vec!["cat".to_string(), "/real/tmp/a.txt".to_string()]);
        });
    }
}
