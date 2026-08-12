import Foundation
import SwiftUI
import UIKit

enum LitterPlatform {
#if targetEnvironment(macCatalyst)
    static let isCatalyst = true
#else
    static let isCatalyst = false
#endif

    /// `true` only on the unsandboxed Mac Catalyst lane (Developer ID
    /// notarized .dmg). Sandboxed Catalyst (Mac App Store) always sets
    /// `APP_SANDBOX_CONTAINER_ID`, so its absence on a Catalyst process
    /// is a reliable indicator that the App Sandbox is off and we can
    /// spawn child processes (codex app-server, etc.).
    static let isDirectDistMac: Bool = {
        guard isCatalyst else { return false }
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }()

    /// `true` whenever the process renders as a Mac app — Catalyst or
    /// "Designed for iPad" on Apple Silicon. AppKit-bridge bugs hit
    /// both modes (NSVisualEffectView ignoring `fractionComplete=0`,
    /// NavigationSplitView Liquid Glass material being clobbered by
    /// gradient backdrops, menu-equivalent shortcuts not firing in-view),
    /// so UI workarounds gate on this rather than the compile-time
    /// `targetEnvironment(macCatalyst)` flag — the iOS lane in
    /// "Designed for iPad" mode hits the same AppKit bridge.
    static let rendersAsMacApp: Bool = {
        if isCatalyst { return true }
        return ProcessInfo.processInfo.isiOSAppOnMac
    }()

    static let supportsLocalRuntime = !isCatalyst
    static let supportsVoiceRuntime = !isCatalyst

    private enum LocalRuntimeBootstrapState {
        case idle
        case starting
        case ready
    }

    private nonisolated(unsafe) static var bootstrapState: LocalRuntimeBootstrapState = .idle
    private static let bootstrapLock = NSLock()

    static func bootstrapLocalRuntimeIfNeeded() {
#if !targetEnvironment(macCatalyst)
        guard beginLocalRuntimeBootstrap() else { return }

        migrateWorkDirIfHostPath()
        let fm = FileManager.default
        guard let bundleFs = Bundle.main.url(forResource: "fs", withExtension: nil) else {
            NSLog("[ish] bundled fs not found")
            finishLocalRuntimeBootstrap(.idle)
            return
        }
        let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        guard let appSupport, let docs else {
            NSLog("[ish] could not resolve sandbox dirs")
            finishLocalRuntimeBootstrap(.idle)
            return
        }
        let bundlePath = bundleFs.path
        let appSupportPath = appSupport.path
        let docsPath = docs.path
        // First-launch rootfs extraction can take 10-30s. Bootstrapping
        // synchronously on the main actor froze the UI and made the
        // Terminal route race the kernel boot. Run it on a background
        // queue and let `instance_or_wait` on the Rust side handle the
        // race so the UI stays responsive.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ishBootstrap(
                    bundleFsPath: bundlePath,
                    applicationSupportDir: appSupportPath,
                    documentsDir: docsPath
                )
                finishLocalRuntimeBootstrap(.ready)
                Task { @MainActor in
                    await UserMountStore.shared.loadAndRemountAll()
                }
            } catch {
                NSLog("[ish] bootstrap failed: \(error)")
                finishLocalRuntimeBootstrap(.idle)
            }
        }
#endif
    }

    private static func beginLocalRuntimeBootstrap() -> Bool {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        switch bootstrapState {
        case .idle:
            bootstrapState = .starting
            return true
        case .starting, .ready:
            return false
        }
    }

    private static func finishLocalRuntimeBootstrap(_ state: LocalRuntimeBootstrapState) {
        bootstrapLock.lock()
        bootstrapState = state
        bootstrapLock.unlock()
    }

    /// iSH cannot see iOS sandbox paths. If the persisted `workDir` is one
    /// (carried over from an older build that ran shell commands directly in
    /// the iOS sandbox, or from the @AppStorage default), reset it to a
    /// fakefs-internal path so the model doesn't waste a cd-probe round-trip
    /// on every fresh turn.
    private static func migrateWorkDirIfHostPath() {
        let key = "workDir"
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        let hostPrefixes = ["/var/", "/private/", "/Users/", "/Library/", "/System/", "/Applications/"]
        let isHostPath = hostPrefixes.contains { stored.hasPrefix($0) }
        if stored.isEmpty || isHostPath {
            UserDefaults.standard.set("/root", forKey: key)
        }
    }

    static func defaultLocalWorkingDirectory() -> String {
#if targetEnvironment(macCatalyst)
        return NSHomeDirectory()
#else
        return ishDefaultCwd()
#endif
    }

    static func localRuntimeDisplayName() -> String {
#if targetEnvironment(macCatalyst)
        for candidate in [
            ProcessInfo.processInfo.hostName,
            ProcessInfo.processInfo.environment["HOSTNAME"],
            "Local Mac"
        ] {
            if let displayName = normalizedHostDisplayName(candidate) {
                return displayName
            }
        }
        return "Local Mac"
#else
        let device = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return device.isEmpty ? "This Device" : device
#endif
    }

#if targetEnvironment(macCatalyst)
    private static func normalizedHostDisplayName(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.hasSuffix(".local") {
            value.removeLast(".local".count)
        } else if let dotIndex = value.firstIndex(of: ".") {
            value = String(value[..<dotIndex])
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
#endif

    static func isRegularSurface(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        // Some current iPhone simulator/device combinations report a regular
        // horizontal size class while still rendering as a phone. Treating
        // that as a split-view surface leaves the conversation in a narrow
        // detail column beside a mostly empty sidebar. Phone navigation stays
        // single-column in either orientation; split navigation is for iPad
        // and Mac only.
        if rendersAsMacApp { return true }
        return UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }
}
