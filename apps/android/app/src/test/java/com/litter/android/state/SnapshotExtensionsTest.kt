package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSubagentStatus
import uniffi.codex_mobile_client.ThreadKey

class SnapshotExtensionsTest {

    @Test
    fun `displayModelLabel uses concrete thread model first`() {
        assertEquals(
            "gpt-5.4",
            displayModelLabel(
                model = "gpt-5.4",
                infoModel = null,
                modelProvider = "anthropic",
                agentRuntimeKind = "claude",
            ),
        )
    }

    @Test
    fun `displayModelLabel falls back to provider and runtime labels`() {
        assertEquals(
            "Claude",
            displayModelLabel(
                model = null,
                infoModel = null,
                modelProvider = "anthropic",
                agentRuntimeKind = "claude",
            ),
        )
        assertEquals(
            "Opencode",
            displayModelLabel(
                model = null,
                infoModel = null,
                modelProvider = null,
                agentRuntimeKind = "opencode",
            ),
        )
    }

    @Test
    fun `session display title prefers explicit title over preview`() {
        val summary = AppSessionSummary(
            key = ThreadKey(serverId = "studio", threadId = "renamed"),
            agentRuntimeKind = "codex",
            serverDisplayName = "Studio",
            serverHost = "studio.local",
            title = "litter-deepseek",
            preview = "<command-message>review</command-message>",
            cwd = "/tmp",
            model = "",
            modelProvider = "",
            parentThreadId = null,
            forkedFromId = null,
            agentNickname = null,
            agentRole = null,
            agentDisplayLabel = null,
            agentStatus = AppSubagentStatus.UNKNOWN,
            updatedAt = null,
            hasActiveTurn = false,
            isResumed = false,
            isSubagent = false,
            isFork = false,
            lastResponsePreview = null,
            lastResponseTurnId = null,
            lastUserMessage = null,
            lastToolLabel = null,
            recentToolLog = emptyList(),
            lastTurnStartMs = null,
            lastTurnEndMs = null,
            stats = null,
            tokenUsage = null,
            goal = null,
        )

        assertEquals("litter-deepseek", summary.displayTitle)
    }
}
