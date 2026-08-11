use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;
use sha1::{Digest, Sha1};

use crate::ffi::ClientError;

const CACHE_TTL: Duration = Duration::from_secs(60);

// ── Public UniFFI types ───────────────────────────────────────────────────

#[derive(Debug, Clone, uniffi::Record)]
pub struct AmbientSuggestion {
    pub id: String,
    pub title: Option<String>,
    pub prompt: Option<String>,
    pub icon: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AmbientSuggestionsSnapshot {
    pub project_root: String,
    pub generated_at_ms: i64,
    pub suggestions: Vec<AmbientSuggestion>,
}

// ── Wire-format types (private) ───────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WireSuggestion {
    pub id: String,
    pub title: Option<String>,
    pub prompt: Option<String>,
    pub icon: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WireSnapshot {
    pub project_root: String,
    pub generated_at_ms: i64,
    pub current_suggestion_ids: Vec<String>,
    pub suggestions: Vec<WireSuggestion>,
}

// ── Cache ─────────────────────────────────────────────────────────────────

#[derive(Debug)]
pub(crate) struct CachedEntry {
    pub snapshot: AmbientSuggestionsSnapshot,
    pub fetched_at: Instant,
}

pub(crate) type AmbientCache = Mutex<HashMap<(String, String), CachedEntry>>;

pub(crate) fn new_ambient_cache() -> AmbientCache {
    Mutex::new(HashMap::new())
}

// ── Bucket hash ───────────────────────────────────────────────────────────

pub(crate) fn ambient_bucket(project_root: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(b"local");
    hasher.update([0u8]);
    hasher.update(project_root.as_bytes());
    hex::encode(hasher.finalize())
}

// ── Snapshot assembly from wire data ─────────────────────────────────────

pub(crate) fn build_snapshot_from_wire(
    wire: WireSnapshot,
) -> Result<AmbientSuggestionsSnapshot, ClientError> {
    let id_map: HashMap<&str, &WireSuggestion> = wire
        .suggestions
        .iter()
        .map(|s| (s.id.as_str(), s))
        .collect();

    let suggestions = wire
        .current_suggestion_ids
        .iter()
        .filter_map(|id| id_map.get(id.as_str()))
        .map(|s| AmbientSuggestion {
            id: s.id.clone(),
            title: s.title.clone(),
            prompt: s.prompt.clone(),
            icon: s.icon.clone(),
            description: s.description.clone(),
        })
        .collect();

    Ok(AmbientSuggestionsSnapshot {
        project_root: wire.project_root,
        generated_at_ms: wire.generated_at_ms,
        suggestions,
    })
}

// ── Cache helpers ─────────────────────────────────────────────────────────

pub(crate) fn cache_lookup(
    cache: &AmbientCache,
    server_id: &str,
    project_root: &str,
) -> Option<AmbientSuggestionsSnapshot> {
    let guard = cache.lock().unwrap_or_else(|p| p.into_inner());
    guard
        .get(&(server_id.to_string(), project_root.to_string()))
        .filter(|e| e.fetched_at.elapsed() < CACHE_TTL)
        .map(|e| e.snapshot.clone())
}

pub(crate) fn cache_insert(
    cache: &AmbientCache,
    server_id: &str,
    project_root: &str,
    snapshot: AmbientSuggestionsSnapshot,
) {
    let mut guard = cache.lock().unwrap_or_else(|p| p.into_inner());
    guard.insert(
        (server_id.to_string(), project_root.to_string()),
        CachedEntry {
            snapshot,
            fetched_at: Instant::now(),
        },
    );
}

pub(crate) fn invalidate_cache(cache: &AmbientCache, server_id: &str, project_root: Option<&str>) {
    let mut guard = cache.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(root) = project_root {
        guard.remove(&(server_id.to_string(), root.to_string()));
    } else {
        guard.retain(|(sid, _), _| sid != server_id);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_hash_known_value() {
        // printf 'local\0/foo/bar' | shasum -a 1
        assert_eq!(
            ambient_bucket("/foo/bar"),
            "8cc2cd985eb82c7c8c9d699361edea3f4efc4fa3"
        );
    }

    #[test]
    fn filter_and_order_by_current_suggestion_ids() {
        let wire = WireSnapshot {
            project_root: "/proj".to_string(),
            generated_at_ms: 1000,
            current_suggestion_ids: vec!["b".to_string(), "a".to_string()],
            suggestions: vec![
                WireSuggestion {
                    id: "a".to_string(),
                    title: Some("A".to_string()),
                    prompt: None,
                    icon: None,
                    description: None,
                },
                WireSuggestion {
                    id: "b".to_string(),
                    title: Some("B".to_string()),
                    prompt: None,
                    icon: None,
                    description: None,
                },
                WireSuggestion {
                    id: "c".to_string(),
                    title: Some("C".to_string()),
                    prompt: None,
                    icon: None,
                    description: None,
                },
            ],
        };

        let snapshot = build_snapshot_from_wire(wire).unwrap();
        let ids: Vec<&str> = snapshot.suggestions.iter().map(|s| s.id.as_str()).collect();
        // order follows currentSuggestionIds, "c" is excluded
        assert_eq!(ids, vec!["b", "a"]);
    }

    #[test]
    fn inactive_suggestions_excluded() {
        let wire = WireSnapshot {
            project_root: "/proj".to_string(),
            generated_at_ms: 1000,
            current_suggestion_ids: vec!["a".to_string()],
            suggestions: vec![
                WireSuggestion {
                    id: "a".to_string(),
                    title: None,
                    prompt: None,
                    icon: None,
                    description: None,
                },
                WireSuggestion {
                    id: "inactive".to_string(),
                    title: None,
                    prompt: None,
                    icon: None,
                    description: None,
                },
            ],
        };

        let snapshot = build_snapshot_from_wire(wire).unwrap();
        assert_eq!(snapshot.suggestions.len(), 1);
        assert_eq!(snapshot.suggestions[0].id, "a");
    }
}
