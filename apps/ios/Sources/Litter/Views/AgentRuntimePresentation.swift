import SwiftUI

/// Bridge alias: Rust exposes agent identity as an opaque `String` (the
/// lowercase id alleycat advertises). The legacy `AgentRuntimeKind`
/// name is kept as a type alias so call sites compile; ALL agent
/// metadata — label, icon, BETA badge, sort order, capability flags —
/// comes from `AgentMetadataStore` keyed by id. There is no hardcoded
/// catalog of agent names in litter, so adding a new agent only
/// requires an entry in the alleycat manifest.
typealias AgentRuntimeKind = String

/// Lookup hook into the Rust-owned `AgentMetadataStore`. Wired up at
/// app launch in `LitterApp` so any view can resolve an `AgentId` to
/// its metadata. Returns `nil` before the first probe response.
enum AgentRuntimeMetadataProvider {
    static var lookup: ((String) -> AppAgentMetadata?)?
    static var all: (() -> [AppAgentMetadata])?
}

extension AgentRuntimeKind {
    static let claude: AgentRuntimeKind = "claude"
    static let codex: AgentRuntimeKind = "codex"
    static let devin: AgentRuntimeKind = "devin"
    static let droid: AgentRuntimeKind = "droid"
    static let opencode: AgentRuntimeKind = "opencode"
    static let localStudio: AgentRuntimeKind = "local-studio"

    /// Presentation order surfaced by `AgentMetadataStore` (sorted by
    /// each agent's `presentation.sort_order` from the alleycat
    /// manifest). Empty when no probe has populated the cache yet —
    /// callers should treat that as "no agents available."
    static var presentationOrder: [AgentRuntimeKind] {
        AgentRuntimeMetadataProvider.all?().map(\.name) ?? []
    }

    var metadata: AppAgentMetadata? {
        AgentRuntimeMetadataProvider.lookup?(self)
    }

    /// Short label used in lists. Prefers metadata `display_name`;
    /// falls back to a titlecased id so the UI never shows a blank
    /// label during the brief window between server connect and probe
    /// completion.
    var displayLabel: String {
        if self == Self.localStudio {
            return "Local Studio"
        }
        if let meta = metadata, !meta.displayName.isEmpty {
            return meta.displayName
        }
        return titlecased
    }

    /// Header / title rendering. Prefers metadata `presentation.title`
    /// (e.g. "Factory Droid") over the short label.
    var titleDisplayLabel: String {
        if let title = metadata?.presentation?.title, !title.isEmpty {
            return title
        }
        return displayLabel
    }

    /// Sort index. Prefers metadata `sort_order`; otherwise drops to
    /// the end, tie-broken by name.
    var presentationSortIndex: Int {
        if let order = metadata?.presentation?.sortOrder {
            return Int(order)
        }
        return Int.max
    }

    /// BETA badge driven by `presentation.is_beta` from alleycat. Codex is
    /// always treated as stable, including cold-start SSH/alleycat paths where
    /// metadata may not be cached yet. Other unknown agents stay beta by
    /// default until metadata says otherwise.
    var isBeta: Bool {
        if Self.isStableAgentIdentity(self, displayName: "") {
            return false
        }
        return metadata?.presentation?.isBeta ?? true
    }

    /// Whether this runtime accepts client-side thread permission overrides.
    /// Older daemons did not advertise the capability, so default to the
    /// historical behaviour until a runtime explicitly opts out.
    var supportsThreadPermissionOverrides: Bool {
        !Self.hasFixedFullAccess(self) &&
            (metadata?.capabilities?.supportsThreadPermissionOverrides ?? true)
    }

    /// Whether this runtime reports effective thread permissions that the UI
    /// can present as authoritative runtime state.
    var reportsEffectiveThreadPermissions: Bool {
        !Self.hasFixedFullAccess(self) &&
            (metadata?.capabilities?.reportsEffectiveThreadPermissions ?? true)
    }

    static func hasFixedFullAccess(_ runtime: String) -> Bool {
        runtime == "pi" || runtime == "local-studio"
    }

    /// Asset catalog name for this agent's bundled icon, by convention
    /// `agent_<id>`. Returns `nil` when no matching `UIImage(named:)`
    /// is bundled — callers fall back to a monogram chip via
    /// `AgentIconView`. Litter ships icons for the agents it knows
    /// about (codex, claude, etc.) and renders a monogram for anything
    /// new that alleycat advertises.
    var bundledAssetName: String? {
        let candidate = "agent_\(self)"
        return UIImage(named: candidate) != nil ? candidate : nil
    }

    /// Picker / add-server callers check whether an agent should show
    /// a BETA badge before its metadata has been promoted into the
    /// store. With no enum to consult, defer entirely to the cached
    /// metadata; unknown agents are beta by default except Codex.
    static func isBetaAgentName(_ name: String, displayName: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isStableAgentIdentity(key, displayName: displayName) {
            return false
        }
        return AgentRuntimeMetadataProvider.lookup?(key)?.presentation?.isBeta ?? true
    }

    private static func isStableAgentIdentity(_ name: String, displayName: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName == "codex"
            || normalizedName == "local-studio"
            || normalizedDisplayName == "codex"
            || normalizedDisplayName == "local studio"
    }

    private var titlecased: String {
        guard !isEmpty else { return "Agent" }
        return prefix(1).uppercased() + dropFirst()
    }
}

/// Renders an agent's icon from the local asset catalog (`agent_<id>`)
/// when one is bundled, otherwise falls back to a monogram letter chip.
/// Use this everywhere instead of `Image(kind.assetName)` — it keeps
/// new alleycat-advertised agents renderable without shipping a litter
/// release first.
struct AgentIconView: View {
    let kind: AgentRuntimeKind
    var size: CGFloat = 24

    var body: some View {
        if let assetName = kind.bundledAssetName {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            AgentMonogramView(kind: kind, size: size)
        }
    }
}

/// Letter-based fallback when no icon is cached. Renders the first
/// character of the agent id in the accent color over a dark chip —
/// good enough for cold-start before the first probe completes.
struct AgentMonogramView: View {
    let kind: AgentRuntimeKind
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.2)
                        .stroke(LitterTheme.textPrimary.opacity(0.25), lineWidth: 0.5)
                )
            Text(monogramLetter)
                .font(.system(size: size * 0.6, weight: .semibold, design: .monospaced))
                .foregroundColor(LitterTheme.accent)
        }
        .frame(width: size, height: size)
    }

    private var monogramLetter: String {
        kind.first.map { String($0).uppercased() } ?? "?"
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .litterFont(.caption2)
            .foregroundColor(LitterTheme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(LitterTheme.accent.opacity(0.6), lineWidth: 0.5)
            )
    }
}
