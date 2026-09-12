import Foundation
import SwiftUI
import UIKit

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
///
/// Reads go through `AgentMetadataMemo`, never straight to these
/// closures — each raw call crosses the UniFFI boundary and lifts a
/// fresh `AppAgentMetadata` (nested `presentation` + `capabilities`
/// records) out of a `RustBuffer`.
enum AgentRuntimeMetadataProvider {
    static var lookup: ((String) -> AppAgentMetadata?)? {
        didSet { AgentMetadataMemo.invalidate() }
    }

    static var all: (() -> [AppAgentMetadata])? {
        didSet { AgentMetadataMemo.invalidate() }
    }
}

/// Main-thread memo in front of the Rust-owned `AgentMetadataStore`.
///
/// Agent labels, icons, badges and capability flags are read once per
/// model per derivation, and pickers re-derive several times per body
/// pass — so an uncached `metadata` lookup turned a single keystroke in
/// the model search field into hundreds of synchronous FFI hops.
///
/// **Invalidation.** The memo is scoped to a single main run-loop turn.
/// A `CFRunLoopObserver` empties it on `.afterWaiting` (the moment the
/// loop wakes, before the main-queue drain that delivers store updates),
/// on `.beforeWaiting` at an order above CoreAnimation's commit observer
/// (once the frame has been rendered), and on `.exit`. Nothing cached
/// here can therefore survive into a later frame, and a metadata upsert
/// — which happens in Rust and only reaches the UI via a store update
/// delivered on the main queue — always lands after a drain point.
/// Assigning a new provider closure clears the memo eagerly too.
/// Off-main reads bypass the memo entirely, which keeps the storage
/// single-threaded and lock-free.
enum AgentMetadataMemo {
    private static var metadataByKind: [String: AppAgentMetadata?] = [:]
    private static var visibleModesByKind: [String: Set<String>?] = [:]
    private static var directoryOrder: [String]?
    private static var directoryFingerprint: Int?
    private static var observerInstalled = false

    static func metadata(for kind: String) -> AppAgentMetadata? {
        guard Thread.isMainThread else {
            return AgentRuntimeMetadataProvider.lookup?(kind)
        }
        installObserverIfNeeded()
        if let cached = metadataByKind[kind] {
            return cached
        }
        let resolved = AgentRuntimeMetadataProvider.lookup?(kind)
        metadataByKind[kind] = resolved
        return resolved
    }

    static func visibleModes(for kind: String) -> Set<String>? {
        guard Thread.isMainThread else {
            return AgentRuntimeMetadataProvider.lookup?(kind)?.capabilities?.visibleModes.map(Set.init)
        }
        installObserverIfNeeded()
        if let cached = visibleModesByKind[kind] {
            return cached
        }
        let resolved = metadata(for: kind)?.capabilities?.visibleModes.map(Set.init)
        visibleModesByKind[kind] = resolved
        return resolved
    }

    static func presentationOrder() -> [String] {
        guard Thread.isMainThread else {
            return AgentRuntimeMetadataProvider.all?().map(\.name) ?? []
        }
        installObserverIfNeeded()
        loadDirectoryIfNeeded()
        return directoryOrder ?? []
    }

    /// Cheap identity of the whole agent directory. Callers that cache
    /// metadata-derived work across frames key on this so a probe
    /// response (new agent, changed label, changed capabilities)
    /// invalidates their cache.
    static func fingerprint() -> Int {
        guard Thread.isMainThread else {
            return computeFingerprint(AgentRuntimeMetadataProvider.all?() ?? []).1
        }
        installObserverIfNeeded()
        loadDirectoryIfNeeded()
        return directoryFingerprint ?? 0
    }

    static func invalidate() {
        if Thread.isMainThread {
            clear()
        } else {
            DispatchQueue.main.async { clear() }
        }
    }

