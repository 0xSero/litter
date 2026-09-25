//! Per-connection memo of remote runtime detection results.
//!
//! Every connect used to re-run the same probes over SSH: shell detection
//! (two execs, repeated at every call site), codex binary lookup,
//! `app-server proxy/daemon --help`, `codex --version`, the agent probe
//! script (which spawns `<agent> --version` for several agents), CLI path
//! lookups, `opencode --version`, and the OMP home lookup. Each one is a
//! serial SSH exec round trip.
//!
//! [`SshDetection`] memoizes those results on the [`super::SshClient`] for
//! the lifetime of the connection, and is serializable so the reconnect
//! path can seed it from the persisted per-server cache
//! (`crate::ssh_detect_cache`) and skip the probes entirely.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::{RemoteShell, SshClient};
use crate::ssh_bridge::RemoteAgentAvailability;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct SshDetection {
    #[serde(default)]
    pub shell: Option<RemoteShell>,
    #[serde(default)]
    pub codex_path: Option<String>,
    #[serde(default)]
    pub codex_version: Option<String>,
    #[serde(default)]
    pub app_server_proxy_supported: Option<bool>,
    #[serde(default)]
    pub app_server_daemon_supported: Option<bool>,
    #[serde(default)]
    pub agents: Option<Vec<RemoteAgentAvailability>>,
    /// Resolved CLI path keyed by the newline-joined candidate list.
    #[serde(default)]
    pub cli_paths: BTreeMap<String, String>,
    /// CLI paths that answered `--version` successfully.
    #[serde(default)]
    pub validated_clis: Vec<String>,
    #[serde(default)]
    pub omp_agent_dir: Option<String>,
}

impl SshDetection {
    pub(crate) fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

pub(crate) fn cli_key(candidates: &[String]) -> String {
    candidates.join("\n")
}

impl SshClient {
    /// Snapshot of everything detected (or seeded) on this connection.
    pub(crate) fn detection_snapshot(&self) -> SshDetection {
        self.detection
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// Seed the memo from a persisted cache entry. Returns whether anything
    /// was seeded.
    pub(crate) fn seed_detection(&self, detection: SshDetection) -> bool {
        let seeded = !detection.is_empty();
        *self
            .detection
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = detection;
        seeded
    }

    /// Forget every memoized result so the next caller re-probes.
    pub(crate) fn clear_detection(&self) {
        self.seed_detection(SshDetection::default());
    }

    pub(crate) fn with_detection<R>(&self, f: impl FnOnce(&mut SshDetection) -> R) -> R {
        let mut guard = self
            .detection
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut guard)
    }
}
