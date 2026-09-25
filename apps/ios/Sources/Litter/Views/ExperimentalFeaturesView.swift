import SwiftUI

struct ExperimentalFeaturesView: View {
    @State private var experimentalFeatures = ExperimentalFeatures.shared
    @State private var debugSettings = DebugSettings.shared

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            Form {
                Section {
                    ForEach(LitterFeature.allCases) { feature in
                        Toggle(isOn: binding(for: feature)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.displayName)
                                    .litterFont(.body)
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text(feature.description)
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                        .tint(LitterTheme.accentStrong)
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                } header: {
                    Text("Features")
                        .litterSectionLabel()
                } footer: {
                    Text("Experimental features may be unstable or change without notice.")
                        .foregroundColor(LitterTheme.textMuted)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { debugSettings.enabled },
                        set: { debugSettings.enabled = $0 }
                    )) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Debug Mode")
                                    .litterFont(.body)
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text("Show debug controls in conversations")
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                    }
                    .tint(LitterTheme.accent)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                } header: {
                    Text("Debug")
                        .litterSectionLabel()
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Experimental")
        .navigationBarTitleDisplayMode(.inline)
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

#if DEBUG
#Preview("Experimental Features") {
    NavigationStack {
        ExperimentalFeaturesView()
    }
}
#endif
