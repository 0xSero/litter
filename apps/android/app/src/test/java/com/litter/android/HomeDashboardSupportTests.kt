package com.litter.android

import com.litter.android.ui.home.HomeDashboardSupport
import com.litter.android.ui.home.mergeHomeSessions
import com.litter.android.ui.home.usesServerConfiguredModelDefault
import com.litter.android.state.statusDotState
import com.litter.android.state.statusLabel
import com.litter.android.ui.common.StatusDotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AgentRuntimeInfo
import uniffi.codex_mobile_client.AppServerCapabilities
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppServerTransportState
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSubagentStatus
import uniffi.codex_mobile_client.PinnedThreadKey
import uniffi.codex_mobile_client.ThreadKey

class HomeDashboardSupportTests {

    @Test
    fun `Local Studio-only catalogs defer to the server configured default`() {
        assertTrue(usesServerConfiguredModelDefault(listOf("local-studio")))
        assertTrue(
            usesServerConfiguredModelDefault(
                listOf("local-studio", "local-studio"),
            ),
        )
        assertFalse(usesServerConfiguredModelDefault(emptyList()))
        assertFalse(
            usesServerConfiguredModelDefault(
                listOf("local-studio", "codex"),
            ),
        )
    }

    @Test
    fun `Local Studio pins retain recent sessions and use Local Studio placeholders`() {
        val server = server("studio", "local-studio")
        val stalePin = PinnedThreadKey(serverId = "studio", threadId = "stale")

        val result = mergeHomeSessions(
            pinned = listOf(stalePin),
            hidden = emptyList(),
            servers = listOf(server),
            allSessions = listOf(session("studio", "recent", "local-studio")),
        )

        assertEquals(listOf("stale", "recent"), result.map { it.key.threadId })
        assertEquals(listOf("local-studio", "local-studio"), result.map { it.agentRuntimeKind })
    }

    @Test
    fun `Codex pins keep the existing pins-only behavior`() {
        val server = server("codex", "codex")

        val result = mergeHomeSessions(
            pinned = listOf(PinnedThreadKey(serverId = "codex", threadId = "stale")),
            hidden = emptyList(),
            servers = listOf(server),
            allSessions = listOf(session("codex", "recent", "codex")),
        )

        assertEquals(listOf("stale"), result.map { it.key.threadId })
        assertEquals(listOf("codex"), result.map { it.agentRuntimeKind })
    }

    @Test
    fun `Local Studio does not show a false OpenAI sign-in warning`() {
        val studio = server("studio", "local-studio")
        val codex = server("codex", "codex", requiresOpenaiAuth = true)

        assertEquals("Connected", studio.statusLabel)
        assertEquals(StatusDotState.OK, studio.statusDotState)
        assertEquals("Sign in required", codex.statusLabel)
        assertEquals(StatusDotState.PENDING, codex.statusDotState)
    }

    @Test
    fun `workspaceLabel extracts last path component`() {
        assertEquals("projects", HomeDashboardSupport.workspaceLabel("/home/user/projects"))
        assertEquals("src", HomeDashboardSupport.workspaceLabel("/home/user/projects/src"))
    }

    @Test
    fun `workspaceLabel returns tilde for null or blank`() {
        assertEquals("~", HomeDashboardSupport.workspaceLabel(null))
        assertEquals("~", HomeDashboardSupport.workspaceLabel(""))
        assertEquals("~", HomeDashboardSupport.workspaceLabel("   "))
    }

    @Test
    fun `workspaceLabel handles root path`() {
        assertEquals("/", HomeDashboardSupport.workspaceLabel("/"))
    }

    @Test
    fun `workspaceLabel trims trailing slash`() {
        assertEquals("projects", HomeDashboardSupport.workspaceLabel("/home/user/projects/"))
    }

    @Test
    fun `relativeTime formats correctly`() {
        val now = System.currentTimeMillis() / 1000L

        assertEquals("just now", HomeDashboardSupport.relativeTime(now - 30))
        assertEquals("5m ago", HomeDashboardSupport.relativeTime(now - 300))
        assertEquals("2h ago", HomeDashboardSupport.relativeTime(now - 7200))
        assertEquals("3d ago", HomeDashboardSupport.relativeTime(now - 259200))
    }

    @Test
    fun `relativeTime returns empty for null or zero`() {
        assertEquals("", HomeDashboardSupport.relativeTime(null))
        assertEquals("", HomeDashboardSupport.relativeTime(0L))
    }

    private fun server(
        id: String,
        runtimeKind: String,
        requiresOpenaiAuth: Boolean = false,
    ) = AppServerSnapshot(
        serverId = id,
        displayName = id,
        host = "$id.local",
        port = 8390u,
        wakeMac = null,
        isLocal = false,
        health = AppServerHealth.CONNECTED,
        transportState = AppServerTransportState.CONNECTED,
        capabilities = AppServerCapabilities(
            canUseTransportActions = true,
            canBrowseDirectories = true,
            canStartThreads = true,
            canResumeThreads = true,
            supportsTurnPagination = true,
        ),
        account = null,
        requiresOpenaiAuth = requiresOpenaiAuth,
        rateLimits = null,
        rateLimitsByRuntime = emptyList(),
        availableModels = null,
        agentRuntimes = listOf(
            AgentRuntimeInfo(
                kind = runtimeKind,
                name = runtimeKind,
                displayName = runtimeKind,
                available = true,
            ),
        ),
        connectionProgress = null,
        usageStats = null,
        sessionListHasMore = false,
    )

    private fun session(serverId: String, threadId: String, runtimeKind: String) = AppSessionSummary(
        key = ThreadKey(serverId = serverId, threadId = threadId),
        agentRuntimeKind = runtimeKind,
        serverDisplayName = serverId,
        serverHost = "$serverId.local",
        title = threadId,
        preview = threadId,
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
}
