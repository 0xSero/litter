package com.litter.android.ui.home

import com.litter.android.state.SavedServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSubagentStatus
import uniffi.codex_mobile_client.PinnedThreadKey
import uniffi.codex_mobile_client.ThreadKey

class HomeListVirtualizationTest {
    @Test
    fun hydrationWindowCoversViewportPlusPrefetch() {
        assertEquals(0..17, HomeListVirtualization.hydrationWindow(0, 7, 1000))
        assertEquals(40..59, HomeListVirtualization.hydrationWindow(40, 55, 60))
        assertTrue(HomeListVirtualization.hydrationWindow(0, 0, 0).isEmpty())
    }

    @Test
    fun pagingGrowsByOnePageNearTheEnd() {
        assertEquals(50, HomeListVirtualization.renderedCount(50, 10, 1200))
        assertEquals(100, HomeListVirtualization.renderedCount(50, 40, 1200))
        assertEquals(1200, HomeListVirtualization.renderedCount(1200, 1195, 1200))
        assertEquals(30, HomeListVirtualization.renderedCount(50, 29, 30))
    }

    @Test
    fun sectionsFollowRecency() {
        val now = 1_750_000_000_000L
        val nowS = now / 1000
        assertEquals(SessionSection.NOW, sessionSection(nowS - 60, now))
        assertEquals(SessionSection.YESTERDAY, sessionSection(nowS - secondsIntoDay(now) - 3_700L, now))
        assertEquals(SessionSection.OLDER, sessionSection(nowS - 30 * 86_400L, now))
        assertEquals(SessionSection.OLDER, sessionSection(null, now))
    }

    @Test
    fun pinnedIsItsOwnSectionFirst() {
        val now = System.currentTimeMillis()
        val nowS = now / 1000
        val a = session("a", nowS - 10)
        val b = session("b", nowS - 40 * 86_400L)
        val entries = sessionListEntries(
            listOf(a, b),
            setOf(PinnedThreadKey(serverId = "s", threadId = "b")),
            now,
        )
        assertEquals(
            listOf("section:PINNED", "s/b", "section:NOW", "s/a"),
            entries.map { it.key },
        )
    }

    @Test
    fun rememberedServerShowsConnectingBeforeTheStoreReportsIt() {
        val saved = SavedServer(
            id = "alleycat:local-studio:node",
            name = "Local Studio",
            hostname = "node",
            port = 0,
            rememberedByUser = true,
        )
        val open = homeServerEntries(emptyList(), emptyList(), listOf(saved), launchWindowOpen = true)
        assertEquals(ServerLinkLabel.CONNECTING, open.single().label)
        assertEquals("connecting…", open.single().label?.text)
        val closed = homeServerEntries(emptyList(), emptyList(), listOf(saved), launchWindowOpen = false)
        assertEquals(ServerLinkLabel.OFFLINE, closed.single().label)
    }

    private fun secondsIntoDay(nowMillis: Long): Long {
        val cal = java.util.Calendar.getInstance().apply { timeInMillis = nowMillis }
        return cal.get(java.util.Calendar.HOUR_OF_DAY) * 3600L +
            cal.get(java.util.Calendar.MINUTE) * 60L + cal.get(java.util.Calendar.SECOND)
    }

    private fun session(threadId: String, updatedAt: Long) = AppSessionSummary(
        key = ThreadKey(serverId = "s", threadId = threadId),
        agentRuntimeKind = "codex",
        serverDisplayName = "s",
        serverHost = "s.local",
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
        updatedAt = updatedAt,
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
