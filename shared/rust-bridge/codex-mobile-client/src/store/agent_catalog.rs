//! Built-in agent catalog — the one place litter states what it knows
//! about each coding agent.
//!
//! Two problems this solves:
//!
//! 1. **Cold / non-alleycat metadata.** [`crate::store::AgentMetadataStore`]
//!    used to be populated *only* by an alleycat `list_agents` probe.
//!    Every other connection path (SSH bridge, Slingshot, direct
//!    `ws://` Codex URL) left it empty, so platform code that derives
//!    presentation order by intersecting with
//!    `AgentMetadataStore::all_sorted()` silently rendered *nothing* —
//!    a connected Claude / opencode runtime would not appear in the
//!    model-picker runtime row or the session filter chips. Seeding the
//!    store from this catalog gives every known agent a label, title,
//!    sort order and capability set before any probe runs. A real probe
//!    response still wins: `upsert` replaces the seeded entry.
//!
//! 2. **Scattered allowlists.** The set of agents litter can bootstrap
//!    over its *own* SSH bridge was spelled out as a literal `match` in
//!    four different files, which drifted. It now lives in
//!    [`SSH_BRIDGE_PROBE_ORDER`] / [`SSH_BRIDGE_RECONNECT_ORDER`] and is
//!    checked against the catalog by a unit test.
//!
//! Presentation fields mirror the upstream alleycat agent manifest so a
//! seeded entry and a probed entry agree. Adding a *new* agent to
//! alleycat still needs no litter release — unknown ids fall through to
//! generic rendering exactly as before.

use crate::ffi::alleycat::{AppAgentCapabilities, AppAgentPresentation};
use crate::store::AppAgentMetadata;

/// Which transports can reach an agent from this build of litter.
///
/// This is deliberately *not* the alleycat manifest's
/// `supports_ssh_bridge` flag. That flag describes what the alleycat
/// **host** binary can do; this one describes what the litter app has
/// actually linked. Litter only depends on `alleycat-pi-bridge`,
/// `alleycat-claude-bridge` and `alleycat-opencode-bridge`, so those —
/// plus Codex, which has its own direct app-server bootstrap — are the
/// only agents its SSH path can launch. Everything else reaches the
/// host through kittylitter/alleycat pairing, where the *host* owns the
/// bridge process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentReach {
    /// Litter links a bridge (or a direct bootstrap) that can start this
    /// agent over SSH, and it also works over alleycat pairing.
    SshBridgeAndPairing,
    /// Litter has no bridge for this agent. It works only when the
    /// paired host runs it (kittylitter / Local Studio / alleycat).
    PairingOnly,
}

impl AgentReach {
    pub fn supports_ssh_bridge(self) -> bool {
        matches!(self, Self::SshBridgeAndPairing)
    }
}

/// How `probe_remote_agents` looks for an agent's CLI on an SSH host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeStyle {
    /// Agent is discovered by a dedicated script fragment rather than a
    /// plain `command -v` (currently only Local Studio, which has to
    /// locate an app bundle).
    Custom,
    /// `command -v` is enough — the binary being on PATH means the agent
    /// is usable.
    Path,
    /// The binary must also answer `--version`. opencode ships broken
    /// shims often enough that presence alone is a false positive.
    PathAndVersion,
}

pub struct AgentCatalogEntry {
    /// Canonical lowercase id. Same string alleycat advertises.
    pub name: &'static str,
    pub display_name: &'static str,
    /// Longer header title when the short label is ambiguous.
    pub title: Option<&'static str>,
    pub is_beta: bool,
    pub sort_order: i32,
    /// Blurb plus the host-side prerequisite. Surfaced to platform UI
    /// through `presentation.description`, so users see what an agent
    /// needs instead of an empty row. Replaced by the host's own
    /// description once a probe lands.
    pub description: &'static str,
    /// Short imperative sentence used in error messages when a connect
    /// or probe fails for this agent.
    pub requirement: &'static str,
    /// Alternate ids seen on the wire or in persisted server records.
    pub aliases: &'static [&'static str],
    pub locks_reasoning_effort_after_activity: bool,
    pub visible_modes: Option<&'static [&'static str]>,
    pub uses_direct_codex_port: bool,
    pub supports_thread_permission_overrides: bool,
    pub reports_effective_thread_permissions: bool,
    pub reach: AgentReach,
    pub probe_style: ProbeStyle,
    /// Candidate binaries tried in order by the SSH probe. Empty for
    /// [`ProbeStyle::Custom`] and pairing-only agents.
    pub probe_commands: &'static [&'static str],
}

