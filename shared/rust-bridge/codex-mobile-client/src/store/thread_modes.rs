//! Bounded, mobile-owned persistence for per-thread collaboration modes.
//!
//! The pinned app-server protocol does not expose collaboration mode on
//! `thread/list`, `thread/read`, `thread/resume`, or lifecycle notifications.
//! Until it does, mobile cannot authoritatively recover that state after a
//! process restart. This store persists only non-default modes, keyed by the
//! existing mobile [`ThreadKey`], and caps stale entries so it cannot grow
//! without bound.
//!
//! This fallback cannot observe mode changes made by another client and will
//! miss if a server is later registered under a different `server_id`. An
//! upstream thread metadata field should supersede this local value once one
//! is available.

use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::types::{AppModeKind, ThreadKey};

const THREAD_MODES_FILE: &str = "thread_modes.json";
const CURRENT_VERSION: u32 = 1;
const MAX_PERSISTED_THREAD_MODES: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedThreadMode {
    server_id: String,
    thread_id: String,
    mode: AppModeKind,
}

impl PersistedThreadMode {
    fn key(&self) -> ThreadKey {
        ThreadKey {
            server_id: self.server_id.clone(),
            thread_id: self.thread_id.clone(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedThreadModes {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    modes: Vec<PersistedThreadMode>,
}

#[derive(Default)]
struct ThreadModeState {
    path: Option<PathBuf>,
    modes: Vec<PersistedThreadMode>,
}

#[derive(Default)]
pub(super) struct ThreadModeStore {
    state: Mutex<ThreadModeState>,
}

impl ThreadModeStore {
    pub(super) fn configure(&self, directory: &str) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let trimmed = directory.trim();
        if trimmed.is_empty() {
            *state = ThreadModeState::default();
            return;
        }

        let path = PathBuf::from(trimmed).join(THREAD_MODES_FILE);
        let mut modes = read_thread_modes(&path).modes;
        normalize_modes(&mut modes);
        *state = ThreadModeState {
            path: Some(path),
            modes,
        };
    }

    pub(super) fn mode_for(&self, key: &ThreadKey) -> Option<AppModeKind> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state
            .modes
            .iter()
            .rev()
            .find(|entry| entry.server_id == key.server_id && entry.thread_id == key.thread_id)
            .map(|entry| entry.mode)
    }

    pub(super) fn set_mode(&self, key: &ThreadKey, mode: AppModeKind) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(path) = state.path.clone() else {
            return;
        };

        state
            .modes
            .retain(|entry| entry.server_id != key.server_id || entry.thread_id != key.thread_id);
        if mode != AppModeKind::Default {
            state.modes.push(PersistedThreadMode {
                server_id: key.server_id.clone(),
                thread_id: key.thread_id.clone(),
                mode,
            });
        }
        trim_to_capacity(&mut state.modes);

        write_thread_modes(&path, &PersistedThreadModes {
            version: CURRENT_VERSION,
            modes: state.modes.clone(),
        });
    }
}

fn normalize_modes(modes: &mut Vec<PersistedThreadMode>) {
    modes.retain(|entry| entry.mode != AppModeKind::Default);
    let mut seen = HashSet::new();
    modes.reverse();
    modes.retain(|entry| seen.insert(entry.key()));
    modes.reverse();
    trim_to_capacity(modes);
}

fn trim_to_capacity(modes: &mut Vec<PersistedThreadMode>) {
    if modes.len() > MAX_PERSISTED_THREAD_MODES {
        modes.drain(..modes.len() - MAX_PERSISTED_THREAD_MODES);
    }
}

fn read_thread_modes(path: &Path) -> PersistedThreadModes {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(_) => return PersistedThreadModes::default(),
    };
    serde_json::from_slice(&bytes).unwrap_or_default()
}

fn write_thread_modes(path: &Path, value: &PersistedThreadModes) {
    let Some(parent) = path.parent() else { return };
    if let Err(error) = fs::create_dir_all(parent) {
        tracing::warn!(error = %error, "thread_modes: create dir failed");
        return;
    }

    let json = match serde_json::to_vec_pretty(value) {
        Ok(bytes) => bytes,
        Err(error) => {
            tracing::warn!(error = %error, "thread_modes: serialize failed");
            return;
        }
    };
    let temporary_path = path.with_extension("json.tmp");
    match fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&temporary_path)
    {
        Ok(mut file) => {
            if let Err(error) = file.write_all(&json) {
                tracing::warn!(error = %error, "thread_modes: write failed");
                let _ = fs::remove_file(&temporary_path);
                return;
            }
            let _ = file.sync_all();
        }
        Err(error) => {
            tracing::warn!(error = %error, "thread_modes: open temp file failed");
            return;
        }
    }
    if let Err(error) = fs::rename(&temporary_path, path) {
        tracing::warn!(error = %error, "thread_modes: rename failed");
        let _ = fs::remove_file(&temporary_path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn key(index: usize) -> ThreadKey {
        ThreadKey {
            server_id: "server".to_string(),
            thread_id: format!("thread-{index}"),
        }
    }

    #[test]
    fn plan_mode_round_trips_across_store_instances() {
        let directory = tempdir().expect("tempdir");
        let directory = directory.path().to_string_lossy();
        let first = ThreadModeStore::default();
        first.configure(&directory);
        first.set_mode(&key(1), AppModeKind::Plan);

        let restarted = ThreadModeStore::default();
        restarted.configure(&directory);

        assert_eq!(restarted.mode_for(&key(1)), Some(AppModeKind::Plan));
    }

    #[test]
    fn default_mode_removes_persisted_entry() {
        let directory = tempdir().expect("tempdir");
        let directory = directory.path().to_string_lossy();
        let first = ThreadModeStore::default();
        first.configure(&directory);
        first.set_mode(&key(1), AppModeKind::Plan);
        first.set_mode(&key(1), AppModeKind::Default);

        let restarted = ThreadModeStore::default();
        restarted.configure(&directory);

        assert_eq!(restarted.mode_for(&key(1)), None);
    }

    #[test]
    fn persisted_modes_are_bounded_to_recent_entries() {
        let directory = tempdir().expect("tempdir");
        let directory = directory.path().to_string_lossy();
        let store = ThreadModeStore::default();
        store.configure(&directory);
        for index in 0..=MAX_PERSISTED_THREAD_MODES {
            store.set_mode(&key(index), AppModeKind::Plan);
        }

        let restarted = ThreadModeStore::default();
        restarted.configure(&directory);

        assert_eq!(restarted.mode_for(&key(0)), None);
        assert_eq!(
            restarted.mode_for(&key(MAX_PERSISTED_THREAD_MODES)),
            Some(AppModeKind::Plan)
        );
    }
}
