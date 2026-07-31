package com.litter.android.state

import android.content.Context
import android.util.Log
import androidx.compose.runtime.mutableStateOf
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryPurchasesParams

/**
 * Shared, lightweight view of the user's tip-jar purchases so surfaces like
 * the home screen can show the purchased kitty without embedding BillingClient
 * plumbing themselves.
 *
 * The full purchase / list flow still lives in `TipJarScreen`.
 */
object TipJarSupporterState {
    private const val TAG = "TipJarSupporter"
    private const val PREFS_NAME = "tip_jar_supporter"
    private const val SELECTED_HEADER_KEYS = "selected_header_keys"

    /**
     * Ordered by tier (smallest → largest) so we pick the highest purchased.
     * The product id list stays in sync with `TipJarScreen.TIP_PRODUCTS`.
     */
    private val tiers: List<Tier> = listOf(
        Tier(
            key = "tip_10",
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_10,
            productIds = listOf("tip_10", "com.sigkitten.litter.tip.10", "com.sigkitten.litter.android.tip.10"),
        ),
        Tier(
            key = "tip_25",
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_25,
            productIds = listOf("tip_25", "com.sigkitten.litter.tip.25", "com.sigkitten.litter.android.tip.25"),
        ),
        Tier(
            key = "tip_50",
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_50,
            productIds = listOf("tip_50", "com.sigkitten.litter.tip.50", "com.sigkitten.litter.android.tip.50"),
        ),
        Tier(
            key = "tip_100",
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_100,
            productIds = listOf("tip_100", "com.sigkitten.litter.tip.100", "com.sigkitten.litter.android.tip.100"),
        ),
    )

    /** Highest purchased tier's icon drawable, or null if the user isn't a supporter yet. */
    val supporterIconRes = mutableStateOf<Int?>(null)

    /**
     * Positional tier-ordered list of 4 slots (smallest → largest). Each slot
     * is the icon drawable if purchased, or null otherwise. Hosts slice this
     * to show e.g. left (tiers 0..1) and right (tiers 2..3) of the logo.
     */
    val tierIcons = mutableStateOf<List<Int?>>(List(4) { null })
    val selectedHeaderKeys = mutableStateOf<Set<String>?>(null)

    private var ownedProductIds: Set<String> = emptySet()

    fun refresh(context: Context) {
        val app = context.applicationContext
        selectedHeaderKeys.value = loadSelectedHeaderKeys(app)
        val client = BillingClient.newBuilder(app)
            .setListener(PurchasesUpdatedListener { _, _ -> })
            .enableAutoServiceReconnection()
            .enablePendingPurchases(
                PendingPurchasesParams.newBuilder()
                    .enableOneTimeProducts()
                    .build(),
            )
            .build()
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    Log.w(TAG, "billing setup failed: ${result.debugMessage}")
                    client.endConnection()
                    return
                }
                client.queryPurchasesAsync(
                    QueryPurchasesParams.newBuilder()
                        .setProductType(BillingClient.ProductType.INAPP)
                        .build(),
                ) { _, purchases ->
                    val owned = purchases
                        .filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                        .flatMap { it.products }
                        .toSet()
                    updateOwnedProductIds(app, owned)
                    client.endConnection()
                }
            }

            override fun onBillingServiceDisconnected() {
                client.endConnection()
            }
        })
    }

    fun updateOwnedProductIds(context: Context, owned: Set<String>) {
        val app = context.applicationContext
        ownedProductIds = owned
        selectedHeaderKeys.value = loadSelectedHeaderKeys(app)
        publishState()
    }

    fun isHeaderKittySelected(productIds: List<String>): Boolean {
        val tier = tiers.firstOrNull { it.productIds == productIds } ?: return false
        if (!tier.productIds.any(ownedProductIds::contains)) return false
        val selected = selectedHeaderKeys.value ?: return true
        return tier.key in selected
    }

    fun setHeaderKittySelected(context: Context, productIds: List<String>, selected: Boolean) {
        val tier = tiers.firstOrNull { it.productIds == productIds } ?: return
        if (!tier.productIds.any(ownedProductIds::contains)) return
        val purchasedKeys = tiers
            .filter { it.productIds.any(ownedProductIds::contains) }
            .map { it.key }
            .toSet()
        val next = (selectedHeaderKeys.value ?: purchasedKeys).toMutableSet()
        if (selected) {
            next.add(tier.key)
        } else {
            next.remove(tier.key)
        }
        selectedHeaderKeys.value = next
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(SELECTED_HEADER_KEYS, next)
            .apply()
        publishState()
    }

    private fun publishState() {
        val selected = selectedHeaderKeys.value
        val highest = tiers.lastOrNull { tier ->
            tier.productIds.any(ownedProductIds::contains)
        }
        supporterIconRes.value = highest?.iconRes
        tierIcons.value = tiers.map { tier ->
            val purchased = tier.productIds.any(ownedProductIds::contains)
            val shown = selected?.contains(tier.key) ?: true
            if (purchased && shown) tier.iconRes else null
        }
    }

    private fun loadSelectedHeaderKeys(context: Context): Set<String>? {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return if (prefs.contains(SELECTED_HEADER_KEYS)) {
            prefs.getStringSet(SELECTED_HEADER_KEYS, emptySet())?.toSet() ?: emptySet()
        } else {
            null
        }
    }

    private data class Tier(val key: String, val iconRes: Int, val productIds: List<String>)
}
