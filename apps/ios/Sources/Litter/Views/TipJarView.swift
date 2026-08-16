import SwiftUI
import StoreKit

struct TipJarView: View {
    private var store: TipJarStore { TipJarStore.shared }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()

            Form {
                headerSection

                if store.isLoading {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                } else {
                    tipsSection
                    if !store.purchasedTiers.isEmpty {
                        headerKittySelectionSection
                    }
                    restoreSection
                }

                if store.purchaseState == .purchased {
                    thankYouSection
                }

                if case .failed(let message) = store.purchaseState {
                    Section {
                        Text(message)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.danger)
                            .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                }
            }
            .scrollContentBackground(.hidden)

            if store.purchaseState == .purchasing {
                Color.black.opacity(0.3).ignoresSafeArea()
                ProgressView()
                    .tint(LitterTheme.accent)
                    .scaleEffect(1.2)
            }
        }
        .navigationTitle("Tip the Kitty")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadProducts()
        }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 8) {
                if let tier = store.supporterTier {
                    TipCatIcon(name: tier.icon, size: 120)
                    Text("You're a supporter! Thank you.")
                        .litterFont(.subheadline, weight: .semibold)
                        .foregroundColor(LitterTheme.accent)
                } else {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 28))
                        .foregroundColor(LitterTheme.accent)
                }
                Text("If you enjoy Litter, consider leaving a tip. Tips help support ongoing development and are entirely optional.")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
    }

    private var tipsSection: some View {
        Section {
            ForEach(store.tiers) { tier in
                if tier.isPurchased {
                    HStack(spacing: 12) {
                        TipCatIcon(name: tier.icon, size: 48)
                        Text(tier.displayName)
                            .litterFont(.subheadline)
                            .foregroundColor(LitterTheme.textPrimary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(LitterTheme.accent)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                } else {
                    Button {
                        Task { await store.purchase(tier) }
                    } label: {
                        HStack(spacing: 12) {
                            TipCatIcon(name: tier.icon, size: 48)
                            Text(tier.displayName)
                                .litterFont(.subheadline)
                                .foregroundColor(LitterTheme.textPrimary)
                            Spacer()
                            Text(tier.displayPrice)
                                .litterFont(.subheadline, weight: .semibold)
                                .foregroundColor(LitterTheme.accent)
                        }
                    }
                    .padding(.vertical, 4)
                    .disabled(store.purchaseState == .purchasing)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            }
        } header: {
            Text("Tip Jar")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    private var headerKittySelectionSection: some View {
        Section {
            ForEach(store.purchasedTiers) { tier in
                Button {
                    store.setHeaderKitty(tier, selected: !store.isHeaderKittySelected(tier))
                } label: {
                    HStack(spacing: 12) {
                        TipCatIcon(name: tier.icon, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.displayName)
                                .litterFont(.subheadline)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text(store.isHeaderKittySelected(tier) ? "Shown on home" : "Hidden from home")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: store.isHeaderKittySelected(tier) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(store.isHeaderKittySelected(tier) ? LitterTheme.accent : LitterTheme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            Text("Home Header")
                .foregroundColor(LitterTheme.textSecondary)
        } footer: {
            Text("Pick which purchased kitties appear around the home logo.")
                .foregroundColor(LitterTheme.textMuted)
        }
    }

    private var restoreSection: some View {
        Section {
            Button {
                Task { await store.restorePurchases() }
            } label: {
                Text("Restore Purchases")
                    .litterFont(.subheadline)
                    .foregroundColor(LitterTheme.accent)
                    .frame(maxWidth: .infinity)
            }
            .disabled(store.purchaseState == .purchasing)
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
    }

    private var thankYouSection: some View {
        Section {
            VStack(spacing: 6) {
                Text("Thank you!")
                    .litterFont(.subheadline, weight: .semibold)
                    .foregroundColor(LitterTheme.accent)
                Text("Your support means a lot.")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
        .transition(.opacity)
    }
}

/// Renders purchased kitty icons for a tier range (e.g. 0..<2 = lower tiers,
/// 2..<4 = higher tiers) next to the home logo. Collapses to nothing for
/// ranges with no purchased tiers. `loadProducts` is called by the host
/// screen so this stays a pure read.
struct SupporterKittyBadges: View {
    let tierIndices: Range<Int>
    @State private var showTipJar = false

    var body: some View {
        let store = TipJarStore.shared
        let purchased = store.tiers.enumerated()
            .filter { tierIndices.contains($0.offset) && store.isHeaderKittySelected($0.element) }
            .map(\.element)
        if !purchased.isEmpty {
            HStack(spacing: 2) {
                ForEach(purchased, id: \.id) { tier in
                    Button { showTipJar = true } label: {
                        Image(tier.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showTipJar) {
                NavigationStack {
                    TipJarView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showTipJar = false }
                                    .foregroundColor(LitterTheme.accent)
                            }
                        }
                }
            }
        }
    }
}

private struct TipCatIcon: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Image(name)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size * 0.9, height: size * 0.9)
            .frame(width: size, height: size)
            .modifier(GlassCircleModifier())
    }
}
