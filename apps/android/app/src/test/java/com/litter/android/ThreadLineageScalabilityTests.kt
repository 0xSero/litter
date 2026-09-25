package com.litter.android

import com.litter.android.ui.home.HomeDashboardSupport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSubagentStatus
import uniffi.codex_mobile_client.ThreadKey

class ThreadLineageScalabilityTests {
    @Test
    fun ordinaryPathsPreserveEveryAncestorAndBranchOrdering() {
        val sessions = (0..<5).map { session("$it", parent = if (it == 0) null else "${it - 1}", updatedAt = it.toLong()) }
        val last = HomeDashboardSupport.computeLineageMap(sessions.reversed()).getValue(sessions[4].key)
        assertEquals(listOf("0", "1", "2", "3"), last.ancestors.map { it.key.threadId })
        assertEquals(0, last.omittedAncestorCount)
        assertEquals(sessions[3].key, last.parentKey)
        assertEquals(sessions[0].key, last.rootKey)
        assertEquals(listOf("4", "3", "2", "1", "0"), last.members.map { it.key.threadId })
        assertEquals(1, last.branchIndex)
    }

    @Test
    fun thousandDeepForksKeepBoundedBreadcrumbsAndCompleteSharedMembership() {
        val sessions = (0..<1_000).map { session("$it", parent = if (it == 0) null else "${it - 1}", updatedAt = it.toLong()) }
        val map = HomeDashboardSupport.computeLineageMap(sessions.reversed())
        val last = map.getValue(sessions[999].key)
        assertEquals(1_000, map.size)
        assertEquals(3_990, map.values.sumOf { it.ancestors.size })
        assertEquals(listOf("0", "996", "997", "998"), last.ancestors.map { it.key.threadId })
        assertEquals(995, last.omittedAncestorCount)
        assertEquals(1_000, last.branchTotal)
        assertEquals(1_000, last.members.map { it.key }.toSet().size)
        map.values.forEach { assertSame(last.members, it.members) }
    }

    @Test
    fun thousandWideForksKeepEveryBranch() {
        val sessions = listOf(session("root")) + (1..<1_000).map { session("$it", parent = "root") }
        val map = HomeDashboardSupport.computeLineageMap(sessions)
        assertEquals(999, map.values.sumOf { it.ancestors.size })
        assertTrue(map.values.all { it.branchTotal == 1_000 && it.omittedAncestorCount == 0 })
    }

    @Test
    fun missingParentsStayServerScopedAndSubagentsDoNotJoinForks() {
        val sessions = listOf(session("a", parent = "missing"), session("b", parent = " missing "),
            session("a", serverId = "other", parent = "missing"), session("agent", subagentParent = "a"))
        val map = HomeDashboardSupport.computeLineageMap(sessions)
        assertEquals(ThreadKey("server", "missing"), map.getValue(sessions[0].key).rootKey)
        assertEquals(2, map.getValue(sessions[0].key).branchTotal)
        assertEquals(1, map.getValue(sessions[2].key).branchTotal)
        assertTrue(map.getValue(sessions[0].key).ancestors.isEmpty())
        assertEquals(sessions[3].key, map.getValue(sessions[3].key).rootKey)
    }

    @Test
    fun malformedCyclesHaveDeterministicRootWithoutCyclicBreadcrumbs() {
        val sessions = listOf(session("b", parent = "a"), session("a", parent = "b"),
            session("child", parent = "b"), session("self", parent = "self"))
        val map = HomeDashboardSupport.computeLineageMap(sessions)
        val reversed = HomeDashboardSupport.computeLineageMap(sessions.reversed())
        sessions.take(3).forEach {
            assertEquals("a", map.getValue(it.key).rootKey.threadId)
            assertEquals(map.getValue(it.key).rootKey, reversed.getValue(it.key).rootKey)
            assertEquals(3, map.getValue(it.key).branchTotal)
        }
        assertTrue(map.getValue(sessions[0].key).ancestors.isEmpty())
        assertTrue(map.getValue(sessions[1].key).ancestors.isEmpty())
        assertEquals(listOf("b"), map.getValue(sessions[2].key).ancestors.map { it.key.threadId })
        assertTrue(map.getValue(sessions[3].key).ancestors.isEmpty())
    }

    private fun session(threadId: String, serverId: String = "server", parent: String? = null, subagentParent: String? = null, updatedAt: Long = 0) = AppSessionSummary(
        key = ThreadKey(serverId = serverId, threadId = threadId),
        agentRuntimeKind = "codex",
        serverDisplayName = serverId,
        serverHost = "$serverId.local",
        title = threadId,
        preview = threadId,
        cwd = "/tmp",
        model = "",
        modelProvider = "",
        parentThreadId = subagentParent,
        forkedFromId = parent,
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