impl AgentCatalogEntry {
    fn presentation(&self) -> AppAgentPresentation {
        AppAgentPresentation {
            title: self.title.map(str::to_owned),
            is_beta: self.is_beta,
            sort_order: self.sort_order,
            description: Some(self.description.to_owned()),
            aliases: self.aliases.iter().map(|alias| (*alias).to_owned()).collect(),
        }
    }

    fn capabilities(&self) -> AppAgentCapabilities {
        AppAgentCapabilities {
            locks_reasoning_effort_after_activity: self.locks_reasoning_effort_after_activity,
            visible_modes: self
                .visible_modes
                .map(|modes| modes.iter().map(|mode| (*mode).to_owned()).collect()),
            supports_ssh_bridge: self.reach.supports_ssh_bridge(),
            uses_direct_codex_port: self.uses_direct_codex_port,
            supports_thread_permission_overrides: self.supports_thread_permission_overrides,
            reports_effective_thread_permissions: self.reports_effective_thread_permissions,
        }
    }

    pub fn metadata(&self) -> AppAgentMetadata {
        AppAgentMetadata {
            name: self.name.to_owned(),
            display_name: self.display_name.to_owned(),
            presentation: Some(self.presentation()),
            capabilities: Some(self.capabilities()),
        }
    }
}

