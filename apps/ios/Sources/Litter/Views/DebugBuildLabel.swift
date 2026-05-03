import SwiftUI

enum BuildInfo {
    /// True only for installs that came from the App Store production
    /// listing (App Store receipt, no embedded provisioning profile, not
    /// simulator, not Debug). TestFlight, dev sideloads, and simulator all
    /// return false.
    static var isAppStoreProduction: Bool {
        #if DEBUG
        return false
        #else
        #if targetEnvironment(simulator)
        return false
        #else
        if Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil {
            return false
        }
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "receipt"
        #endif
        #endif
    }

    static var marketingVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// "1.5.0 · 53306" — last 5 chars of the build number with leading
    /// zeros stripped. Returns nil if either value is missing.
    static var shortLabel: String? {
        guard let marketing = marketingVersion, let build = buildNumber else { return nil }
        let suffix = String(build.suffix(5))
        let trimmed = suffix.drop(while: { $0 == "0" })
        let shortBuild = trimmed.isEmpty ? "0" : String(trimmed)
        return "\(marketing) · \(shortBuild)"
    }
}

struct DebugBuildLabel: View {
    var body: some View {
        if !BuildInfo.isAppStoreProduction, let label = BuildInfo.shortLabel {
            Text(label)
                .litterFont(.caption2)
                .foregroundColor(LitterTheme.textMuted.opacity(0.55))
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}
