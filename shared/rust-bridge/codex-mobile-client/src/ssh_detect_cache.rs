//! Persisted per-server SSH detection cache.
//!
//! Reconnecting a saved SSH server used to re-run the full remote
//! agent/runtime detection (shell probe, agent probe script that spawns
//! `<agent> --version`, CLI lookups, `opencode --version`, codex binary and
//! capability checks). Those results almost never change between launches,
//! so they are stored here after a successful connect and seeded into the
//! next connection's [`crate::ssh::SshDetection`] memo.
//!
//! Entries are keyed by server id and only honored when the host identity
//! (normalized host, SSH port, username, and the host-key fingerprint seen on
//! this connection) matches, so a re-pointed hostname or a rotated host key
//! never reuses stale paths. The file lives next to the mobile preferences
//! and holds only paths/versions/flags, never credentials.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::ssh::SshDetection;

const CACHE_FILE: &str = "ssh_detect_cache.json";
const CURRENT_VERSION: u32 = 1;
const MAX_ENTRIES: usize = 64;

static LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CacheKey {
    pub server_id: String,
    pub identity: String,
}

impl CacheKey {
    pub(crate) fn new(
        server_id: &str,
        host: &str,
        port: u16,
        username: &str,
        fingerprint: Option<&str>,
    ) -> Option<Self> {
        // Without an observed host key there is no identity to bind to.
        let fingerprint = fingerprint?.trim();
        if fingerprint.is_empty() || server_id.is_empty() {
            return None;
        }
        Some(Self {
            server_id: server_id.to_string(),
            identity: format!(
                "{}:{port}|{username}|{fingerprint}",
                crate::terminal::normalize_host(host)
            ),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Entry {
    identity: String,
    saved_at_ms: i64,
    detection: SshDetection,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Persisted {
    version: u32,
    entries: BTreeMap<String, Entry>,
}

fn cache_path(directory: &str) -> PathBuf {
    PathBuf::from(directory).join(CACHE_FILE)
}

fn read(path: &Path) -> Persisted {
    let Ok(bytes) = fs::read(path) else {
        return Persisted::default();
    };
    match serde_json::from_slice::<Persisted>(&bytes) {
        Ok(p) if p.version == CURRENT_VERSION => p,
        _ => Persisted::default(),
    }
}

fn write(path: &Path, mut value: Persisted) {
    value.version = CURRENT_VERSION;
    if value.entries.len() > MAX_ENTRIES {
        let mut by_age = value
            .entries
            .iter()
            .map(|(k, e)| (e.saved_at_ms, k.clone()))
            .collect::<Vec<_>>();
        by_age.sort();
        let excess = value.entries.len() - MAX_ENTRIES;
        for (_, key) in by_age.into_iter().take(excess) {
            value.entries.remove(&key);
        }
    }
    let Some(parent) = path.parent() else { return };
    if let Err(e) = fs::create_dir_all(parent) {
        tracing::warn!(error = %e, "ssh detect cache: create dir failed");
        return;
    }
    let Ok(json) = serde_json::to_vec(&value) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    let ok = fs::File::create(&tmp)
        .and_then(|mut f| f.write_all(&json))
        .is_ok();
    if !ok || fs::rename(&tmp, path).is_err() {
        tracing::warn!("ssh detect cache: write failed");
        let _ = fs::remove_file(&tmp);
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

/// Cached detection for `key`, if one exists for the same host identity.
pub(crate) fn load(directory: &str, key: &CacheKey) -> Option<SshDetection> {
    let _guard = LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let entry = read(&cache_path(directory))
        .entries
        .remove(&key.server_id)?;
    (entry.identity == key.identity && !entry.detection.is_empty()).then_some(entry.detection)
}

/// Store (replace) the detection for `key`. Empty detections are ignored.
pub(crate) fn store(directory: &str, key: &CacheKey, detection: &SshDetection) {
    if detection.is_empty() {
        return;
    }
    let _guard = LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let path = cache_path(directory);
    let mut persisted = read(&path);
    persisted.entries.insert(
        key.server_id.clone(),
        Entry {
            identity: key.identity.clone(),
            saved_at_ms: now_ms(),
            detection: detection.clone(),
        },
    );
    write(&path, persisted);
}

/// Drop the entry for `server_id` (e.g. a launch with cached paths failed).
pub(crate) fn invalidate(directory: &str, server_id: &str) {
    let _guard = LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let path = cache_path(directory);
    let mut persisted = read(&path);
    if persisted.entries.remove(server_id).is_some() {
        write(&path, persisted);
    }
}

/// Reconnect-side handle: seeds a connection from the cache, persists what
/// the connection detected, revalidates in the background, and invalidates
/// when a launch that used cached results fails.
pub(crate) struct DetectionCacheSession {
    directory: String,
    key: CacheKey,
    seeded: bool,
}

impl DetectionCacheSession {
    /// Seed `ssh` from the cache. `None` when there is no preferences
    /// directory or no host identity (the connect then behaves exactly as a
    /// first-ever connect).
    pub(crate) fn begin(
        directory: Option<String>,
        key: Option<CacheKey>,
        ssh: &crate::ssh::SshClient,
    ) -> Option<Self> {
        let directory = directory.filter(|d| !d.is_empty())?;
        let key = key?;
        let seeded = match load(&directory, &key) {
            Some(detection) => ssh.seed_detection(detection),
            None => false,
        };
        tracing::info!(server_id = %key.server_id, seeded, "ssh detect cache: begin");
        Some(Self {
            directory,
            key,
            seeded,
        })
    }

    /// A connect that ran on cached results failed: drop the entry, clear
    /// the connection memo, and report whether the caller should re-probe
    /// and retry once. Returns `false` when nothing was cached (the failure
    /// is genuine, not a stale cache).
    pub(crate) fn on_failure(&mut self, ssh: &crate::ssh::SshClient) -> bool {
        if !self.seeded {
            return false;
        }
        tracing::warn!(
            server_id = %self.key.server_id,
            "ssh detect cache: connect with cached detection failed; re-probing once"
        );
        invalidate(&self.directory, &self.key.server_id);
        ssh.clear_detection();
        self.seeded = false;
        true
    }

    /// Persist what the connection detected. When the connect was served
    /// from cache, re-probe in the background (stale-while-revalidate) so
    /// the next reconnect sees changes such as a newly installed agent.
    pub(crate) fn on_success(self, ssh: std::sync::Arc<crate::ssh::SshClient>) {
        let snapshot = ssh.detection_snapshot();
        store(&self.directory, &self.key, &snapshot);
        if !self.seeded {
            return;
        }
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        handle.spawn(async move {
            let fresh = crate::ssh_bridge::revalidate_detection(&ssh, &snapshot).await;
            if !ssh.is_connected() {
                return;
            }
            let merged = merge_revalidated(&snapshot, fresh);
            if merged != snapshot {
                tracing::info!(
                    server_id = %self.key.server_id,
                    "ssh detect cache: background revalidation updated entry"
                );
            }
            store(&self.directory, &self.key, &merged);
        });
    }
}

/// Fresh values win; a probe that produced nothing (transient failure) keeps
/// the previous value rather than erasing it. Genuine removals are caught by
/// the launch-failure invalidation path instead.
pub(crate) fn merge_revalidated(previous: &SshDetection, fresh: SshDetection) -> SshDetection {
    let mut cli_paths = previous.cli_paths.clone();
    cli_paths.extend(fresh.cli_paths);
    let validated_clis = if fresh.validated_clis.is_empty() {
        previous.validated_clis.clone()
    } else {
        fresh.validated_clis
    };
    SshDetection {
        shell: fresh.shell.or(previous.shell),
        codex_path: fresh.codex_path.or_else(|| previous.codex_path.clone()),
        codex_version: fresh
            .codex_version
            .or_else(|| previous.codex_version.clone()),
        app_server_proxy_supported: fresh
            .app_server_proxy_supported
            .or(previous.app_server_proxy_supported),
        app_server_daemon_supported: fresh
            .app_server_daemon_supported
            .or(previous.app_server_daemon_supported),
        agents: fresh.agents.or_else(|| previous.agents.clone()),
        cli_paths,
        validated_clis,
        omp_agent_dir: fresh
            .omp_agent_dir
            .or_else(|| previous.omp_agent_dir.clone()),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn merge_prefers_fresh_but_keeps_previous_on_missing() {
        let previous = sample();
        let mut fresh = SshDetection {
            shell: Some(RemoteShell::Posix),
            codex_version: Some("codex 9.9.9".into()),
            agents: Some(Vec::new()),
            ..Default::default()
        };
        fresh
            .cli_paths
            .insert("claude".into(), "/bin/claude".into());
        let merged = merge_revalidated(&previous, fresh);
        assert_eq!(merged.codex_version.as_deref(), Some("codex 9.9.9"));
        assert_eq!(merged.codex_path, previous.codex_path);
        assert_eq!(merged.agents, Some(Vec::new()));
        assert_eq!(merged.cli_paths.len(), 2);
        assert_eq!(merged.validated_clis, previous.validated_clis);
        assert_eq!(merged.omp_agent_dir, previous.omp_agent_dir);
    }

    use super::*;
    use crate::ssh::RemoteShell;
    use crate::ssh_bridge::{AgentAvailabilityStatus, RemoteAgentAvailability};

    fn sample() -> SshDetection {
        let mut d = SshDetection {
            shell: Some(RemoteShell::Posix),
            codex_path: Some("/usr/local/bin/codex".into()),
            codex_version: Some("codex 1.2.3".into()),
            app_server_proxy_supported: Some(true),
            app_server_daemon_supported: Some(false),
            agents: Some(vec![RemoteAgentAvailability {
                kind: "opencode".into(),
                status: AgentAvailabilityStatus::Available,
            }]),
            validated_clis: vec!["/opt/bin/opencode".into()],
            omp_agent_dir: Some("/home/u/.omp/agent".into()),
            ..Default::default()
        };
        d.cli_paths
            .insert("opencode".into(), "/opt/bin/opencode".into());
        d
    }

    fn key(fp: &str) -> CacheKey {
        CacheKey::new("srv", "Box.Local", 22, "me", Some(fp)).unwrap()
    }

    #[test]
    fn round_trips_detection_for_matching_identity() {
        let dir = tempfile::tempdir().unwrap();
        let dir = dir.path().to_string_lossy().to_string();
        assert!(load(&dir, &key("FP")).is_none());
        store(&dir, &key("FP"), &sample());
        assert_eq!(load(&dir, &key("FP")), Some(sample()));
        // Host identity is case-normalized.
        let other_case = CacheKey::new("srv", "box.local", 22, "me", Some("FP")).unwrap();
        assert_eq!(load(&dir, &other_case), Some(sample()));
    }

    #[test]
    fn identity_mismatch_misses() {
        let dir = tempfile::tempdir().unwrap();
        let dir = dir.path().to_string_lossy().to_string();
        store(&dir, &key("FP"), &sample());
        assert!(load(&dir, &key("ROTATED")).is_none());
        let other_user = CacheKey::new("srv", "box.local", 22, "root", Some("FP")).unwrap();
        assert!(load(&dir, &other_user).is_none());
        let other_port = CacheKey::new("srv", "box.local", 2222, "me", Some("FP")).unwrap();
        assert!(load(&dir, &other_port).is_none());
    }

    #[test]
    fn invalidate_and_bad_files() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().to_string_lossy().to_string();
        store(&d, &key("FP"), &sample());
        invalidate(&d, "srv");
        assert!(load(&d, &key("FP")).is_none());
        fs::write(dir.path().join(CACHE_FILE), b"garbage").unwrap();
        assert!(load(&d, &key("FP")).is_none());
        store(&d, &key("FP"), &SshDetection::default());
        assert!(load(&d, &key("FP")).is_none());
    }

    #[test]
    fn no_key_without_fingerprint() {
        assert!(CacheKey::new("srv", "h", 22, "u", None).is_none());
        assert!(CacheKey::new("srv", "h", 22, "u", Some(" ")).is_none());
    }

    #[test]
    fn caps_entries() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().to_string_lossy().to_string();
        for i in 0..(MAX_ENTRIES + 5) {
            let k = CacheKey::new(&format!("s{i}"), "h", 22, "u", Some("FP")).unwrap();
            store(&d, &k, &sample());
        }
        assert_eq!(read(&cache_path(&d)).entries.len(), MAX_ENTRIES);
    }
}
