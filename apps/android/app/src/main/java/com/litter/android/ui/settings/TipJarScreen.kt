package com.litter.android.ui.settings

import android.app.Activity
import android.util.Log
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.litter.android.state.TipJarSupporterState
import com.litter.android.ui.LitterTheme

private data class TipProduct(
    val productIds: List<String>,
    val iconRes: Int,
    val displayName: String,
    val fallbackPrice: String,
    val details: ProductDetails? = null,
    val isPurchased: Boolean = false,
)

private const val TIP_JAR_TAG = "TipJar"

private val TIP_PRODUCTS = listOf(
    TipProduct(
        productIds = listOf("tip_10", "com.sigkitten.litter.tip.10", "com.sigkitten.litter.android.tip.10"),
        iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_10,
        displayName = "$9.99 Tip",
        fallbackPrice = "$9.99",
    ),
    TipProduct(
        productIds = listOf("tip_25", "com.sigkitten.litter.tip.25", "com.sigkitten.litter.android.tip.25"),
        iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_25,
        displayName = "$24.99 Tip",
        fallbackPrice = "$24.99",
    ),
    TipProduct(
        productIds = listOf("tip_50", "com.sigkitten.litter.tip.50", "com.sigkitten.litter.android.tip.50"),
        iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_50,
        displayName = "$49.99 Tip",
        fallbackPrice = "$49.99",
    ),
    TipProduct(
        productIds = listOf("tip_100", "com.sigkitten.litter.tip.100", "com.sigkitten.litter.android.tip.100"),
        iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_100,
        displayName = "$99.99 Tip",
        fallbackPrice = "$99.99",
    ),
)

private sealed class TipJarState {
    data object Loading : TipJarState()
    data class Ready(
        val products: List<TipProduct>,
        val justPurchased: Boolean = false,
        val message: String? = null,
    ) : TipJarState()
    data object Purchasing : TipJarState()
    data class Error(val message: String) : TipJarState()
}

private val TIP_TITLE_SUFFIX_REGEX = Regex("\\s*\\(.*\\)$")

