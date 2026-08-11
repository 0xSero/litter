import StoreKit

struct TipTier: Identifiable {
    let id: String
    let displayName: String
    let fallbackPrice: String
    let icon: String
    var product: Product?
    var isPurchased: Bool = false

    var displayPrice: String {
        product?.displayPrice ?? fallbackPrice
    }
}

@MainActor
@Observable
final class TipJarStore {
    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case purchased
        case failed(String)
    }

    private(set) var tiers: [TipTier] = [
        TipTier(id: "com.sigkitten.litter.tip.10", displayName: "$9.99 Tip", fallbackPrice: "$9.99", icon: "tip_cat_10"),
        TipTier(id: "com.sigkitten.litter.tip.25", displayName: "$24.99 Tip", fallbackPrice: "$24.99", icon: "tip_cat_25"),
        TipTier(id: "com.sigkitten.litter.tip.50", displayName: "$49.99 Tip", fallbackPrice: "$49.99", icon: "tip_cat_50"),
        TipTier(id: "com.sigkitten.litter.tip.100", displayName: "$99.99 Tip", fallbackPrice: "$99.99", icon: "tip_cat_100"),
    ]
    private(set) var purchaseState: PurchaseState = .idle
    private(set) var isLoading = true
    private(set) var selectedHeaderTierIDs: Set<String>?
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?

    static let shared = TipJarStore()
    private static let selectedHeaderTierIDsKey = "tipJar.selectedHeaderTierIDs"

    /// The highest purchased tier, or nil if none.
    var supporterTier: TipTier? {
        tiers.last(where: \.isPurchased)
    }

    var purchasedTiers: [TipTier] {
        tiers.filter(\.isPurchased)
    }

    var selectedHeaderTiers: [TipTier] {
        guard let selectedHeaderTierIDs else { return purchasedTiers }
        return purchasedTiers.filter { selectedHeaderTierIDs.contains($0.id) }
    }

    init() {
        if let ids = UserDefaults.standard.array(forKey: Self.selectedHeaderTierIDsKey) as? [String] {
            selectedHeaderTierIDs = Set(ids)
        }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let tx) = result {
                    await tx.finish()
                    await self?.refreshPurchasedState()
                }
                _ = self
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        do {
            let productIDs = tiers.map(\.id)
            let fetched = try await Product.products(for: productIDs)
            let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            for i in tiers.indices {
                if let product = byID[tiers[i].id] {
                    tiers[i] = TipTier(
                        id: tiers[i].id,
                        displayName: product.displayName,
                        fallbackPrice: tiers[i].fallbackPrice,
                        icon: tiers[i].icon,
                        product: product,
                        isPurchased: tiers[i].isPurchased
                    )
                }
            }
        } catch {}
        await refreshPurchasedState()
        isLoading = false
    }

    func purchase(_ tier: TipTier) async {
        guard let product = tier.product else {
            purchaseState = .failed("Tips are not available right now")
            return
        }
        purchaseState = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let tx) = verification {
                    await tx.finish()
                    await refreshPurchasedState()
                    purchaseState = .purchased
                } else {
                    purchaseState = .failed("Unable to verify purchase")
                }
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func restorePurchases() async {
        purchaseState = .purchasing
        do {
            try await StoreKit.AppStore.sync()
            await refreshPurchasedState()
            purchaseState = tiers.contains(where: \.isPurchased) ? .purchased : .idle
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func isHeaderKittySelected(_ tier: TipTier) -> Bool {
        guard tier.isPurchased else { return false }
        guard let selectedHeaderTierIDs else { return true }
        return selectedHeaderTierIDs.contains(tier.id)
    }

    func setHeaderKitty(_ tier: TipTier, selected: Bool) {
        guard tier.isPurchased else { return }
        var ids = selectedHeaderTierIDs ?? Set(purchasedTiers.map(\.id))
        if selected {
            ids.insert(tier.id)
        } else {
            ids.remove(tier.id)
        }
        selectedHeaderTierIDs = ids
        UserDefaults.standard.set(Array(ids).sorted(), forKey: Self.selectedHeaderTierIDsKey)
    }

    private func refreshPurchasedState() async {
        var purchasedIDs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result {
                purchasedIDs.insert(tx.productID)
            }
        }
        for i in tiers.indices {
            tiers[i] = TipTier(
                id: tiers[i].id,
                displayName: tiers[i].displayName,
                fallbackPrice: tiers[i].fallbackPrice,
                icon: tiers[i].icon,
                product: tiers[i].product,
                isPurchased: purchasedIDs.contains(tiers[i].id)
            )
        }
    }
}
