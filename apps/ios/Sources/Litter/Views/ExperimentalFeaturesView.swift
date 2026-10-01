import SwiftUI

/// Experimental feature toggles plus debug mode, shown inline on the
/// Settings "Advanced" page.
struct ExperimentalFeatureSections: View {
    @State private var experimentalFeatures = ExperimentalFeatures.shared
    @State private var debugSettings = DebugSettings.shared

    var body: some View {
        Section {
            ForEach(LitterFeature.allCases) { feature in
                Toggle(isOn: binding(for: feature)) {
                    SettingsRowText(title: feature.displayName, subtitle: feature.description)
                }
                .tint(LitterTheme.accent)
                .settingsRowBackground()
            }
        } header: {
            SettingsSectionHeader("Experimental")
        } footer: {
            Text("Experimental features may be unstable or change without notice.")
                .litterFont(.footnote)
                .foregroundColor(LitterTheme.textMuted)
        }

        Section {
            Toggle(isOn: Binding(
                get: { debugSettings.enabled },
                set: { debugSettings.enabled = $0 }
            )) {
                SettingsRowText(title: "Debug mode", subtitle: "Show debug controls in conversations")
            }
            .tint(LitterTheme.accent)
            .settingsRowBackground()
        }
    }

    private func binding(for feature: LitterFeature) -> Binding<Bool> {
        Binding(
            get: { experimentalFeatures.isEnabled(feature) },
            set: { newValue in
                experimentalFeatures.setEnabled(feature, newValue)
            }
        )
    }
}
