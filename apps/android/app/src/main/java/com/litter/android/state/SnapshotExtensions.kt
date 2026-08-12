package com.litter.android.state

import androidx.compose.ui.graphics.Color
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppServerTransportState
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.AppConnectionStepKind
import uniffi.codex_mobile_client.AppConnectionStepSnapshot
import uniffi.codex_mobile_client.AppConnectionStepState
import com.litter.android.ui.common.AgentRuntimeKind
import com.litter.android.ui.common.runtimeLabel
import uniffi.codex_mobile_client.ThreadSummaryStatus

/** Accent green matching iOS theme. */
private val AccentGreen = Color(0xFF00FF9C)
private val WarningOrange = Color(0xFFFF9500)
private val SecondaryGray = Color(0xFF8E8E93)

// --- AppServerHealth extensions ----------------------------------------------

val AppServerHealth.displayLabel: String
    get() = when (this) {
        AppServerHealth.CONNECTED -> "Connected"
        AppServerHealth.CONNECTING -> "Connecting\u2026"
        AppServerHealth.UNRESPONSIVE -> "Unresponsive"
        AppServerHealth.DISCONNECTED -> "Disconnected"
        AppServerHealth.UNKNOWN -> "Unknown"
    }

val AppServerHealth.accentColor: Color
    get() = when (this) {
        AppServerHealth.CONNECTED -> AccentGreen
        AppServerHealth.CONNECTING, AppServerHealth.UNRESPONSIVE -> WarningOrange
        AppServerHealth.DISCONNECTED, AppServerHealth.UNKNOWN -> SecondaryGray
    }

val AppServerTransportState.displayLabel: String
    get() = when (this) {
        AppServerTransportState.CONNECTED -> "Connected"
        AppServerTransportState.CONNECTING -> "Connecting\u2026"
        AppServerTransportState.UNRESPONSIVE -> "Unresponsive"
        AppServerTransportState.DISCONNECTED -> "Disconnected"
        AppServerTransportState.UNKNOWN -> "Unknown"
    }

val AppServerTransportState.accentColor: Color
    get() = when (this) {
        AppServerTransportState.CONNECTED -> AccentGreen
        AppServerTransportState.CONNECTING, AppServerTransportState.UNRESPONSIVE -> WarningOrange
        AppServerTransportState.DISCONNECTED, AppServerTransportState.UNKNOWN -> SecondaryGray
    }

// --- AppServerSnapshot extensions --------------------------------------------

val AppServerSnapshot.isConnected: Boolean
    get() = transportState == AppServerTransportState.CONNECTED

val AppServerSnapshot.canUseTransportActions: Boolean
    get() = capabilities.canUseTransportActions

val AppServerSnapshot.canBrowseDirectories: Boolean
    get() = capabilities.canBrowseDirectories

val AppServerSnapshot.connectionModeLabel: String
    get() = when {
        isLocal -> "local"
        else -> "remote"
    }

val AppServerSnapshot.currentConnectionStep: AppConnectionStepSnapshot?
    get() = connectionProgress?.steps?.firstOrNull {
        it.state == AppConnectionStepState.AWAITING_USER_INPUT ||
            it.state == AppConnectionStepState.IN_PROGRESS
    } ?: connectionProgress?.steps?.lastOrNull {
        it.state == AppConnectionStepState.FAILED ||
            it.state == AppConnectionStepState.COMPLETED
    }

val AppServerSnapshot.connectionProgressLabel: String?
    get() = when (currentConnectionStep?.kind) {
        AppConnectionStepKind.CONNECTING_TO_SSH -> "connecting"
        AppConnectionStepKind.FINDING_CODEX -> "finding codex"
        AppConnectionStepKind.INSTALLING_CODEX -> "installing"
        AppConnectionStepKind.STARTING_APP_SERVER -> "starting"
        AppConnectionStepKind.OPENING_TUNNEL -> "tunneling"
        AppConnectionStepKind.CONNECTED -> "connected"
        null -> null
    }

val AppServerSnapshot.statusLabel: String
    get() = when {
        connectionProgressLabel != null -> connectionProgressLabel!!
        transportState == AppServerTransportState.CONNECTED && requiresOpenaiAuth && account == null ->
            "Sign in required"
        else -> transportState.displayLabel
    }

val AppServerSnapshot.statusColor: Color
    get() = when {
        currentConnectionStep?.state == AppConnectionStepState.FAILED -> Color(0xFFFF6B6B)
        currentConnectionStep?.state == AppConnectionStepState.AWAITING_USER_INPUT -> WarningOrange
        connectionProgressLabel != null -> AccentGreen
        transportState == AppServerTransportState.CONNECTED && requiresOpenaiAuth && account == null ->
            WarningOrange
        else -> transportState.accentColor
    }

/**
 * Stable mapping to the shared `StatusDotState` palette (green/orange/red) so
 * the server dot renders the same colors as the task indicator across themes.
 */
