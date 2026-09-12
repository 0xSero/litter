//! Global cache of agent metadata sourced from alleycat probe
//! responses. Platforms (Swift / Kotlin) read from here when they need
//! to render an agent's label, icon, sort order, BETA badge, or branch
//! on capability flags.
//!
//! The store is keyed by the lowercase agent `name` (the same string
//! alleycat advertises and uses to route `Connect` requests). Multiple
//! servers may advertise the same agent name; the latest probe wins —
//! agents are expected to converge on identical metadata across hosts
//! built from the same alleycat version.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use crate::ffi::alleycat::{AppAgentCapabilities, AppAgentPresentation};

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppAgentMetadata {
    pub name: String,
    pub display_name: String,
    pub presentation: Option<AppAgentPresentation>,
    pub capabilities: Option<AppAgentCapabilities>,
}

#[derive(Default)]
pub struct AgentMetadataStore {
    inner: RwLock<HashMap<String, AppAgentMetadata>>,
}

impl AgentMetadataStore {
    /// Empty store. Only useful for tests that want to assert on probe
    /// behaviour in isolation — the app builds its store with
    /// [`Self::with_builtin_catalog`].
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Store pre-seeded from [`crate::store::agent_catalog`].
    ///
    /// Without this, every non-alleycat connection path (SSH bridge,
    /// Slingshot, direct `ws://` Codex URL) left the store empty, and
    /// platform code that orders runtimes by intersecting with
    /// [`Self::all_sorted`] rendered an empty list — a connected Claude
    /// or opencode runtime simply never appeared in the picker. Seeding
    /// gives every known agent a label, title, sort order and capability
    /// set up front; a probe response still overwrites it.
    pub fn with_builtin_catalog() -> Arc<Self> {
        let store = Self::default();
        store.upsert_all(crate::store::agent_catalog::seed_metadata());
        Arc::new(store)
    }

    /// Replace this agent's metadata. Called whenever a probe response
    /// carries fresh data. Older alleycat hosts that omit `presentation`
    /// / `capabilities` / `icon` still overwrite the entry — clients
    /// must tolerate partial metadata.
    pub fn upsert(&self, metadata: AppAgentMetadata) {
        let key = metadata.name.to_ascii_lowercase();
        let mut guard = self.inner.write().expect("agent metadata lock");
        guard.insert(key, metadata);
    }

    pub fn upsert_all<I>(&self, entries: I)
    where
        I: IntoIterator<Item = AppAgentMetadata>,
    {
        let mut guard = self.inner.write().expect("agent metadata lock");
        for metadata in entries {
            let key = metadata.name.to_ascii_lowercase();
            guard.insert(key, metadata);
        }
    }

    /// Resolve an agent id to its metadata, tolerating every spelling
    /// litter may hold: the canonical id, the runtime kind an alleycat
    /// `name`/`display_name` pair normalizes to, a built-in catalog
    /// alias (`claude-code`, `factory-droid`, `local_studio`, …), or an
    /// alias the host itself advertised in `presentation.aliases`.
    pub fn get(&self, name: &str) -> Option<AppAgentMetadata> {
        let key = name.trim().to_ascii_lowercase();
        if key.is_empty() {
            return None;
        }
        let guard = self.inner.read().expect("agent metadata lock");
        if let Some(found) = guard.get(&key) {
            return Some(found.clone());
        }
        // An entry stored under a host-specific name (`pi.dev`) answers
        // to the canonical kind it normalizes to (`pi`).
        if let Some(found) = guard.values().find(|metadata| {
            crate::alleycat::agent_runtime_kind(&metadata.name, &metadata.display_name).as_deref()
                == Some(key.as_str())
        }) {
            return Some(found.clone());
        }
        // The reverse direction: the caller asked with an alias, the
        // entry is stored under the canonical id.
        if let Some(canonical) = crate::store::agent_catalog::canonical_kind(&key)
            && canonical != key
            && let Some(found) = guard.get(&canonical)
        {
            return Some(found.clone());
        }
        // Aliases the host advertised for an agent litter has no
        // built-in catalog entry for.
        guard
            .values()
            .find(|metadata| {
                metadata
                    .presentation
                    .as_ref()
                    .is_some_and(|presentation| {
                        presentation
                            .aliases
                            .iter()
                            .any(|alias| alias.trim().to_ascii_lowercase() == key)
                    })
            })
            .cloned()
    }

