//! Cross-device sync for saved computers.
//!
//! The platform owns the saved-server schema, so each computer travels as an
//! opaque JSON payload keyed by its server id. This module owns the merge:
//! a last-write-wins element set. Every id carries the time it was last
//! written and, if removed, the time it was removed; the later of the two
//! decides whether it is live. Two devices that write concurrently each keep
//! the other's entries after merging, and removals propagate instead of being
//! resurrected by a device that has not seen them yet.
//!
//! The ledger is serialized as canonical JSON (sorted keys) so the platform
//! can skip a publish when the merged ledger equals what it just received.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Tombstones older than this are dropped. A device offline for longer than
/// this could resurrect a removed computer, which is an acceptable trade for
/// keeping the ledger small.
const TOMBSTONE_RETENTION_MS: i64 = 90 * 24 * 60 * 60 * 1000;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncedComputer {
    pub id: String,
    /// Platform-encoded saved-server JSON. Compared byte-for-byte, so the
    /// platform must encode deterministically (sorted keys).
    pub payload_json: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ComputerSyncResult {
    /// Canonical ledger JSON to persist locally and publish to other devices.
    pub ledger_json: String,
    /// Computers that are live after the merge, sorted by id.
    pub computers: Vec<SyncedComputer>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
struct Ledger {
    #[serde(default)]
    entries: BTreeMap<String, Entry>,
    #[serde(default)]
    removed: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Entry {
    payload: String,
    at: i64,
}

impl Ledger {
    fn parse(json: Option<&str>) -> Self {
        json.filter(|s| !s.trim().is_empty())
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default()
    }

    fn is_live(&self, id: &str) -> bool {
        match (self.entries.get(id), self.removed.get(id)) {
            (Some(entry), Some(removed_at)) => entry.at > *removed_at,
            (Some(_), None) => true,
            _ => false,
        }
    }

    /// Record the device's current computers: new or changed payloads are
    /// stamped `now`, and live entries missing from `local` are removed.
    fn record_local(&mut self, local: &[SyncedComputer], now_ms: i64) {
        for computer in local {
            let unchanged = self.is_live(&computer.id)
                && self
                    .entries
                    .get(&computer.id)
                    .is_some_and(|entry| entry.payload == computer.payload_json);
            if !unchanged {
                self.entries.insert(
                    computer.id.clone(),
                    Entry {
                        payload: computer.payload_json.clone(),
                        at: now_ms,
                    },
                );
            }
        }
        let live_ids: Vec<String> = self
            .entries
            .keys()
            .filter(|id| self.is_live(id))
            .cloned()
            .collect();
        for id in live_ids {
            if !local.iter().any(|computer| computer.id == id) {
                self.removed.insert(id, now_ms);
            }
        }
    }

    fn merge(&mut self, other: Ledger) {
        for (id, entry) in other.entries {
            let newer = self.entries.get(&id).is_none_or(|mine| entry.at > mine.at);
            if newer {
                self.entries.insert(id, entry);
            }
        }
        for (id, removed_at) in other.removed {
            let newer = self.removed.get(&id).is_none_or(|mine| removed_at > *mine);
            if newer {
                self.removed.insert(id, removed_at);
            }
        }
    }

    fn compact(&mut self, now_ms: i64) {
        let dead: Vec<String> = self
            .entries
            .keys()
            .filter(|id| !self.is_live(id))
            .cloned()
            .collect();
        for id in dead {
            self.entries.remove(&id);
        }
        self.removed
            .retain(|_, removed_at| now_ms - *removed_at < TOMBSTONE_RETENTION_MS);
    }

    fn live(&self) -> Vec<SyncedComputer> {
        self.entries
            .iter()
            .filter(|(id, _)| self.is_live(id))
            .map(|(id, entry)| SyncedComputer {
                id: id.clone(),
                payload_json: entry.payload.clone(),
            })
            .collect()
    }
}

pub fn reconcile(
    ledger_json: Option<&str>,
    local: &[SyncedComputer],
    remote_json: Option<&str>,
    now_ms: i64,
) -> ComputerSyncResult {
    let mut ledger = Ledger::parse(ledger_json);
    ledger.record_local(local, now_ms);
    if remote_json.is_some() {
        ledger.merge(Ledger::parse(remote_json));
    }
    ledger.compact(now_ms);
    ComputerSyncResult {
        ledger_json: serde_json::to_string(&ledger).unwrap_or_default(),
        computers: ledger.live(),
    }
}

/// Merge this device's saved computers with the ledger from other devices.
///
/// * `ledger_json`: this device's last ledger (None on first run).
/// * `local`: the computers currently saved on this device.
/// * `remote_json`: the ledger received from other devices, if any.
///
/// Returns the merged ledger and the computers that should now be saved.
#[uniffi::export]
pub fn cloud_sync_reconcile_computers(
    ledger_json: Option<String>,
    local: Vec<SyncedComputer>,
    remote_json: Option<String>,
    now_ms: i64,
) -> ComputerSyncResult {
    reconcile(
        ledger_json.as_deref(),
        &local,
        remote_json.as_deref(),
        now_ms,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn computer(id: &str, payload: &str) -> SyncedComputer {
        SyncedComputer {
            id: id.to_string(),
            payload_json: payload.to_string(),
        }
    }

    fn ids(result: &ComputerSyncResult) -> Vec<&str> {
        result.computers.iter().map(|c| c.id.as_str()).collect()
    }

    #[test]
    fn first_run_keeps_local_computers() {
        let result = reconcile(None, &[computer("a", "1")], None, 10);
        assert_eq!(ids(&result), vec!["a"]);
    }

    #[test]
    fn concurrent_adds_on_two_devices_both_survive() {
        let a = reconcile(None, &[computer("mac", "m")], None, 10);
        let b = reconcile(None, &[computer("pc", "p")], None, 11);
        // Device B receives A's ledger after writing its own.
        let merged = reconcile(
            Some(&b.ledger_json),
            &b.computers,
            Some(&a.ledger_json),
            12,
        );
        assert_eq!(ids(&merged), vec!["mac", "pc"]);
    }

    #[test]
    fn late_joining_device_does_not_wipe_existing_computers() {
        let phone = reconcile(None, &[computer("mac", "m")], None, 10);
        // A new iPad with nothing saved publishes first, then sees the phone.
        let ipad = reconcile(None, &[], None, 20);
        let ipad = reconcile(Some(&ipad.ledger_json), &[], Some(&phone.ledger_json), 21);
        assert_eq!(ids(&ipad), vec!["mac"]);
    }

    #[test]
    fn removal_propagates_and_is_not_resurrected() {
        let a = reconcile(None, &[computer("mac", "m")], None, 10);
        let b = reconcile(None, &[], Some(&a.ledger_json), 11);
        assert_eq!(ids(&b), vec!["mac"]);
        // A removes the computer.
        let a = reconcile(Some(&a.ledger_json), &[], None, 20);
        assert!(a.computers.is_empty());
        // B still has it saved locally but must drop it after merging.
        let b = reconcile(Some(&b.ledger_json), &b.computers, Some(&a.ledger_json), 21);
        assert!(b.computers.is_empty());
    }

    #[test]
    fn re_adding_after_removal_wins() {
        let a = reconcile(None, &[computer("mac", "m")], None, 10);
        let a = reconcile(Some(&a.ledger_json), &[], None, 20);
        let a = reconcile(Some(&a.ledger_json), &[computer("mac", "m2")], None, 30);
        assert_eq!(ids(&a), vec!["mac"]);
        assert_eq!(a.computers[0].payload_json, "m2");
    }

    #[test]
    fn rename_on_one_device_reaches_the_other() {
        let a = reconcile(None, &[computer("mac", "old")], None, 10);
        let b = reconcile(None, &[], Some(&a.ledger_json), 11);
        let a = reconcile(Some(&a.ledger_json), &[computer("mac", "new")], None, 20);
        let b = reconcile(Some(&b.ledger_json), &b.computers, Some(&a.ledger_json), 21);
        assert_eq!(b.computers[0].payload_json, "new");
    }

    #[test]
    fn unchanged_state_produces_identical_ledger() {
        let a = reconcile(None, &[computer("mac", "m")], None, 10);
        let again = reconcile(Some(&a.ledger_json), &a.computers, Some(&a.ledger_json), 50);
        assert_eq!(a.ledger_json, again.ledger_json);
    }

    #[test]
    fn old_tombstones_are_compacted() {
        let a = reconcile(None, &[computer("mac", "m")], None, 0);
        let a = reconcile(Some(&a.ledger_json), &[], None, 1);
        let later = reconcile(Some(&a.ledger_json), &[], None, TOMBSTONE_RETENTION_MS + 10);
        assert_eq!(later.ledger_json, r#"{"entries":{},"removed":{}}"#);
    }
}