@Composable
fun TipJarScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    var state by remember { mutableStateOf<TipJarState>(TipJarState.Loading) }
    // Cache products so we can restore ready state after cancel
    var cachedProducts by remember { mutableStateOf<List<TipProduct>>(emptyList()) }
    val selectedHeaderKeys by TipJarSupporterState.selectedHeaderKeys

    val purchasesUpdatedListener = remember {
        PurchasesUpdatedListener { billingResult, _ ->
            when (billingResult.responseCode) {
                BillingClient.BillingResponseCode.OK -> {
                    // Will refresh owned purchases below via LaunchedEffect
                    state = TipJarState.Loading
                }
                BillingClient.BillingResponseCode.USER_CANCELED -> {
                    state = TipJarState.Ready(cachedProducts)
                }
                else -> {
                    state = TipJarState.Error(billingResult.debugMessage ?: "Purchase failed")
                }
            }
        }
    }

    val billingClient = remember {
        BillingClient.newBuilder(context)
            .setListener(purchasesUpdatedListener)
            .enableAutoServiceReconnection()
            .enablePendingPurchases(
                PendingPurchasesParams.newBuilder()
                    .enableOneTimeProducts()
                    .build(),
            )
            .build()
    }

    DisposableEffect(Unit) {
        onDispose { billingClient.endConnection() }
    }

    fun loadProductsAndPurchases() {
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(billingResult: BillingResult) {
                if (billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
                    Log.w(
                        TIP_JAR_TAG,
                        "Billing setup failed code=${billingResult.responseCode} message=${billingResult.debugMessage}",
                    )
                    state = TipJarState.Ready(
                        products = TIP_PRODUCTS,
                        message = "Google Play Billing is unavailable for this install.",
                    )
                    return
                }

                // Query product details
                val requestedProductIds = TIP_PRODUCTS
                    .flatMap { it.productIds }
                    .distinct()
                val productList = requestedProductIds
                    .map { productId ->
                        QueryProductDetailsParams.Product.newBuilder()
                            .setProductId(productId)
                            .setProductType(BillingClient.ProductType.INAPP)
                            .build()
                    }
                val params = QueryProductDetailsParams.newBuilder()
                    .setProductList(productList)
                    .build()

                billingClient.queryProductDetailsAsync(params) { result, queryResult ->
                    val detailsList = queryResult.productDetailsList
                    if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                        Log.w(
                            TIP_JAR_TAG,
                            "Product detail query failed code=${result.responseCode} message=${result.debugMessage}",
                        )
                        state = TipJarState.Ready(
                            products = TIP_PRODUCTS,
                            message = "Google Play did not return tip products for this install.",
                        )
                        return@queryProductDetailsAsync
                    }

                    val detailsMap = detailsList.associateBy { it.productId }
                    Log.i(
                        TIP_JAR_TAG,
                        "Resolved tip products=${detailsMap.keys.sorted()} requested=$requestedProductIds",
                    )

                    // Query owned purchases (non-consumables persist here)
                    billingClient.queryPurchasesAsync(
                        QueryPurchasesParams.newBuilder()
                            .setProductType(BillingClient.ProductType.INAPP)
                            .build()
                    ) { _, purchases ->
                        val ownedProductIds = purchases
                            .filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                            .flatMap { purchase ->
                                // Acknowledge if needed
                                if (!purchase.isAcknowledged) {
                                    val ackParams = AcknowledgePurchaseParams.newBuilder()
                                        .setPurchaseToken(purchase.purchaseToken)
                                        .build()
                                    billingClient.acknowledgePurchase(ackParams) { _ -> }
                                }
                                purchase.products
                            }
                            .toSet()

                        val products = TIP_PRODUCTS.map { tip ->
                            val matchedId = tip.productIds.firstOrNull(detailsMap::containsKey)
                            tip.copy(
                                details = matchedId?.let(detailsMap::get),
                                isPurchased = tip.productIds.any(ownedProductIds::contains),
                            )
                        }
                        val hadPurchases = cachedProducts.any { it.isPurchased }
                        val hasPurchasesNow = products.any { it.isPurchased }
                        val message = if (products.none { it.details != null }) {
                            "Tips are unavailable in this build. Google Play did not match any configured tip products."
                        } else {
                            null
                        }
                        TipJarSupporterState.updateOwnedProductIds(context, ownedProductIds)
                        cachedProducts = products
                        state = TipJarState.Ready(
                            products,
                            justPurchased = !hadPurchases && hasPurchasesNow,
                            message = message,
                        )
                    }
                }
            }

            override fun onBillingServiceDisconnected() {
                Log.w(TIP_JAR_TAG, "Billing service disconnected")
            }
        })
    }

    LaunchedEffect(Unit) {
        loadProductsAndPurchases()
    }

    // Refresh after a purchase completes
    LaunchedEffect(state) {
        if (state is TipJarState.Loading && cachedProducts.isNotEmpty()) {
            loadProductsAndPurchases()
        }
    }

    val supporterTier = cachedProducts.lastOrNull { it.isPurchased }

    Column(
        Modifier
            .fillMaxSize()
            .imePadding()
            .padding(16.dp),
    ) {
        // Nav bar
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = LitterTheme.accent)
            }
            Spacer(Modifier.weight(1f))
            Text(
                "Tip the Kitty",
                color = LitterTheme.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }

        Spacer(Modifier.height(16.dp))

        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // Header
            item {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                        .padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (supporterTier != null) {
                        Image(
                            painter = painterResource(supporterTier.iconRes),
                            contentDescription = "Supporter",
                            modifier = Modifier.size(80.dp),
                            contentScale = ContentScale.Fit,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "You're a supporter! Thank you.",
                            color = LitterTheme.accent,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(4.dp))
                    } else {
                        Text("\u2764\uFE0F", fontSize = 28.sp)
                        Spacer(Modifier.height(8.dp))
                    }
                    Text(
                        "If you enjoy Litter, consider leaving a tip. Tips help support ongoing development and are entirely optional.",
                        color = LitterTheme.textSecondary,
                        fontSize = 13.sp,
                        textAlign = TextAlign.Center,
                    )
                }
            }

            item { Spacer(Modifier.height(8.dp)) }

            when (val currentState = state) {
                is TipJarState.Loading -> {
                    item {
                        Box(
                            Modifier.fillMaxWidth().padding(32.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                strokeWidth = 2.dp,
                                color = LitterTheme.accent,
                            )
                        }
                    }
                }

                is TipJarState.Ready -> {
                    if (currentState.message != null) {
                        item {
                            Text(
                                currentState.message,
                                color = LitterTheme.danger,
                                fontSize = 13.sp,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                            )
                        }
                    }
                    items(currentState.products) { tip ->
                        if (tip.isPurchased) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                                    .padding(12.dp),
                            ) {
                                Image(
                                    painter = painterResource(tip.iconRes),
                                    contentDescription = tip.displayName,
                                    modifier = Modifier.size(40.dp),
                                    contentScale = ContentScale.Fit,
                                )
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    tip.displayName,
                                    color = LitterTheme.textPrimary,
                                    fontSize = 14.sp,
                                    modifier = Modifier.weight(1f),
                                )
                                Icon(
                                    Icons.Default.CheckCircle,
                                    contentDescription = "Purchased",
                                    tint = LitterTheme.accent,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        } else {
                            val price = tip.details?.oneTimePurchaseOfferDetails?.formattedPrice ?: tip.fallbackPrice
                            val interactionSource = remember { MutableInteractionSource() }
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                                    .clickable(
                                        enabled = tip.details != null,
                                        interactionSource = interactionSource,
                                        indication = null,
                                    ) {
                                        val details = tip.details ?: return@clickable
                                        val activity = context as? Activity ?: return@clickable
                                        state = TipJarState.Purchasing
                                        val flowParams = BillingFlowParams.newBuilder()
                                            .setProductDetailsParamsList(
                                                listOf(
                                                    BillingFlowParams.ProductDetailsParams.newBuilder()
                                                        .setProductDetails(details)
                                                        .build()
                                                )
                                            )
                                            .build()
                                        billingClient.launchBillingFlow(activity, flowParams)
                                    }
                                    .padding(12.dp),
                            ) {
                                Image(
                                    painter = painterResource(tip.iconRes),
                                    contentDescription = tip.displayName,
                                    modifier = Modifier.size(40.dp),
                                    contentScale = ContentScale.Fit,
                                )
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    tip.details?.title?.replace(TIP_TITLE_SUFFIX_REGEX, "") ?: tip.displayName,
                                    color = LitterTheme.textPrimary,
                                    fontSize = 14.sp,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    price,
                                    color = if (tip.details != null) LitterTheme.accent else LitterTheme.textSecondary,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                        }
                    }
                    val purchasedTips = currentState.products.filter { it.isPurchased }
                    if (purchasedTips.isNotEmpty()) {
                        item {
                            Text(
                                "Home Header",
                                color = LitterTheme.textSecondary,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                            )
                        }
                        items(purchasedTips, key = { "header-${it.productIds.first()}" }) { tip ->
                            val isSelected = selectedHeaderKeys?.contains(tip.productIds.first()) ?: true
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                                    .clickable {
                                        TipJarSupporterState.setHeaderKittySelected(
                                            context = context,
                                            productIds = tip.productIds,
                                            selected = !isSelected,
                                        )
                                    }
                                    .padding(12.dp),
                            ) {
                                Image(
                                    painter = painterResource(tip.iconRes),
                                    contentDescription = tip.displayName,
                                    modifier = Modifier.size(40.dp),
                                    contentScale = ContentScale.Fit,
                                )
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        tip.displayName,
                                        color = LitterTheme.textPrimary,
                                        fontSize = 14.sp,
                                    )
                                    Text(
                                        if (isSelected) "Shown on home" else "Hidden from home",
                                        color = LitterTheme.textSecondary,
                                        fontSize = 12.sp,
                                    )
                                }
                                Icon(
                                    Icons.Default.CheckCircle,
                                    contentDescription = if (isSelected) "Shown on home" else "Hidden from home",
                                    tint = if (isSelected) LitterTheme.accent else LitterTheme.textMuted,
                                    modifier = Modifier
                                        .size(20.dp)
                                        .alpha(if (isSelected) 1f else 0.35f),
                                )
                            }
                        }
                        item {
                            Text(
                                "Pick which purchased kitties appear around the home logo.",
                                color = LitterTheme.textMuted,
                                fontSize = 12.sp,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                            )
                        }
                    }

                    // Restore purchases
                    item {
                        Spacer(Modifier.height(4.dp))
                        TextButton(
                            onClick = { state = TipJarState.Loading },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Restore Purchases", color = LitterTheme.accent, fontSize = 14.sp)
                        }
                    }

                    // Thank you after purchase
                    if (currentState.justPurchased) {
                        item {
                            AnimatedVisibility(visible = true, enter = fadeIn()) {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                                        .padding(16.dp),
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                ) {
                                    Text(
                                        "Thank you!",
                                        color = LitterTheme.accent,
                                        fontSize = 16.sp,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        "Your support means a lot.",
                                        color = LitterTheme.textSecondary,
                                        fontSize = 13.sp,
                                    )
                                }
                            }
                        }
                    }
                }

                is TipJarState.Purchasing -> {
                    item {
                        Box(
                            Modifier.fillMaxWidth().padding(32.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                strokeWidth = 2.dp,
                                color = LitterTheme.accent,
                            )
                        }
                    }
                }

                is TipJarState.Error -> {
                    item {
                        Text(
                            currentState.message,
                            color = LitterTheme.danger,
                            fontSize = 13.sp,
                            modifier = Modifier.padding(12.dp),
                        )
                    }
                }
            }
        }
    }
}
