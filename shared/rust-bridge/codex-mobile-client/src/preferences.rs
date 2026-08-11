//! Mobile preferences: small, JSON-serialized user preferences shared across
//! iOS and Android. Persisted to a single file in a platform-provided
//! directory so the platforms can point it at local storage today and at a
//! cloud-synced directory (iCloud ubiquity container / Drive app-data mirror)
//! later without Rust changes.
//!
//! Intentionally excludes anything credential-bearing (SSH keys, API tokens,
//! ChatGPT auth). Only low-sensitivity user preferences belong here.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

const PREFERENCES_FILE: &str = "mobile_prefs.json";
const CURRENT_VERSION: u32 = 1;

static WRITE_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct PinnedThreadKey {
    pub server_id: String,
    pub thread_id: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct HomeSelection {
    pub selected_server_id: Option<String>,
    pub selected_project_id: Option<String>,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct MobilePreferences {
    pub pinned_threads: Vec<PinnedThreadKey>,
    /// Threads the user swiped to hide from the home list. Does not delete
    /// the thread — just suppresses it from the home merge.
    pub hidden_threads: Vec<PinnedThreadKey>,
    pub home_selection: HomeSelection,
}
#[derive(Serialize, Deserialize)]
struct PersistedPreferences {
    version: u32,
    #[serde(default)]
    pinned_threads: Vec<PinnedThreadKey>,
    #[serde(default)]
    hidden_threads: Vec<PinnedThreadKey>,
    #[serde(default)]
    home_selection: HomeSelection,
}

impl From<PersistedPreferences> for MobilePreferences {
    fn from(p: PersistedPreferences) -> Self {
        Self {
            pinned_threads: p.pinned_threads,
            hidden_threads: p.hidden_threads,
            home_selection: p.home_selection,
        }
    }
}

impl From<&MobilePreferences> for PersistedPreferences {
    fn from(p: &MobilePreferences) -> Self {
        Self {
            version: CURRENT_VERSION,
            pinned_threads: p.pinned_threads.clone(),
            hidden_threads: p.hidden_threads.clone(),
            home_selection: p.home_selection.clone(),
        }
    }
}

fn preferences_path(directory: &str) -> PathBuf {
    PathBuf::from(directory).join(PREFERENCES_FILE)
}

/// Guard used by cloud_sync to serialize its own read-modify-write cycles
/// against the handwritten preferences API.
pub(crate) fn acquire_write_guard() -> std::sync::MutexGuard<'static, ()> {
    WRITE_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

pub(crate) fn preferences_path_for(directory: &str) -> PathBuf {
    preferences_path(directory)
}

pub(crate) fn read_preferences_at(path: &Path) -> MobilePreferences {
    read_preferences(path)
}

pub(crate) fn write_preferences_at(path: &Path, value: &MobilePreferences) {
    write_preferences(path, value);
}

fn read_preferences(path: &Path) -> MobilePreferences {
    let bytes = match fs::read(path) {
        Ok(b) => b,
        Err(_) => return MobilePreferences::default(),
    };
    match serde_json::from_slice::<PersistedPreferences>(&bytes) {
        Ok(persisted) => persisted.into(),
        Err(_) => MobilePreferences::default(),
    }
}

fn write_preferences(path: &Path, value: &MobilePreferences) {
    let Some(parent) = path.parent() else { return };
    if let Err(e) = fs::create_dir_all(parent) {
        tracing::warn!(error = %e, "preferences: create dir failed");
        return;
    }

    let persisted: PersistedPreferences = value.into();
    let json = match serde_json::to_vec_pretty(&persisted) {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(error = %e, "preferences: serialize failed");
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
                tracing::warn!(error = %e, "preferences: write failed");
                let _ = fs::remove_file(&tmp_path);
                return;
            }
            let _ = file.sync_all();
        }
        Err(e) => {
            tracing::warn!(error = %e, "preferences: open tmp failed");
            return;
        }
    }
    if let Err(e) = fs::rename(&tmp_path, path) {
        tracing::warn!(error = %e, "preferences: rename failed");
        let _ = fs::remove_file(&tmp_path);
    }
}

/// Read the preferences file. Missing or corrupt files return defaults.
#[uniffi::export]
pub fn preferences_load(directory: String) -> MobilePreferences {
    let path = preferences_path(&directory);
    let _guard = WRITE_LOCK.lock().ok();
    read_preferences(&path)
}

/// Overwrite the preferences file with `value`. Returns what's on disk after
/// the write (identity of `value` when the write succeeds).
#[uniffi::export]
pub fn preferences_save(directory: String, value: MobilePreferences) -> MobilePreferences {
    let path = preferences_path(&directory);
    let _guard = WRITE_LOCK.lock().ok();
    write_preferences(&path, &value);
    read_preferences(&path)
}

/// Insert `key` at the front of the pinned-threads list. If it's already
/// pinned, leaves position unchanged. Returns the updated preferences.
#[uniffi::export]
pub fn preferences_add_pinned_thread(directory: String, key: PinnedThreadKey) -> MobilePreferences {
    let path = preferences_path(&directory);
    let _guard = WRITE_LOCK.lock().ok();
    let mut prefs = read_preferences(&path);
    if !prefs.pinned_threads.contains(&key) {
        prefs.pinned_threads.insert(0, key);
        write_preferences(&path, &prefs);
    }
    prefs
}

