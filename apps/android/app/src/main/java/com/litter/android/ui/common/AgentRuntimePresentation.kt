package com.litter.android.ui.common

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import com.litter.android.ui.LitterTheme
import uniffi.codex_mobile_client.AppAgentMetadata

/**
 * Bridge alias: Rust exposes agent identity as an opaque `String` (the
 * lowercase id alleycat advertises). The legacy `AgentRuntimeKind`
 * name is preserved as a type alias so call sites compile; ALL agent
 * metadata — label, icon, BETA badge, sort order, capability flags —
 * comes from `AgentMetadataStore` keyed by id. There is no hardcoded
 * catalog of agent names in litter, so adding a new agent only
 * requires an entry in the alleycat manifest.
 */
typealias AgentRuntimeKind = String

/**
 * Lookup hook into the Rust-owned `AgentMetadataStore`. Wired up at
 * app launch in `LitterApplication`. Returns `null` before the first
 * probe response has populated the cache.
 */
object AgentRuntimeMetadataProvider {
    var lookup: ((String) -> AppAgentMetadata?)? = null
    var all: (() -> List<AppAgentMetadata>)? = null
}

val AgentRuntimeKind.metadata: AppAgentMetadata?
    get() = AgentRuntimeMetadataProvider.lookup?.invoke(this)

/** Short label used in lists. Falls back to titlecased id on cold start. */
val AgentRuntimeKind.runtimeLabel: String
    get() = if (this == "local-studio") {
        "Local Studio"
    } else {
        metadata?.displayName?.takeIf { it.isNotEmpty() } ?: titlecased()
    }

/** Header / title rendering. Prefers metadata `presentation.title`. */
val AgentRuntimeKind.titleDisplayLabel: String
    get() = metadata?.presentation?.title?.takeIf { it.isNotEmpty() } ?: runtimeLabel

/**
 * Ascending sort key from `presentation.sort_order`; unknown agents
 * drop to the end.
 */
val AgentRuntimeKind.runtimeSortIndex: Int
    get() = metadata?.presentation?.sortOrder?.toInt() ?: Int.MAX_VALUE

/**
 * BETA badge driven by `presentation.is_beta`. Codex is always stable,
 * including cold-start SSH/alleycat paths before metadata is cached; other
 * unknown agents stay beta by default until metadata says otherwise.
 */
val AgentRuntimeKind.isBeta: Boolean
    get() = if (isStableAgentIdentity(this, "")) {
        false
    } else {
        metadata?.presentation?.isBeta ?: true
    }

/** Whether this runtime accepts client-side thread permission overrides. */
val AgentRuntimeKind.supportsThreadPermissionOverrides: Boolean
    get() = !hasFixedFullAccess && (metadata?.capabilities?.supportsThreadPermissionOverrides ?: true)

/** Whether this runtime reports effective permissions as authoritative state. */
val AgentRuntimeKind.reportsEffectiveThreadPermissions: Boolean
    get() = !hasFixedFullAccess && (metadata?.capabilities?.reportsEffectiveThreadPermissions ?: true)

val AgentRuntimeKind.hasFixedFullAccess: Boolean
    get() = this == "pi" || this == "local-studio"

/** Picker callers that only know `name` / `displayName` from a probe. */
fun isBetaAgentName(name: String, displayName: String): Boolean {
    val key = name.trim().lowercase()
    if (isStableAgentIdentity(key, displayName)) {
        return false
    }
    val cached = AgentRuntimeMetadataProvider.lookup?.invoke(key)
    return cached?.presentation?.isBeta ?: true
}

private fun isStableAgentIdentity(name: String, displayName: String): Boolean =
    name.trim().lowercase() in setOf("codex", "local-studio") ||
        displayName.trim().lowercase() in setOf("codex", "local studio")

private fun AgentRuntimeKind.titlecased(): String {
    if (isEmpty()) return "Agent"
    return substring(0, 1).uppercase() + substring(1)
}

/**
 * Renders an agent's icon from the local drawable catalog
 * (`R.drawable.agent_<id>`) when one is bundled, falling back to a
 * monogram letter chip. Use this everywhere — new alleycat-advertised
 * agents stay renderable without needing a litter release first.
 */
@Composable
fun AgentIconView(
    kind: AgentRuntimeKind,
    sizeDp: Int = 24,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val resName = "agent_${kind.lowercase().replace("-", "_")}"
    val resId = context.resources.getIdentifier(resName, "drawable", context.packageName)
    if (resId != 0) {
        Image(
            painter = painterResource(id = resId),
            contentDescription = kind.runtimeLabel,
            modifier = modifier.size(sizeDp.dp),
        )
    } else {
        AgentMonogram(kind = kind, sizeDp = sizeDp, modifier = modifier)
    }
}

@Composable
fun AgentMonogram(
    kind: AgentRuntimeKind,
    sizeDp: Int = 24,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .size(sizeDp.dp)
            .clip(RoundedCornerShape((sizeDp * 0.2).dp))
            .background(Color.Black.copy(alpha = 0.82f))
            .border(
                width = 0.5.dp,
                color = LitterTheme.textPrimary.copy(alpha = 0.25f),
                shape = RoundedCornerShape((sizeDp * 0.2).dp),
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = kind.firstOrNull()?.uppercaseChar()?.toString() ?: "?",
            color = LitterTheme.accent,
            fontSize = (sizeDp * 0.6).sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
fun BetaBadge(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .border(
                width = 0.5.dp,
                color = LitterTheme.accent.copy(alpha = 0.6f),
                shape = RoundedCornerShape(3.dp),
            )
            .padding(horizontal = 5.dp, vertical = 1.dp),
    ) {
        Text(
            text = "BETA",
            color = LitterTheme.accent,
            fontSize = 9.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