/// Sort orders and capability flags mirror the alleycat agent manifest
/// (`crates/alleycat/src/agent_manifest.rs` upstream). `local-studio` is
/// litter-specific: it is a Pi runtime scoped to a Local Studio install,
/// so alleycat never advertises it by that name.
pub const CATALOG: &[AgentCatalogEntry] = &[
    AgentCatalogEntry {
        name: "codex",
        display_name: "Codex",
        title: None,
        is_beta: false,
        sort_order: 0,
        description: "OpenAI Codex app-server. Needs the `codex` CLI on the host and a signed-in ChatGPT or API account.",
        requirement: "install the `codex` CLI on the host and sign in with `codex login`",
        aliases: &[],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: true,
        supports_thread_permission_overrides: true,
        reports_effective_thread_permissions: true,
        reach: AgentReach::SshBridgeAndPairing,
        probe_style: ProbeStyle::Path,
        probe_commands: &["codex"],
    },
    AgentCatalogEntry {
        name: "local-studio",
        display_name: "Local Studio",
        title: Some("Local Studio"),
        is_beta: false,
        sort_order: 1,
        description: "Local Studio's bundled Pi runtime. Needs the Local Studio desktop app installed on the host.",
        requirement: "install the Local Studio desktop app on the host",
        aliases: &["local_studio", "localstudio", "local studio"],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::SshBridgeAndPairing,
        probe_style: ProbeStyle::Custom,
        probe_commands: &[],
    },
    AgentCatalogEntry {
        name: "pi",
        display_name: "Pi",
        title: None,
        is_beta: true,
        sort_order: 1,
        description: "Pi coding agent. Needs the `pi-coding-agent` (or `pi`) CLI on the host.",
        requirement: "install the `pi-coding-agent` CLI on the host",
        aliases: &["pi.dev", "pidev", "pi-coding-agent"],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::SshBridgeAndPairing,
        probe_style: ProbeStyle::Path,
        probe_commands: &["pi-coding-agent", "pi"],
    },
    AgentCatalogEntry {
        name: "amp",
        display_name: "Amp",
        title: Some("Amp"),
        is_beta: true,
        sort_order: 2,
        description: "Sourcegraph Amp. Runs on the paired host — pair with kittylitter to use it.",
        requirement: "pair with kittylitter on a host that has the `amp` CLI installed",
        aliases: &["ampcode", "amp-code", "amp_code", "amp code"],
        locks_reasoning_effort_after_activity: true,
        visible_modes: Some(&["smart", "rush", "deep"]),
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::PairingOnly,
        probe_style: ProbeStyle::Path,
        probe_commands: &[],
    },
    AgentCatalogEntry {
        name: "opencode",
        display_name: "opencode",
        title: Some("Opencode"),
        is_beta: true,
        sort_order: 3,
        description: "Open-source local coding agent. Needs the `opencode` CLI on the host with a configured model provider.",
        requirement: "install the `opencode` CLI on the host and configure a model provider",
        aliases: &["open-code", "open_code", "open code"],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::SshBridgeAndPairing,
        probe_style: ProbeStyle::PathAndVersion,
        probe_commands: &["opencode"],
    },
    AgentCatalogEntry {
        name: "claude",
        display_name: "Claude",
        title: Some("Claude Code"),
        is_beta: true,
        sort_order: 4,
        description: "Anthropic Claude Code. Needs the `claude` CLI on the host and an authenticated Claude account or ANTHROPIC_API_KEY.",
        requirement: "install the `claude` CLI on the host and authenticate it (`claude` login or ANTHROPIC_API_KEY)",
        aliases: &["claude-code", "claude_code", "claude code"],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::SshBridgeAndPairing,
        probe_style: ProbeStyle::Path,
        probe_commands: &["claude"],
    },
    AgentCatalogEntry {
        name: "droid",
        display_name: "Droid",
        title: Some("Factory Droid"),
        is_beta: true,
        sort_order: 5,
        description: "Factory Droid coding agent. Runs on the paired host — pair with kittylitter to use it.",
        requirement: "pair with kittylitter on a host that has the `droid` CLI installed and signed in",
        aliases: &["factory", "factory-droid", "factory_droid", "factory droid"],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::PairingOnly,
        probe_style: ProbeStyle::Path,
        probe_commands: &[],
    },
    AgentCatalogEntry {
        name: "hermes",
        display_name: "Hermes",
        title: Some("Hermes"),
        is_beta: true,
        sort_order: 6,
        description: "Nous Research Hermes agent. Runs on the paired host — pair with kittylitter to use it.",
        requirement: "pair with kittylitter on a host that has the Hermes agent installed",
        aliases: &[],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::PairingOnly,
        probe_style: ProbeStyle::Path,
        probe_commands: &[],
    },
    AgentCatalogEntry {
        name: "devin",
        display_name: "Devin",
        title: Some("Devin"),
        is_beta: true,
        sort_order: 7,
        description: "Devin coding agent. Runs on the paired host — pair with kittylitter to use it.",
        requirement: "pair with kittylitter on a host that has the `devin` CLI installed and signed in",
        aliases: &[],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::PairingOnly,
        probe_style: ProbeStyle::Path,
        probe_commands: &[],
    },
    AgentCatalogEntry {
        name: "grok",
        display_name: "Grok",
        title: Some("Grok"),
        is_beta: true,
        sort_order: 8,
        description: "xAI Grok coding agent. Runs on the paired host — pair with kittylitter to use it.",
        requirement: "pair with kittylitter on a host that has the Grok CLI installed",
        aliases: &["grok-code", "xai-grok", "xai grok"],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::PairingOnly,
        probe_style: ProbeStyle::Path,
        probe_commands: &[],
    },
    AgentCatalogEntry {
        name: "shell",
        display_name: "Shell",
        title: Some("Shell"),
        is_beta: true,
        sort_order: 9,
        description: "PTY-backed host shell. Runs on the paired host — pair with kittylitter to use it.",
        requirement: "pair with kittylitter to reach the host shell",
        aliases: &["terminal"],
        locks_reasoning_effort_after_activity: false,
        visible_modes: None,
        uses_direct_codex_port: false,
        supports_thread_permission_overrides: false,
        reports_effective_thread_permissions: false,
        reach: AgentReach::PairingOnly,
        probe_style: ProbeStyle::Path,
        probe_commands: &[],
    },
];

/// Runtime kinds litter can bootstrap over its own SSH bridge, in the
/// order the SSH agent picker lists them. Kept explicit (rather than
/// derived by filtering [`CATALOG`]) so the user-visible ordering is
/// stable; [`tests::ssh_bridge_orders_match_catalog`] asserts it stays
/// in sync with the `reach` flags.
pub const SSH_BRIDGE_PROBE_ORDER: &[&str] =
    &["local-studio", "claude", "pi", "opencode", "codex"];

/// Same set, in the order automatic reconnect prefers when a saved
/// server did not record which runtimes it had. Claude leads because
/// it is the most common SSH-bootstrap target; Local Studio trails
/// because it is only present on hosts running the desktop app.
pub const SSH_BRIDGE_RECONNECT_ORDER: &[&str] =
    &["claude", "pi", "opencode", "codex", "local-studio"];

