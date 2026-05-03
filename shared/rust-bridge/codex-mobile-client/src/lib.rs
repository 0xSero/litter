//! Shared mobile client library for iOS / Android.
//!
//! This crate owns the single public UniFFI surface for mobile. Keep shared
//! business logic here so Swift/Kotlin only compile one binding set.

#[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
pub mod ish_exec;

#[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
pub mod ish_runtime;

// Always-compiled UniFFI-visible types. The host cdylib that
// `generate-bindings.sh` feeds to uniffi-bindgen must contain these so the
// generated Swift/Kotlin has `IshRunResult` / `IshBootstrapError` /
// `ishBootstrap` / `ishDefaultCwd` / `ishRun` symbols on every lane.
pub mod ish_types;

pub use ish_types::{IshBootstrapError, IshRunResult};

/// One-time iSH bootstrap. Swift passes the bundle's `fs/` resource dir, the
/// app's Application Support dir, and the Documents dir; Rust does the
/// rootfs extraction, boot, and exec-hook registration. Replaces the old
/// `codex_ish_init` + `litter_install_ish_hook` C entry points.
///
/// Non-iOS targets (Catalyst, Android, host bindgen) return
/// `IshBootstrapError::Unsupported` — the kernel is iOS-only and not linked
/// into those builds.
#[uniffi::export]
pub fn ish_bootstrap(
    bundle_fs_path: String,
    application_support_dir: String,
    documents_dir: String,
) -> Result<(), IshBootstrapError> {
    #[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
    {
        return ish_runtime::bootstrap(
            std::path::Path::new(&bundle_fs_path),
            std::path::Path::new(&application_support_dir),
            std::path::Path::new(&documents_dir),
        );
    }
    #[cfg(not(all(target_os = "ios", not(target_abi = "macabi"))))]
    {
        let _ = (bundle_fs_path, application_support_dir, documents_dir);
        Err(IshBootstrapError::Unsupported {
            detail: "iSH is iOS-only".into(),
        })
    }
}

/// Default working directory for iSH-backed local sessions. Always `/root`
/// (the standard Alpine home for the root user inside the fakefs). Safe to
/// call on every platform — it's a pure constant.
#[uniffi::export]
pub fn ish_default_cwd() -> String {
    "/root".to_string()
}

/// Run `cmd` through the persistent iSH `/bin/sh`. An empty `cwd` means "no
/// cd wrapping" (run in the kernel's current dir). Output is merged
/// stdout+stderr; `exit_code` is the process exit code, or a negative
/// `ISH_E_*` value if dispatch failed.
///
/// Non-iOS targets return `exit_code = -1` and a stub "unsupported on this
/// platform" message so Swift callers can uniformly handle the failure.
#[uniffi::export]
pub fn ish_run(cmd: String, cwd: String) -> IshRunResult {
    #[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
    {
        let cwd_opt = if cwd.is_empty() {
            None
        } else {
            Some(cwd.as_str())
        };
        let (exit_code, output) = ish_runtime::run(&cmd, cwd_opt, None);
        return IshRunResult { exit_code, output };
    }
    #[cfg(not(all(target_os = "ios", not(target_abi = "macabi"))))]
    {
        let _ = (cmd, cwd);
        IshRunResult {
            exit_code: -1,
            output: b"unsupported on this platform\n".to_vec(),
        }
    }
}

#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
mod mobile_exec_command;
mod shell_quoting;
pub(crate) mod ssh_scripts;

#[cfg(target_os = "android")]
mod android_context;
#[cfg(target_os = "android")]
pub mod android_exec;

#[cfg(any(
    all(target_os = "ios", not(target_abi = "macabi")),
    target_os = "android",
    test
))]
pub mod shell_preflight;

pub mod alleycat;
pub mod ambient_suggestions;
pub mod capability;
pub mod cloud_sync;
pub mod conversation;
pub mod conversation_uniffi;
pub mod discovery;
pub mod discovery_uniffi;
pub mod ffi;
pub mod hydration;
pub mod immer_patch;
mod local_runtime_instructions;
pub mod local_server;
pub mod logging;
pub mod markdown_blocks;
mod mobile_client;
pub mod pair;
pub mod parser;
pub mod permissions;
pub mod pets;
pub mod plugin_refs;
pub mod preferences;
pub mod project;
pub mod reconnect;
pub mod recorder;
pub mod remote_path;
pub mod saved_apps;
pub mod session;
pub mod ssh;
pub mod ssh_bridge;
pub mod ssh_detached_launcher;
pub mod ssh_launcher;
pub mod store;
pub mod transport;
pub mod types;
pub mod widget_guidelines;

pub use mobile_client::*;

// ── Shared infra ─────────────────────────────────────────────────────────

use std::sync::atomic::{AtomicI64, Ordering};

static REQUEST_COUNTER: AtomicI64 = AtomicI64::new(1);
pub(crate) const MOBILE_ASYNC_THREAD_STACK_SIZE_BYTES: usize = 4 * 1024 * 1024;

pub(crate) fn next_request_id() -> i64 {
    REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed)
}

#[derive(Debug, thiserror::Error)]
pub enum RpcClientError {
    #[error("RPC: {0}")]
    Rpc(String),
    #[error("Serialization: {0}")]
    Serialization(String),
}

uniffi::setup_scaffolding!();