    /// All known agents in presentation-sort order. Agents without an
    /// explicit `sort_order` fall to the end, tie-broken by name.
    pub fn all_sorted(&self) -> Vec<AppAgentMetadata> {
        let guard = self.inner.read().expect("agent metadata lock");
        let mut out: Vec<AppAgentMetadata> = guard.values().cloned().collect();
        out.sort_by(|a, b| {
            let a_order = a
                .presentation
                .as_ref()
                .map(|p| p.sort_order)
                .unwrap_or(i32::MAX);
            let b_order = b
                .presentation
                .as_ref()
                .map(|p| p.sort_order)
                .unwrap_or(i32::MAX);
            a_order.cmp(&b_order).then_with(|| a.name.cmp(&b.name))
        });
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn metadata(name: &str, sort_order: i32) -> AppAgentMetadata {
        AppAgentMetadata {
            name: name.to_owned(),
            display_name: name.to_owned(),
            presentation: Some(AppAgentPresentation {
                title: None,
                is_beta: false,
                sort_order,
                description: None,
                aliases: Vec::new(),
            }),
            capabilities: None,
        }
    }

    #[test]
    fn upsert_replaces_by_lowercased_name() {
        let store = AgentMetadataStore::new();
        store.upsert(metadata("Codex", 0));
        store.upsert(metadata("codex", 5));
        let fetched = store.get("CODEX").expect("present");
        assert_eq!(fetched.presentation.unwrap().sort_order, 5);
    }

    #[test]
    fn all_sorted_orders_by_sort_order_then_name() {
        let store = AgentMetadataStore::new();
        store.upsert(metadata("zeta", 1));
        store.upsert(metadata("alpha", 1));
        store.upsert(metadata("middle", 0));
        let sorted: Vec<String> = store.all_sorted().into_iter().map(|m| m.name).collect();
        assert_eq!(sorted, vec!["middle", "alpha", "zeta"]);
    }

    #[test]
    fn get_resolves_runtime_kind_aliases() {
        let store = AgentMetadataStore::new();
        store.upsert(metadata("pi.dev", 0));
        let fetched = store.get("pi").expect("canonical alias should resolve");
        assert_eq!(fetched.name, "pi.dev");
    }

    #[test]
    fn builtin_catalog_seeds_every_known_agent() {
        let store = AgentMetadataStore::with_builtin_catalog();
        for name in [
            "codex",
            "local-studio",
            "pi",
            "amp",
            "opencode",
            "claude",
            "droid",
            "hermes",
            "devin",
            "grok",
            "shell",
        ] {
            assert!(store.get(name).is_some(), "{name} missing from seed");
        }
        // Presentation order must be non-empty before any probe: the
        // platforms intersect their runtime lists with this ordering, so
        // an empty store hides every connected runtime.
        assert!(!store.all_sorted().is_empty());
    }

    #[test]
    fn builtin_catalog_resolves_aliases_and_labels() {
        let store = AgentMetadataStore::with_builtin_catalog();
        assert_eq!(
            store.get("claude-code").map(|entry| entry.display_name),
            Some("Claude".to_string())
        );
        assert_eq!(
            store.get("factory-droid").map(|entry| entry.name),
            Some("droid".to_string())
        );
        assert_eq!(
            store.get("local_studio").map(|entry| entry.display_name),
            Some("Local Studio".to_string())
        );
    }

    #[test]
    fn probe_response_overwrites_seeded_catalog_entry() {
        let store = AgentMetadataStore::with_builtin_catalog();
        store.upsert(metadata("claude", 42));
        let fetched = store.get("claude").expect("present");
        assert_eq!(
            fetched.presentation.expect("presentation").sort_order,
            42,
            "a live probe must win over the seeded entry"
        );
    }
}