/// Resolve any spelling of an agent id — canonical name, manifest
/// alias, or an alleycat `name`/`display_name` pair — to its catalog
/// entry. Returns `None` for agents litter has never heard of; those
/// still work, they just render generically.
pub fn entry(name: &str) -> Option<&'static AgentCatalogEntry> {
    let key = name.trim().to_ascii_lowercase();
    if key.is_empty() {
        return None;
    }
    if let Some(found) = CATALOG.iter().find(|entry| {
        entry.name == key || entry.aliases.iter().any(|alias| *alias == key)
    }) {
        return Some(found);
    }
    let canonical = crate::alleycat::agent_runtime_kind(&key, "")?;
    CATALOG.iter().find(|entry| entry.name == canonical)
}

/// Canonical runtime kind for any spelling litter knows, falling back to
/// [`crate::alleycat::agent_runtime_kind`] for ids that only alleycat
/// knows about. `None` only for blank input.
pub fn canonical_kind(name: &str) -> Option<String> {
    if let Some(entry) = entry(name) {
        return Some(entry.name.to_owned());
    }
    crate::alleycat::agent_runtime_kind(name, "")
}

/// Whether *this build* of litter can start the agent over its own SSH
/// bridge. Unknown agents answer `false`: litter has no bridge for them,
/// so they are pairing-only by definition.
pub fn supports_ssh_bridge(name: &str) -> bool {
    entry(name).is_some_and(|entry| entry.reach.supports_ssh_bridge())
}

/// Human-readable prerequisite, used to turn "connect failed" into
/// "connect failed — install X". `None` for unknown agents.
pub fn requirement(name: &str) -> Option<&'static str> {
    entry(name).map(|entry| entry.requirement)
}

/// Best known label for an agent id before any probe has landed.
pub fn display_name(name: &str) -> Option<&'static str> {
    entry(name).map(|entry| entry.display_name)
}

/// Seed set for [`crate::store::AgentMetadataStore`].
pub fn seed_metadata() -> Vec<AppAgentMetadata> {
    CATALOG.iter().map(AgentCatalogEntry::metadata).collect()
}

