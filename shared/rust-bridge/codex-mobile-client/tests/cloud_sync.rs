//! Integration tests for the cloud_sync UniFFI surface.
//!
//! These run as a separate compilation unit, so they survive even when
//! unrelated upstream-codex test drift breaks the lib's unit tests.

use codex_mobile_client::cloud_sync::{
    cloud_sync_apply_snapshot, cloud_sync_export_snapshot, cloud_sync_platform_keys,
    cloud_sync_update_platform_value,
};
use codex_mobile_client::preferences::{
    HomeSelection, MobilePreferences, PinnedThreadKey, preferences_load, preferences_save,
};
use std::sync::Mutex;
use tempfile::tempdir;

/// Tests share a process-wide platform table (a static singleton in
/// production, by design). Serialize tests that touch it so they don't
/// stomp on each other.
static TEST_LOCK: Mutex<()> = Mutex::new(());

fn pin(server: &str, thread: &str) -> PinnedThreadKey {
    PinnedThreadKey {
        server_id: server.into(),
        thread_id: thread.into(),
    }
}

#[test]
fn round_trip_export_then_apply_preserves_pinned_threads() {
    let _guard = TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let local_dir = tempdir().unwrap();
    let local: String = local_dir.path().to_string_lossy().into();

    preferences_save(
        local.clone(),
        MobilePreferences {
            pinned_threads: vec![pin("s1", "abc")],
            hidden_threads: vec![pin("s2", "xyz")],
            home_selection: HomeSelection {
                selected_server_id: Some("s1".into()),
                selected_project_id: Some("s1::/work".into()),
            },
        },
    );

    let bytes = cloud_sync_export_snapshot(local, "deviceA".into()).expect("export");

    // Apply that snapshot to a *different* local directory, simulating a
    // second device receiving via KVS. We don't assert the writebacks list
    // here because the platform table is a process-wide singleton that
    // earlier tests in this file may have populated; we only care that the
    // Rust-owned prefs round-trip correctly through `mobile_prefs.json`.
    let remote_dir = tempdir().unwrap();
    let remote: String = remote_dir.path().to_string_lossy().into();
    let _writebacks = cloud_sync_apply_snapshot(remote.clone(), bytes).expect("apply");

    let merged = preferences_load(remote);
    assert_eq!(merged.pinned_threads, vec![pin("s1", "abc")]);
    assert_eq!(merged.hidden_threads, vec![pin("s2", "xyz")]);
    assert_eq!(
        merged.home_selection.selected_server_id.as_deref(),
        Some("s1")
    );
}

#[test]
fn platform_value_round_trips_through_envelope() {
    let _guard = TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let local_dir = tempdir().unwrap();
    let local: String = local_dir.path().to_string_lossy().into();

    cloud_sync_update_platform_value("fontFamily".into(), "\"JetBrainsMono\"".into())
        .expect("update");

    let bytes = cloud_sync_export_snapshot(local, "deviceA".into()).expect("export");

    let remote_dir = tempdir().unwrap();
    let remote: String = remote_dir.path().to_string_lossy().into();
    let writebacks = cloud_sync_apply_snapshot(remote, bytes).expect("apply");

    // The font key should appear as a writeback for the platform.
    assert!(
        writebacks
            .iter()
            .any(|wb| wb.key == "fontFamily" && wb.value_json == "\"JetBrainsMono\"")
    );
}

#[test]
fn unknown_platform_key_is_ignored_on_update() {
    // Should not error; just silently drop.
    cloud_sync_update_platform_value("not.a.real.key".into(), "true".into()).expect("noop");
}

#[test]
fn invalid_json_value_returns_error() {
    let err = cloud_sync_update_platform_value("fontFamily".into(), "this is not json".into())
        .unwrap_err();
    let msg = format!("{err:?}");
    assert!(msg.contains("InvalidJson"), "got: {msg}");
}

#[test]
fn platform_keys_lists_all_seven_swift_keys() {
    let keys = cloud_sync_platform_keys();
    let expected = [
        "fontFamily",
        "selectedLightTheme",
        "selectedDarkTheme",
        "conversationTextSizeStep",
        "collapseTurns",
        "litter.debugSettings",
        "litter.experimentalFeatures",
    ];
    for key in expected {
        assert!(keys.iter().any(|k| k == key), "missing key: {key}");
    }
}

#[test]
fn corrupt_envelope_returns_decode_error() {
    let dir = tempdir().unwrap();
    let directory: String = dir.path().to_string_lossy().into();
    let err = cloud_sync_apply_snapshot(directory, b"not json at all".to_vec()).unwrap_err();
    let msg = format!("{err:?}");
    assert!(msg.contains("Decode"), "got: {msg}");
}
