//! Local per-thread runtime mode persistence.
//!
//! The app server does not currently return a thread's collaboration mode in
//! thread list/read snapshots, so mobile stores the user's last local choice
//! beside other app preferences. Only non-default modes are persisted.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::types::{AppModeKind, ThreadKey};

const THREAD_MODES_FILE: &str = "thread_modes.json";
const CURRENT_VERSION: u32 = 1;

static WRITE_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedThreadMode {
    server_id: String,
    thread_id: String,
    mode: AppModeKind,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedThreadModes {
    version: u32,
    #[serde(default)]
    modes: Vec<PersistedThreadMode>,
}

fn thread_modes_path(directory: &str) -> PathBuf {
    PathBuf::from(directory).join(THREAD_MODES_FILE)
}

fn read_thread_modes(path: &Path) -> PersistedThreadModes {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(_) => return PersistedThreadModes::default(),
    };
    serde_json::from_slice::<PersistedThreadModes>(&bytes).unwrap_or_default()
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

    let tmp_path = path.with_extension("json.tmp");
    match fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp_path)
    {
        Ok(mut file) => {
            if let Err(error) = file.write_all(&json) {
                tracing::warn!(error = %error, "thread_modes: write failed");
                let _ = fs::remove_file(&tmp_path);
                return;
            }
            let _ = file.sync_all();
        }
        Err(error) => {
            tracing::warn!(error = %error, "thread_modes: open tmp failed");
            return;
        }
    }
    if let Err(error) = fs::rename(&tmp_path, path) {
        tracing::warn!(error = %error, "thread_modes: rename failed");
        let _ = fs::remove_file(&tmp_path);
    }
}

pub(crate) fn read_mode(directory: &str, key: &ThreadKey) -> Option<AppModeKind> {
    let path = thread_modes_path(directory);
    let _guard = WRITE_LOCK.lock().ok();
    read_thread_modes(&path)
        .modes
        .into_iter()
        .find(|entry| entry.server_id == key.server_id && entry.thread_id == key.thread_id)
        .map(|entry| entry.mode)
}

pub(crate) fn set_mode(directory: &str, key: &ThreadKey, mode: AppModeKind) {
    let path = thread_modes_path(directory);
    let _guard = WRITE_LOCK.lock().ok();
    let mut persisted = read_thread_modes(&path);
    persisted.version = CURRENT_VERSION;
    persisted
        .modes
        .retain(|entry| !(entry.server_id == key.server_id && entry.thread_id == key.thread_id));
    if mode != AppModeKind::Default {
        persisted.modes.push(PersistedThreadMode {
            server_id: key.server_id.clone(),
            thread_id: key.thread_id.clone(),
            mode,
        });
    }
    write_thread_modes(&path, &persisted);
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn dir(tempdir: &tempfile::TempDir) -> String {
        tempdir.path().to_string_lossy().to_string()
    }

    fn key() -> ThreadKey {
        ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
        }
    }

    #[test]
    fn plan_mode_round_trips() {
        let tempdir = tempdir().unwrap();
        let key = key();

        set_mode(&dir(&tempdir), &key, AppModeKind::Plan);

        assert_eq!(read_mode(&dir(&tempdir), &key), Some(AppModeKind::Plan));
    }

    #[test]
    fn default_mode_removes_entry() {
        let tempdir = tempdir().unwrap();
        let key = key();

        set_mode(&dir(&tempdir), &key, AppModeKind::Plan);
        set_mode(&dir(&tempdir), &key, AppModeKind::Default);

        assert_eq!(read_mode(&dir(&tempdir), &key), None);
    }
}