    private static func loadDirectoryIfNeeded() {
        guard directoryOrder == nil else { return }
        let entries = AgentRuntimeMetadataProvider.all?() ?? []
        let (order, fingerprint) = computeFingerprint(entries)
        directoryOrder = order
        directoryFingerprint = fingerprint
    }

    private static func computeFingerprint(_ entries: [AppAgentMetadata]) -> ([String], Int) {
        var hasher = Hasher()
        var order: [String] = []
        order.reserveCapacity(entries.count)
        for entry in entries {
            order.append(entry.name)
            hasher.combine(entry.name)
            hasher.combine(entry.displayName)
            hasher.combine(entry.presentation?.title)
            hasher.combine(entry.presentation?.isBeta)
            hasher.combine(entry.presentation?.sortOrder)
            hasher.combine(entry.capabilities?.visibleModes)
            hasher.combine(entry.capabilities?.supportsThreadPermissionOverrides)
            hasher.combine(entry.capabilities?.reportsEffectiveThreadPermissions)
        }
        return (order, hasher.finalize())
    }

    private static func clear() {
        metadataByKind.removeAll(keepingCapacity: true)
        visibleModesByKind.removeAll(keepingCapacity: true)
        directoryOrder = nil
        directoryFingerprint = nil
    }

    private static func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        // `afterWaiting` drops everything the moment the loop wakes —
        // before the main-queue drain that delivers store updates — and
        // `beforeWaiting` at an order above CoreAnimation's commit
        // observer (2_000_000) drops it again once the frame has been
        // rendered. So the memo is warm for exactly one render pass.
        guard let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue
                | CFRunLoopActivity.beforeWaiting.rawValue
                | CFRunLoopActivity.exit.rawValue,
            true,
            3_000_000,
            { _, _ in clear() }
        ) else {
            return
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
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
        AgentMetadataMemo.presentationOrder()
    }

    /// Identity of the whole agent directory. Views that cache
    /// metadata-derived work (model buckets, search indexes, provider
    /// groups) key on this so a probe response invalidates them.
    static var metadataFingerprint: Int {
        AgentMetadataMemo.fingerprint()
    }

    var metadata: AppAgentMetadata? {
        AgentMetadataMemo.metadata(for: self)
    }

    /// Allowlist of model "mode" names this agent advertises (e.g. Amp's
    /// `smart` / `rush` / `deep`), from `capabilities.visible_modes`.
    /// `nil` when the agent does not use modes at all.
    var visibleModeNames: Set<String>? {
        AgentMetadataMemo.visibleModes(for: self)
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
    ///
    /// Memoized: `UIImage(named:)` does not cache a *negative* result,
    /// so every render of an agent without a bundled icon re-searched
    /// the whole bundle.
    var bundledAssetName: String? {
        AgentAssetCatalogMemo.assetName(for: self)
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
        return AgentMetadataMemo.metadata(for: key)?.presentation?.isBeta ?? true
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

/// Memo for `agent_<id>` asset-catalog lookups, including negative
/// results.
///
/// **Invalidation.** None is needed, and none is possible to get wrong:
/// the asset catalog is compiled into the app bundle at build time and
/// litter never registers images at runtime (no `NSBundleResourceRequest`
/// / on-demand resources anywhere in the app), so `UIImage(named:)` for
/// a fixed name is a pure function of the bundle for the whole process
/// lifetime. Off-main callers bypass the memo so the storage stays
/// single-threaded.
private enum AgentAssetCatalogMemo {
    private static var resolved: [String: String?] = [:]

    static func assetName(for kind: String) -> String? {
        guard Thread.isMainThread else { return lookup(kind) }
        if let cached = resolved[kind] { return cached }
        let value = lookup(kind)
        resolved[kind] = value
        return value
    }

    private static func lookup(_ kind: String) -> String? {
        let candidate = "agent_\(kind)"
        return UIImage(named: candidate) != nil ? candidate : nil
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
