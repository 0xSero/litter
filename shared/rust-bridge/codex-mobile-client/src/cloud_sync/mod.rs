//! iCloud KVS settings sync envelope + merge policy.
//!
//! Transport is owned by the platform (iOS/Catalyst call
//! `NSUbiquitousKeyValueStore`). This module owns the serialized envelope
//! shape, last-write-wins merging, and the integration with
//! `mobile_prefs.json` through the atomic writer in `preferences.rs`.
//!
//! Boundary contract
//! -----------------
//! * `export_cloud_snapshot(directory, device_id)` reads the current
//!   `mobile_prefs.json` plus any platform-pushed UserDefaults values (from
//!   the in-memory platform table) and returns a JSON blob suitable for
//!   `NSUbiquitousKeyValueStore.data(forKey:)`. JSON over CBOR because the
//!   1MB KVS quota leaves plenty of headroom and `serde_json` is already a
//!   workspace dep; one fewer transitive dependency.
//! * `apply_cloud_snapshot(directory, bytes)` decodes a remote blob, merges
//!   with local state last-write-wins per key, atomically rewrites
//!   `mobile_prefs.json` via the existing writer, and returns the list of
//!   writebacks the platform should apply to its own UserDefaults (only the
//!   Swift-owned keys).
//! * `update_platform_value(key, value_json)` stores a local platform-side
//!   change in the in-memory table with a fresh timestamp so the next
//!   `export_cloud_snapshot` includes it.
//!
//! The platform-owned keys list is intentionally small and closed (see
//! `PLATFORM_KEYS`). Anything not in that set is round-tripped through the
//! Rust-owned `mobile_prefs.json` side of the envelope.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::preferences::{
    HomeSelection, MobilePreferences, PinnedThreadKey, acquire_write_guard, preferences_path_for,
    read_preferences_at, write_preferences_at,
};

/// Envelope version. Bump when the layout changes incompatibly.
const ENVELOPE_VERSION: u32 = 1;

/// Rust-owned keys that live inside `mobile_prefs.json`. Treated as a
/// monolithic group with a single per-field timestamp so partial overwrites
/// from older snapshots don't clobber newer fields.
const RUST_KEY_PINNED_THREADS: &str = "rust.pinned_threads";
const RUST_KEY_HIDDEN_THREADS: &str = "rust.hidden_threads";
const RUST_KEY_HOME_SELECTION: &str = "rust.home_selection";