val AppServerSnapshot.statusDotState: com.litter.android.ui.common.StatusDotState
    get() = when {
        currentConnectionStep?.state == AppConnectionStepState.FAILED ->
            com.litter.android.ui.common.StatusDotState.ERROR
        currentConnectionStep?.state == AppConnectionStepState.AWAITING_USER_INPUT ->
            com.litter.android.ui.common.StatusDotState.PENDING
        connectionProgressLabel != null ->
            com.litter.android.ui.common.StatusDotState.PENDING
        transportState == AppServerTransportState.CONNECTED && requiresOpenaiAuth && account == null ->
            com.litter.android.ui.common.StatusDotState.PENDING
        transportState == AppServerTransportState.CONNECTED ->
            com.litter.android.ui.common.StatusDotState.OK
        transportState == AppServerTransportState.CONNECTING ->
            com.litter.android.ui.common.StatusDotState.PENDING
        transportState == AppServerTransportState.UNRESPONSIVE ->
            com.litter.android.ui.common.StatusDotState.PENDING
        else -> com.litter.android.ui.common.StatusDotState.IDLE
    }

// --- AppThreadSnapshot extensions --------------------------------------------

val ThreadSummaryStatus.isActiveStatus: Boolean
    get() = this == ThreadSummaryStatus.ACTIVE

val AppThreadSnapshot.hasActiveTurn: Boolean
    get() = activeTurnId?.trim()?.isNotEmpty() == true || info.status.isActiveStatus

val AppThreadSnapshot.ampReasoningEffortLocked: Boolean
    get() = agentRuntimeKind == "amp" &&
        (hydratedConversationItems.isNotEmpty() || activeTurnId?.trim()?.isNotEmpty() == true)

val AppThreadSnapshot.resolvedModel: String
    get() = model?.trim()?.takeIf { it.isNotEmpty() }
        ?: info.model?.trim()?.takeIf { it.isNotEmpty() }
        ?: ""

val AppThreadSnapshot.displayModelLabel: String
    get() = displayModelLabel(
        model = model,
        infoModel = info.model,
        modelProvider = info.modelProvider,
        agentRuntimeKind = agentRuntimeKind,
    )

fun displayModelLabel(
    model: String?,
    infoModel: String?,
    modelProvider: String?,
    agentRuntimeKind: AgentRuntimeKind,
): String {
    model?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    infoModel?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    modelProviderDisplayLabel(modelProvider)?.let { return it }
    return agentRuntimeDisplayLabel(agentRuntimeKind)
}

private fun modelProviderDisplayLabel(provider: String?): String? {
    val trimmed = provider?.trim().orEmpty()
    if (trimmed.isEmpty()) return null

    return when (val normalized = trimmed.lowercase()) {
        "anthropic", "claude", "claude-code", "claude_code" -> "Claude"
        "amp", "ampcode", "amp-code", "amp_code", "amp code" -> "Amp"
        "opencode", "open-code", "open_code" -> "opencode"
        "pi", "pi.dev", "pidev" -> "Pi"
        "openai", "codex" -> "Codex"
        else -> {
            if (normalized.startsWith("claude") || normalized.contains("anthropic")) {
                "Claude"
            } else if (
                normalized.startsWith("amp") ||
                normalized.contains("ampcode") ||
                normalized.contains("amp-code") ||
                normalized.contains("amp_code")
            ) {
                "Amp"
            } else {
                trimmed
            }
        }
    }
}

private fun agentRuntimeDisplayLabel(kind: AgentRuntimeKind): String = kind.runtimeLabel

val AppThreadSnapshot.displayTitle: String
    get() = info.preview?.takeIf { it.isNotBlank() }
        ?: info.title?.takeIf { it.isNotBlank() }
        ?: "Untitled session"

val AppThreadSnapshot.resolvedPreview: String
    get() = displayTitle

val AppSessionSummary.displayTitle: String
    get() = title?.takeIf { it.isNotBlank() }
        ?: preview?.takeIf { it.isNotBlank() }
        ?: "Untitled session"

val AppThreadSnapshot.contextPercent: Int
    get() {
        val window = modelContextWindow?.toLong() ?: return 0
        if (window <= 0L) return 0
        val used = contextTokensUsed?.toLong() ?: return 0
        return ((used * 100) / window).toInt().coerceIn(0, 100)
    }

val AppThreadSnapshot.latestAssistantSnippet: String?
    get() {
        val items = hydratedConversationItems
        for (i in items.indices.reversed()) {
            val content = items[i].content
            if (content is HydratedConversationItemContent.Assistant) {
                val text = content.v1.text
                if (text.isNotBlank()) {
                    return if (text.length > 120) text.takeLast(120) else text
                }
            } else if (content is HydratedConversationItemContent.CodeReview) {
                val title = content.v1.findings.firstOrNull()?.title
                if (!title.isNullOrBlank()) {
                    return if (title.length > 120) title.take(120) else title
                }
            }
        }
        return null
    }