/// POSIX `sh` fragment that reports one `<kind>\t<path>` line per
/// PATH-probed SSH-bridge agent. Local Studio is excluded — it has its
/// own `crate::local_studio::probe_script()` fragment, which
/// `probe_remote_agents` emits alongside this one.
///
/// Assumes the helper functions `probe_one` / `probe_one_executes` are
/// already defined in the surrounding script.
pub fn ssh_probe_script_lines() -> String {
    SSH_BRIDGE_PROBE_ORDER
        .iter()
        .filter_map(|kind| entry(kind))
        .filter(|entry| !entry.probe_commands.is_empty())
        .map(|entry| {
            let helper = match entry.probe_style {
                ProbeStyle::PathAndVersion => "probe_one_executes",
                _ => "probe_one",
            };
            format!("{helper} {} {}", entry.name, entry.probe_commands.join(" "))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn ssh_bridge_orders_match_catalog() {
        let expected = CATALOG
            .iter()
            .filter(|entry| entry.reach.supports_ssh_bridge())
            .map(|entry| entry.name)
            .collect::<HashSet<_>>();
        assert_eq!(
            SSH_BRIDGE_PROBE_ORDER.iter().copied().collect::<HashSet<_>>(),
            expected,
            "SSH_BRIDGE_PROBE_ORDER drifted from the catalog `reach` flags"
        );
        assert_eq!(
            SSH_BRIDGE_RECONNECT_ORDER
                .iter()
                .copied()
                .collect::<HashSet<_>>(),
            expected,
            "SSH_BRIDGE_RECONNECT_ORDER drifted from the catalog `reach` flags"
        );
    }

    #[test]
    fn catalog_ids_and_aliases_are_unique() {
        let mut seen = HashSet::new();
        for entry in CATALOG {
            assert!(seen.insert(entry.name), "duplicate agent id {}", entry.name);
            for alias in entry.aliases {
                assert!(
                    seen.insert(alias),
                    "alias {alias} collides with another agent id"
                );
            }
        }
    }

    #[test]
    fn entry_resolves_aliases_and_canonical_kinds() {
        assert_eq!(entry("claude-code").map(|e| e.name), Some("claude"));
        assert_eq!(entry("CLAUDE_CODE").map(|e| e.name), Some("claude"));
        assert_eq!(entry("factory-droid").map(|e| e.name), Some("droid"));
        assert_eq!(entry("local_studio").map(|e| e.name), Some("local-studio"));
        assert_eq!(entry("pi.dev").map(|e| e.name), Some("pi"));
        assert_eq!(entry("  Opencode ").map(|e| e.name), Some("opencode"));
        assert_eq!(entry("nope-agent").map(|e| e.name), None);
        assert_eq!(entry("").map(|e| e.name), None);
    }

    #[test]
    fn canonical_kind_passes_unknown_agents_through() {
        assert_eq!(canonical_kind("open-code").as_deref(), Some("opencode"));
        assert_eq!(
            canonical_kind("Custom-Agent").as_deref(),
            Some("custom-agent")
        );
        assert_eq!(canonical_kind("   "), None);
    }

    #[test]
    fn ssh_bridge_support_covers_claude_and_opencode_but_not_pairing_only_agents() {
        for kind in ["codex", "claude", "claude-code", "pi", "opencode", "local-studio"] {
            assert!(supports_ssh_bridge(kind), "{kind} should be SSH-bridgeable");
        }
        for kind in ["droid", "factory-droid", "devin", "amp", "hermes", "grok", "shell"] {
            assert!(
                !supports_ssh_bridge(kind),
                "{kind} has no litter-side bridge and must stay pairing-only"
            );
        }
        assert!(!supports_ssh_bridge("brand-new-agent"));
    }

    #[test]
    fn every_agent_states_what_it_needs() {
        for entry in CATALOG {
            assert!(
                !entry.requirement.trim().is_empty(),
                "{} has no requirement text",
                entry.name
            );
            assert!(
                !entry.description.trim().is_empty(),
                "{} has no description",
                entry.name
            );
        }
        assert!(requirement("claude").is_some_and(|text| text.contains("claude")));
        assert!(requirement("droid").is_some_and(|text| text.contains("kittylitter")));
        assert_eq!(requirement("brand-new-agent"), None);
    }

    #[test]
    fn ssh_probe_script_covers_every_path_probed_bridge_agent() {
        let script = ssh_probe_script_lines();
        assert!(script.contains("probe_one claude claude"));
        assert!(script.contains("probe_one pi pi-coding-agent pi"));
        assert!(script.contains("probe_one_executes opencode opencode"));
        assert!(script.contains("probe_one codex codex"));
        // Local Studio has its own probe fragment and must not be
        // double-probed here.
        assert!(!script.contains("local-studio"));
        // Pairing-only agents must never be probed over SSH — showing
        // them as "available" would offer a connection litter cannot make.
        for pairing_only in ["droid", "devin", "amp", "hermes", "grok", "shell"] {
            assert!(
                !script.contains(pairing_only),
                "{pairing_only} is pairing-only and must not appear in the SSH probe"
            );
        }
    }

    #[test]
    fn seed_metadata_carries_presentation_and_capabilities() {
        let seeded = seed_metadata();
        assert_eq!(seeded.len(), CATALOG.len());
        let claude = seeded
            .iter()
            .find(|entry| entry.name == "claude")
            .expect("claude seeded");
        let presentation = claude.presentation.as_ref().expect("presentation");
        assert_eq!(presentation.title.as_deref(), Some("Claude Code"));
        assert_eq!(presentation.sort_order, 4);
        assert!(presentation.description.is_some());
        let capabilities = claude.capabilities.as_ref().expect("capabilities");
        assert!(capabilities.supports_ssh_bridge);

        let droid = seeded
            .iter()
            .find(|entry| entry.name == "droid")
            .expect("droid seeded");
        assert!(
            !droid
                .capabilities
                .as_ref()
                .expect("capabilities")
                .supports_ssh_bridge,
            "droid has no litter-side SSH bridge"
        );
    }

    #[test]
    fn amp_visible_modes_survive_seeding() {
        let amp = seed_metadata()
            .into_iter()
            .find(|entry| entry.name == "amp")
            .expect("amp seeded");
        assert_eq!(
            amp.capabilities
                .and_then(|capabilities| capabilities.visible_modes),
            Some(vec!["smart".to_string(), "rush".to_string(), "deep".to_string()])
        );
    }
}