/// Swift-owned UserDefaults keys that participate in sync. Anything outside
/// this set is ignored on apply (defense in depth against schema drift) and
/// never exported.
const PLATFORM_KEYS: &[&str] = &[
    "fontFamily",
    "selectedLightTheme",
    "selectedDarkTheme",
    "conversationTextSizeStep",
    "collapseTurns",
    "litter.debugSettings",
    "litter.experimentalFeatures",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CloudEntry {
    value: serde_json::Value,
    updated_at_ms: i64,
    source_device: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CloudSnapshot {
    version: u32,
    entries: HashMap<String, CloudEntry>,
}

/// Thin UniFFI-safe representation of a writeback the platform should apply
/// to its own UserDefaults after a merge.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PlatformWriteback {
    pub key: String,
    /// JSON-encoded value. Platform decodes based on the key's expected type
    /// (string / int / bool / dictionary).
    pub value_json: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CloudSyncError {
    #[error("decode error: {0}")]
    Decode(String),
    #[error("encode error: {0}")]
    Encode(String),
    #[error("invalid json: {0}")]
    InvalidJson(String),
}

/// In-memory table of Swift-owned values with per-key timestamps. Populated
/// by `update_platform_value` and consumed by `export_cloud_snapshot`.
/// Entries here are also rehydrated from the merge result during
/// `apply_cloud_snapshot` so the next export reflects the winning state.
static PLATFORM_TABLE: Mutex<Option<HashMap<String, CloudEntry>>> = Mutex::new(None);

fn platform_table_lock() -> std::sync::MutexGuard<'static, Option<HashMap<String, CloudEntry>>> {
    PLATFORM_TABLE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn with_platform_table<R>(f: impl FnOnce(&mut HashMap<String, CloudEntry>) -> R) -> R {
    let mut guard = platform_table_lock();
    let table = guard.get_or_insert_with(HashMap::new);
    f(table)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn is_platform_key(key: &str) -> bool {
    PLATFORM_KEYS.iter().any(|candidate| *candidate == key)
}

fn build_snapshot(directory: &str, device_id: &str) -> CloudSnapshot {
    let _guard = acquire_write_guard();
    let prefs = read_preferences_at(&preferences_path_for(directory));
    drop(_guard);

    let mut entries: HashMap<String, CloudEntry> = HashMap::new();

    // Snapshot the in-memory platform table into the envelope. Clone so the
    // lock can be released before we serialize.
    let platform_snapshot: HashMap<String, CloudEntry> = {
        let guard = platform_table_lock();
        guard.as_ref().cloned().unwrap_or_default()
    };
    for (key, entry) in platform_snapshot {
        if is_platform_key(&key) {
            entries.insert(key, entry);
        }
    }

    // Rust-side preference values. Each field rides with a shared timestamp
    // derived from "now" because we don't track per-field mtimes on disk.
    // The merge is still correct — the newer side (whichever device just
    // changed) wins because its export happens after its local write.
    let ts = now_ms();
    let rust_entry = |value: serde_json::Value| CloudEntry {
        value,
        updated_at_ms: ts,
        source_device: device_id.to_string(),
    };

    if let Ok(v) = serde_json::to_value(&prefs.pinned_threads) {
        entries.insert(RUST_KEY_PINNED_THREADS.to_string(), rust_entry(v));
    }
    if let Ok(v) = serde_json::to_value(&prefs.hidden_threads) {
        entries.insert(RUST_KEY_HIDDEN_THREADS.to_string(), rust_entry(v));
    }
    if let Ok(v) = serde_json::to_value(&prefs.home_selection) {
        entries.insert(RUST_KEY_HOME_SELECTION.to_string(), rust_entry(v));
    }

    CloudSnapshot {
        version: ENVELOPE_VERSION,
        entries,
    }
}

fn encode_envelope(snapshot: &CloudSnapshot) -> Result<Vec<u8>, CloudSyncError> {
    serde_json::to_vec(snapshot).map_err(|e| CloudSyncError::Encode(e.to_string()))
}

fn decode_envelope(bytes: &[u8]) -> Result<CloudSnapshot, CloudSyncError> {
    serde_json::from_slice(bytes).map_err(|e| CloudSyncError::Decode(e.to_string()))
}

/// Build a sync envelope from current Rust + platform state. JSON-encoded.
pub fn export_snapshot(directory: &str, device_id: &str) -> Result<Vec<u8>, CloudSyncError> {
    let snapshot = build_snapshot(directory, device_id);
    encode_envelope(&snapshot)
}

/// Merge a remote envelope into local state. Writes back to
/// `mobile_prefs.json` via the atomic writer and returns the list of
/// Swift-owned UserDefaults keys the platform should update locally.
///
/// Merge policy: last-write-wins per key by `updated_at_ms`. Ties favor the
/// remote side so an equal-timestamp broadcast eventually converges (the
/// local side will pick the winning value up on its next export).
pub fn apply_snapshot(
    directory: &str,
    bytes: &[u8],
) -> Result<Vec<PlatformWriteback>, CloudSyncError> {
    let remote = decode_envelope(bytes)?;
    if remote.version != ENVELOPE_VERSION {
        // Future: handle version migrations. For v1 we ignore unknown
        // versions rather than risk corrupting local state.
        tracing::warn!(
            received = remote.version,
            expected = ENVELOPE_VERSION,
            "cloud_sync: ignoring snapshot with unexpected version"
        );
        return Ok(Vec::new());
    }

    // Read local state (both prefs file and platform table) under the write
    // lock, merge, and write back. Holding the lock across the write is
    // intentional — it prevents a concurrent preferences_* call from
    // interleaving a partial update.
    let _guard = acquire_write_guard();
    let path = preferences_path_for(directory);
    let mut local = read_preferences_at(&path);
    let mut local_prefs_changed = false;
    let mut writebacks: Vec<PlatformWriteback> = Vec::new();

    for (key, remote_entry) in remote.entries {
        if key.starts_with("rust.") {
            if let Some(changed_prefs) = merge_rust_key(&mut local, &key, &remote_entry) {
                local_prefs_changed = local_prefs_changed || changed_prefs;
            }
            continue;
        }

        if !is_platform_key(&key) {
            // Unknown key — ignore to avoid polluting local state with
            // schema drift from a newer client.
            continue;
        }

        let should_apply = with_platform_table(|table| match table.get(&key) {
            Some(existing) if existing.updated_at_ms > remote_entry.updated_at_ms => false,
            _ => {
                table.insert(key.clone(), remote_entry.clone());
                true
            }
        });

        if should_apply {
            let value_json = serde_json::to_string(&remote_entry.value)
                .map_err(|e| CloudSyncError::Encode(e.to_string()))?;
            writebacks.push(PlatformWriteback { key, value_json });
        }
    }

    if local_prefs_changed {
        write_preferences_at(&path, &local);
    }

    Ok(writebacks)
}

/// Returns `Some(changed)` when the key was recognized (true if local state
/// was updated, false if the local copy was newer and we left it alone).
/// Returns `None` for unknown `rust.*` keys (forward compatibility).
fn merge_rust_key(
    local: &mut MobilePreferences,
    key: &str,
    remote_entry: &CloudEntry,
) -> Option<bool> {
    // We don't persist per-field timestamps in `mobile_prefs.json`, so
    // compare against the platform_table entry (which tracks the last time
    // a value was observed from either a local export or a remote apply).
    let is_newer = with_platform_table(|table| match table.get(key) {
        Some(existing) if existing.updated_at_ms >= remote_entry.updated_at_ms => false,
        _ => {
            table.insert(key.to_string(), remote_entry.clone());
            true
        }
    });

    match key {
        RUST_KEY_PINNED_THREADS => {
            if !is_newer {
                return Some(false);
            }
            match serde_json::from_value::<Vec<PinnedThreadKey>>(remote_entry.value.clone()) {
                Ok(v) => {
                    if local.pinned_threads != v {
                        local.pinned_threads = v;
                        Some(true)
                    } else {
                        Some(false)
                    }
                }
                Err(_) => Some(false),
            }
        }
        RUST_KEY_HIDDEN_THREADS => {
            if !is_newer {
                return Some(false);
            }
            match serde_json::from_value::<Vec<PinnedThreadKey>>(remote_entry.value.clone()) {
                Ok(v) => {
                    if local.hidden_threads != v {
                        local.hidden_threads = v;
                        Some(true)
                    } else {
                        Some(false)
                    }
                }
                Err(_) => Some(false),
            }
        }
        RUST_KEY_HOME_SELECTION => {
            if !is_newer {
                return Some(false);
            }
            match serde_json::from_value::<HomeSelection>(remote_entry.value.clone()) {
                Ok(v) => {
                    if local.home_selection != v {
                        local.home_selection = v;
                        Some(true)
                    } else {
                        Some(false)
                    }
                }
                Err(_) => Some(false),
            }
        }
        _ => None,
    }
}

// ── UniFFI surface ───────────────────────────────────────────────────────

/// Build a CBOR-encoded sync envelope from current local state
/// (`mobile_prefs.json` + Swift-owned table). Call before writing to
/// `NSUbiquitousKeyValueStore`.
#[uniffi::export]
pub fn cloud_sync_export_snapshot(
    directory: String,
    device_id: String,
) -> Result<Vec<u8>, CloudSyncError> {
    export_snapshot(&directory, &device_id)
}

/// Merge a CBOR-encoded remote envelope into local state. Rewrites
/// `mobile_prefs.json` as needed and returns the Swift-owned UserDefaults
/// writebacks the platform must apply.
#[uniffi::export]
pub fn cloud_sync_apply_snapshot(
    directory: String,
    bytes: Vec<u8>,
) -> Result<Vec<PlatformWriteback>, CloudSyncError> {
    apply_snapshot(&directory, &bytes)
}

/// Notify Rust that a Swift-owned value changed locally. `value_json` is a
/// valid JSON encoding of the value (e.g. `"\"Menlo\""` for a string,
/// `"{\"enabled\":true}"` for a dictionary). Keys outside the syncable set
/// are silently ignored.
#[uniffi::export]
pub fn cloud_sync_update_platform_value(
    key: String,
    value_json: String,
) -> Result<(), CloudSyncError> {
    update_platform_value(&key, &value_json)
}

/// The list of Swift-owned UserDefaults keys the platform should observe
/// and feed back via `cloud_sync_update_platform_value`. Kept in Rust so
/// both platforms pull from the same source of truth.
#[uniffi::export]
pub fn cloud_sync_platform_keys() -> Vec<String> {
    PLATFORM_KEYS.iter().map(|s| s.to_string()).collect()
}

/// Platform-side notification: a Swift-owned value just changed locally.
/// Stored with "now" as the timestamp so it wins on the next merge against
/// any stale cloud entries. `value_json` must be a valid JSON encoding of
/// the value; it is decoded and stored as a `serde_json::Value` for later
/// re-serialization into the envelope.
pub fn update_platform_value(key: &str, value_json: &str) -> Result<(), CloudSyncError> {
    if !is_platform_key(key) {
        return Ok(());
    }
    let value: serde_json::Value =
        serde_json::from_str(value_json).map_err(|e| CloudSyncError::InvalidJson(e.to_string()))?;
    let entry = CloudEntry {
        value,
        updated_at_ms: now_ms(),
        source_device: String::new(),
    };
    with_platform_table(|table| {
        table.insert(key.to_string(), entry);
    });
    Ok(())
}

/// Clear the in-memory platform table and hold a lock for the caller's
/// lifetime. Test-only.
///
/// The platform table is process-global and cargo runs tests in parallel, so
/// without serialization one test's reset lands in the middle of another's
/// assertions. That surfaced as `export_includes_platform_table_entries`
/// failing intermittently in CI while the same commit passed locally.
///
/// Callers must bind the returned guard (`let _guard = reset_platform_table();`)
/// so it is held for the whole test body rather than dropped immediately.
#[cfg(test)]
#[must_use = "bind the guard so the platform table stays locked for the test"]
fn reset_platform_table() -> std::sync::MutexGuard<'static, ()> {
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    // Recover from poisoning: one failing test must not cascade into every
    // other test that touches the table.
    let guard = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut table = platform_table_lock();
    *table = None;
    drop(table);
    guard
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::preferences::preferences_save;
    use tempfile::tempdir;

    fn pin(server: &str, thread: &str) -> PinnedThreadKey {
        PinnedThreadKey {
            server_id: server.into(),
            thread_id: thread.into(),
        }
    }

    #[test]
    fn export_includes_rust_prefs() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        // Seed the prefs file.
        preferences_save(
            directory.clone(),
            MobilePreferences {
                pinned_threads: vec![pin("s", "a")],
                hidden_threads: vec![],
                home_selection: HomeSelection::default(),
                ..Default::default()
            },
        );

        let bytes = export_snapshot(&directory, "deviceA").expect("export");
        let snapshot = decode_envelope(&bytes).expect("decode");
        assert_eq!(snapshot.version, ENVELOPE_VERSION);
        assert!(snapshot.entries.contains_key(RUST_KEY_PINNED_THREADS));
        assert!(snapshot.entries.contains_key(RUST_KEY_HIDDEN_THREADS));
        assert!(snapshot.entries.contains_key(RUST_KEY_HOME_SELECTION));
    }

    #[test]
    fn apply_writes_back_rust_prefs_when_remote_is_newer() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        // Local has "a". Remote wants "b".
        preferences_save(
            directory.clone(),
            MobilePreferences {
                pinned_threads: vec![pin("s", "a")],
                hidden_threads: vec![],
                home_selection: HomeSelection::default(),
                ..Default::default()
            },
        );

        let mut snapshot = CloudSnapshot {
            version: ENVELOPE_VERSION,
            entries: HashMap::new(),
        };
        snapshot.entries.insert(
            RUST_KEY_PINNED_THREADS.into(),
            CloudEntry {
                value: serde_json::to_value(vec![pin("s", "b")]).unwrap(),
                updated_at_ms: now_ms() + 10_000,
                source_device: "mac".into(),
            },
        );
        let bytes = encode_envelope(&snapshot).unwrap();
        let writebacks = apply_snapshot(&directory, &bytes).expect("apply");
        assert!(writebacks.is_empty(), "no platform keys in envelope");

        let reloaded = crate::preferences::preferences_load(directory);
        assert_eq!(reloaded.pinned_threads, vec![pin("s", "b")]);
    }

    #[test]
    fn apply_platform_key_returns_writeback() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        let mut snapshot = CloudSnapshot {
            version: ENVELOPE_VERSION,
            entries: HashMap::new(),
        };
        snapshot.entries.insert(
            "fontFamily".into(),
            CloudEntry {
                value: serde_json::Value::String("JetBrainsMono".into()),
                updated_at_ms: now_ms() + 10_000,
                source_device: "mac".into(),
            },
        );
        let bytes = encode_envelope(&snapshot).unwrap();
        let writebacks = apply_snapshot(&directory, &bytes).expect("apply");
        assert_eq!(writebacks.len(), 1);
        assert_eq!(writebacks[0].key, "fontFamily");
        assert_eq!(writebacks[0].value_json, "\"JetBrainsMono\"");
    }

    #[test]
    fn apply_ignores_unknown_platform_keys() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        let mut snapshot = CloudSnapshot {
            version: ENVELOPE_VERSION,
            entries: HashMap::new(),
        };
        snapshot.entries.insert(
            "unknownKey".into(),
            CloudEntry {
                value: serde_json::Value::Bool(true),
                updated_at_ms: now_ms() + 10_000,
                source_device: "mac".into(),
            },
        );
        let bytes = encode_envelope(&snapshot).unwrap();
        let writebacks = apply_snapshot(&directory, &bytes).expect("apply");
        assert!(writebacks.is_empty());
    }

    #[test]
    fn local_platform_change_wins_when_newer() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        // Record a local change "now".
        update_platform_value("fontFamily", "\"Local\"").unwrap();

        // Remote with an older timestamp.
        let mut snapshot = CloudSnapshot {
            version: ENVELOPE_VERSION,
            entries: HashMap::new(),
        };
        snapshot.entries.insert(
            "fontFamily".into(),
            CloudEntry {
                value: serde_json::Value::String("Remote".into()),
                updated_at_ms: now_ms() - 100_000,
                source_device: "mac".into(),
            },
        );
        let bytes = encode_envelope(&snapshot).unwrap();
        let writebacks = apply_snapshot(&directory, &bytes).expect("apply");
        assert!(
            writebacks.is_empty(),
            "local newer value should win and produce no writeback"
        );
    }

    #[test]
    fn export_includes_platform_table_entries() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        update_platform_value("fontFamily", "\"JetBrainsMono\"").unwrap();
        let bytes = export_snapshot(&directory, "deviceA").unwrap();
        let snapshot = decode_envelope(&bytes).unwrap();
        assert!(snapshot.entries.contains_key("fontFamily"));
    }

    #[test]
    fn mismatched_version_is_ignored() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        let snapshot = CloudSnapshot {
            version: 999,
            entries: HashMap::new(),
        };
        let bytes = encode_envelope(&snapshot).unwrap();
        let writebacks = apply_snapshot(&directory, &bytes).unwrap();
        assert!(writebacks.is_empty());
    }

    #[test]
    fn corrupt_bytes_return_error() {
        let _guard = reset_platform_table();
        let dir = tempdir().unwrap();
        let directory: String = dir.path().to_string_lossy().into();

        let err = apply_snapshot(&directory, b"not cbor").unwrap_err();
        matches!(err, CloudSyncError::Decode(_));
    }
}
