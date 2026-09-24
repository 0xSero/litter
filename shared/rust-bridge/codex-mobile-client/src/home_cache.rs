//! Launch cache for the home screen's recent sessions.
//!
//! On cold launch the store starts empty and session rows only appear after
//! every server reconnects and lists its threads, which can take many
//! seconds. This module persists a small, versioned copy of the most recent
//! session summaries so the first snapshot can show them immediately.
//!
//! Cached rows are a projection overlay, not canonical store threads: they
//! live in `AppSnapshot::cached_session_summaries`, are shadowed by any live
//! thread with the same key, and are dropped per server once that server
//! completes an authoritative thread listing.
//!
//! Only display metadata is stored (titles, cwd, model, timestamps, lineage);
//! message bodies, tool logs, and credentials never are.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::store::boundary::{AppSessionSummary, empty_session_summary};
use crate::types::ThreadKey;

const CACHE_FILE: &str = "home_sessions_cache.json";
const CURRENT_VERSION: u32 = 1;
/// Enough to fill the home list on any screen size, small enough to keep
/// the file a few kilobytes.
pub(crate) const MAX_CACHED_SESSIONS: usize = 60;

static WRITE_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct CachedSession {
    server_id: String,
    thread_id: String,
    agent_runtime_kind: String,
    server_display_name: String,
    server_host: String,
    title: String,
    preview: String,
    cwd: String,
    model: String,
    model_provider: String,
    updated_at: Option<i64>,
    parent_thread_id: Option<String>,
    forked_from_id: Option<String>,
    agent_display_label: Option<String>,
    is_subagent: bool,
    is_fork: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct PersistedCache {
    version: u32,
    sessions: Vec<CachedSession>,
}

impl From<&AppSessionSummary> for CachedSession {
    fn from(summary: &AppSessionSummary) -> Self {
        Self {
            server_id: summary.key.server_id.clone(),
            thread_id: summary.key.thread_id.clone(),
            agent_runtime_kind: summary.agent_runtime_kind.clone(),
            server_display_name: summary.server_display_name.clone(),
            server_host: summary.server_host.clone(),
            title: summary.title.clone(),
            preview: summary.preview.clone(),
            cwd: summary.cwd.clone(),
            model: summary.model.clone(),
            model_provider: summary.model_provider.clone(),
            updated_at: summary.updated_at,
            parent_thread_id: summary.parent_thread_id.clone(),
            forked_from_id: summary.forked_from_id.clone(),
            agent_display_label: summary.agent_display_label.clone(),
            is_subagent: summary.is_subagent,
            is_fork: summary.is_fork,
        }
    }
}

impl From<CachedSession> for AppSessionSummary {
    fn from(cached: CachedSession) -> Self {
        let mut summary = empty_session_summary(ThreadKey {
            server_id: cached.server_id,
            thread_id: cached.thread_id,
        });
        summary.agent_runtime_kind = cached.agent_runtime_kind;
        summary.server_display_name = cached.server_display_name;
        summary.server_host = cached.server_host;
        summary.title = cached.title;
        summary.preview = cached.preview;
        summary.cwd = cached.cwd;
        summary.model = cached.model;
        summary.model_provider = cached.model_provider;
        summary.updated_at = cached.updated_at;
        summary.parent_thread_id = cached.parent_thread_id;
        summary.forked_from_id = cached.forked_from_id;
        summary.agent_display_label = cached.agent_display_label;
        summary.is_subagent = cached.is_subagent;
        summary.is_fork = cached.is_fork;
        summary
    }
}

fn cache_path(directory: &str) -> PathBuf {
    PathBuf::from(directory).join(CACHE_FILE)
}

/// Load cached summaries. Missing, corrupt, or other-version files yield an
/// empty list; the cache is rebuilt after the next authoritative listing.
pub(crate) fn load(directory: &str) -> Vec<AppSessionSummary> {
    load_at(&cache_path(directory))
}

fn load_at(path: &Path) -> Vec<AppSessionSummary> {
    let Ok(bytes) = fs::read(path) else {
        return Vec::new();
    };
    match serde_json::from_slice::<PersistedCache>(&bytes) {
        Ok(cache) if cache.version == CURRENT_VERSION => cache
            .sessions
            .into_iter()
            .take(MAX_CACHED_SESSIONS)
            .map(AppSessionSummary::from)
            .collect(),
        Ok(_) | Err(_) => Vec::new(),
    }
}

/// Persist the most recent summaries (callers pass them already sorted by
/// recency). Writes atomically via a temp file and rename.
pub(crate) fn save(directory: &str, summaries: &[AppSessionSummary]) {
    save_at(&cache_path(directory), summaries);
}

fn save_at(path: &Path, summaries: &[AppSessionSummary]) {
    let _guard = WRITE_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(parent) = path.parent() else { return };
    if let Err(e) = fs::create_dir_all(parent) {
        tracing::warn!(error = %e, "home cache: create dir failed");
        return;
    }
    let persisted = PersistedCache {
        version: CURRENT_VERSION,
        sessions: summaries
            .iter()
            .take(MAX_CACHED_SESSIONS)
            .map(CachedSession::from)
            .collect(),
    };
    let json = match serde_json::to_vec(&persisted) {
        Ok(bytes) => bytes,
        Err(e) => {
            tracing::warn!(error = %e, "home cache: serialize failed");
            return;
        }
    };
    let tmp_path = path.with_extension("json.tmp");
    match fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp_path)
    {
        Ok(mut file) => {
            if let Err(e) = file.write_all(&json) {
                tracing::warn!(error = %e, "home cache: write failed");
                let _ = fs::remove_file(&tmp_path);
                return;
            }
        }
        Err(e) => {
            tracing::warn!(error = %e, "home cache: open tmp failed");
            return;
        }
    }
    if let Err(e) = fs::rename(&tmp_path, path) {
        tracing::warn!(error = %e, "home cache: rename failed");
        let _ = fs::remove_file(&tmp_path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(server: &str, thread: &str, title: &str, updated_at: i64) -> AppSessionSummary {
        let mut s = empty_session_summary(ThreadKey {
            server_id: server.to_string(),
            thread_id: thread.to_string(),
        });
        s.title = title.to_string();
        s.updated_at = Some(updated_at);
        s.cwd = "/work/litter".to_string();
        s.last_user_message = Some("secret prompt".to_string());
        s
    }

    #[test]
    fn round_trips_display_fields_and_drops_message_bodies() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(CACHE_FILE);
        save_at(&path, &[summary("studio", "t1", "Fix launch", 20)]);

        let loaded = load_at(&path);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].key.server_id, "studio");
        assert_eq!(loaded[0].title, "Fix launch");
        assert_eq!(loaded[0].cwd, "/work/litter");
        assert_eq!(loaded[0].updated_at, Some(20));
        assert_eq!(loaded[0].last_user_message, None);
        let raw = fs::read_to_string(&path).unwrap();
        assert!(!raw.contains("secret prompt"));
    }

    #[test]
    fn caps_entries_and_ignores_missing_corrupt_or_future_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(CACHE_FILE);
        assert!(load_at(&path).is_empty());

        let many: Vec<_> = (0..(MAX_CACHED_SESSIONS as i64 + 10))
            .map(|i| summary("studio", &format!("t{i}"), "x", i))
            .collect();
        save_at(&path, &many);
        assert_eq!(load_at(&path).len(), MAX_CACHED_SESSIONS);

        fs::write(&path, b"not json").unwrap();
        assert!(load_at(&path).is_empty());

        fs::write(&path, br#"{"version":99,"sessions":[]}"#).unwrap();
        assert!(load_at(&path).is_empty());
    }
}