#[uniffi::export]
pub fn preferences_remove_pinned_thread(
    directory: String,
    key: PinnedThreadKey,
) -> MobilePreferences {
    let path = preferences_path(&directory);
    let _guard = WRITE_LOCK.lock().ok();
    let mut prefs = read_preferences(&path);
    let before = prefs.pinned_threads.len();
    prefs.pinned_threads.retain(|existing| existing != &key);
    if prefs.pinned_threads.len() != before {
        write_preferences(&path, &prefs);
    }
    prefs
}

#[uniffi::export]
pub fn preferences_set_home_selection(
    directory: String,
    selection: HomeSelection,
) -> MobilePreferences {
    let path = preferences_path(&directory);
    let _guard = WRITE_LOCK.lock().ok();
    let mut prefs = read_preferences(&path);
    prefs.home_selection = selection;
    write_preferences(&path, &prefs);
    prefs
}

/// Hide a thread from the home list without archiving it. Adds `key` to
/// the hidden set if not already present. Also removes it from pinned so
/// the user's explicit pin doesn't compete with their hide.
#[uniffi::export]
pub fn preferences_add_hidden_thread(directory: String, key: PinnedThreadKey) -> MobilePreferences {
    let path = preferences_path(&directory);
    let _guard = WRITE_LOCK.lock().ok();
    let mut prefs = read_preferences(&path);
    let mut changed = false;
    if !prefs.hidden_threads.contains(&key) {
        prefs.hidden_threads.insert(0, key.clone());
        changed = true;
    }
    let before = prefs.pinned_threads.len();
    prefs.pinned_threads.retain(|existing| existing != &key);
    if prefs.pinned_threads.len() != before {
        changed = true;
    }
    if changed {
        write_preferences(&path, &prefs);
    }
    prefs
}

#[uniffi::export]
pub fn preferences_remove_hidden_thread(
    directory: String,
    key: PinnedThreadKey,
) -> MobilePreferences {
    let path = preferences_path(&directory);
    let _guard = WRITE_LOCK.lock().ok();
    let mut prefs = read_preferences(&path);
    let before = prefs.hidden_threads.len();
    prefs.hidden_threads.retain(|existing| existing != &key);
    if prefs.hidden_threads.len() != before {
        write_preferences(&path, &prefs);
    }
    prefs
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn key(server: &str, thread: &str) -> PinnedThreadKey {
        PinnedThreadKey {
            server_id: server.into(),
            thread_id: thread.into(),
        }
    }

    #[test]
    fn load_returns_default_when_missing() {
        let dir = tempdir().unwrap();
        let prefs = preferences_load(dir.path().to_string_lossy().into());
        assert!(prefs.pinned_threads.is_empty());
        assert_eq!(prefs.home_selection, HomeSelection::default());
    }

    #[test]
    fn add_prepends_and_dedups() {
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        let prefs = preferences_add_pinned_thread(directory.clone(), key("s", "t1"));
        assert_eq!(prefs.pinned_threads, vec![key("s", "t1")]);

        let prefs = preferences_add_pinned_thread(directory.clone(), key("s", "t2"));
        assert_eq!(prefs.pinned_threads, vec![key("s", "t2"), key("s", "t1")]);

        // Re-adding does not change order.
        let prefs = preferences_add_pinned_thread(directory.clone(), key("s", "t1"));
        assert_eq!(prefs.pinned_threads, vec![key("s", "t2"), key("s", "t1")]);
    }

    #[test]
    fn remove_deletes_entry() {
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        preferences_add_pinned_thread(directory.clone(), key("s", "t1"));
        preferences_add_pinned_thread(directory.clone(), key("s", "t2"));

        let prefs = preferences_remove_pinned_thread(directory.clone(), key("s", "t1"));
        assert_eq!(prefs.pinned_threads, vec![key("s", "t2")]);

        // Removing something absent is a no-op.
        let prefs = preferences_remove_pinned_thread(directory, key("missing", "x"));
        assert_eq!(prefs.pinned_threads, vec![key("s", "t2")]);
    }

    #[test]
    fn home_selection_round_trip() {
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        let prefs = preferences_set_home_selection(
            directory.clone(),
            HomeSelection {
                selected_server_id: Some("srv1".into()),
                selected_project_id: Some("srv1::/path".into()),
            },
        );
        assert_eq!(
            prefs.home_selection.selected_server_id.as_deref(),
            Some("srv1")
        );

        // Persists across loads.
        let reloaded = preferences_load(directory);
        assert_eq!(
            reloaded.home_selection.selected_project_id.as_deref(),
            Some("srv1::/path")
        );
    }

    #[test]
    fn hide_removes_from_pinned_and_persists() {
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        preferences_add_pinned_thread(directory.clone(), key("s", "t1"));
        let prefs = preferences_add_hidden_thread(directory.clone(), key("s", "t1"));

        assert!(prefs.pinned_threads.is_empty());
        assert_eq!(prefs.hidden_threads, vec![key("s", "t1")]);

        // Persists across loads.
        let reloaded = preferences_load(directory.clone());
        assert_eq!(reloaded.hidden_threads, vec![key("s", "t1")]);

        // Unhide returns it to the available pool but not to pinned.
        let unhidden = preferences_remove_hidden_thread(directory, key("s", "t1"));
        assert!(unhidden.hidden_threads.is_empty());
        assert!(unhidden.pinned_threads.is_empty());
    }

    #[test]
    fn corrupt_file_recovers_to_default() {
        let dir = tempdir().unwrap();
        let path = dir.path().join(PREFERENCES_FILE);
        std::fs::write(&path, b"{ not valid json").unwrap();

        let prefs = preferences_load(dir.path().to_string_lossy().into());
        assert!(prefs.pinned_threads.is_empty());
    }
}
