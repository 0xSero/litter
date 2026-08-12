package com.litter.android

import com.litter.android.ui.sessions.SessionsDerivation
import com.litter.android.ui.sessions.WorkspaceSortMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSubagentStatus
import uniffi.codex_mobile_client.ThreadKey

class SessionsDerivationTests {

    @Test
    fun `normalizedCwd trims trailing slash and lowercases`() {
        assertEquals("/home/user/projects", SessionsDerivation.normalizedCwd("/home/user/projects/"))
        assertEquals("/home/user/projects", SessionsDerivation.normalizedCwd("/home/user/Projects"))
    }

    @Test
    fun `normalizedCwd returns tilde for null or blank`() {
        assertEquals("~", SessionsDerivation.normalizedCwd(null))
        assertEquals("~", SessionsDerivation.normalizedCwd(""))
    }

    @Test
    fun `derive nests a local studio fork with its parent and preserves the workspace group`() {
        val parent = session(threadId = "desktop-thread", updatedAt = 100, cwd = "/Projects/Litter")
        val child = session(
            threadId = "phone-fork",
            updatedAt = 200,
            cwd = "/Projects/Litter",
            parentThreadId = parent.key.threadId,
            isFork = true,
        )

        val result = SessionsDerivation.derive(listOf(child, parent))

        assertEquals(2, result.totalCount)
        assertEquals(1, result.groups.size)
        assertEquals("studio|/projects/litter", result.workspaceGroupKeys.single())
        assertEquals("desktop-thread", result.groups.single().nodes.single().summary.key.threadId)
        assertEquals("phone-fork", result.groups.single().nodes.single().children.single().summary.key.threadId)
        assertEquals(parent.key, result.parentByKey.getValue(child.key).key)
        assertEquals("studio|/projects/litter", result.workspaceGroupKeyByThreadKey.getValue(child.key))
    }

    @Test
    fun `derive makes a filtered-out parent a root instead of hiding the child`() {
        val parent = session(threadId = "parent", updatedAt = 100, title = "Desktop work")
        val child = session(
            threadId = "child",
            updatedAt = 200,
            title = "Phone follow-up",
            parentThreadId = parent.key.threadId,
            isFork = true,
        )

        val result = SessionsDerivation.derive(
            summaries = listOf(parent, child),
            forkOnly = true,
        )

        assertEquals(listOf(child.key), result.filteredThreadKeys)
        assertEquals("child", result.groups.single().nodes.single().summary.key.threadId)
        assertTrue(result.groups.single().nodes.single().children.isEmpty())
        assertTrue(result.parentByKey.isEmpty())
    }

    @Test
    fun `derive search matches Local Studio metadata and sorts workspace names`() {
        val localStudio = session(
            threadId = "studio",
            updatedAt = 100,
            cwd = "/work/Zebra",
            agentDisplayLabel = "Local Studio",
        )
        val codex = session(
            serverId = "codex",
            threadId = "codex",
            updatedAt = 200,
            cwd = "/work/alpha",
            title = "Other work",
        )

        val searched = SessionsDerivation.derive(
            summaries = listOf(codex, localStudio),
            searchQuery = "studio",
        )
        assertEquals(listOf(localStudio.key), searched.filteredThreadKeys)

        val alphabetical = SessionsDerivation.derive(
            summaries = listOf(localStudio, codex),
            sortMode = WorkspaceSortMode.NAME,
        )
        assertEquals(listOf("alpha", "Zebra"), alphabetical.groups.map { it.workspaceLabel })
    }

    private fun session(
        serverId: String = "studio",
        threadId: String,
        updatedAt: Long,
        cwd: String = "/work/litter",
        title: String = threadId,
        parentThreadId: String? = null,
        isFork: Boolean = false,
        agentDisplayLabel: String? = null,
    ) = AppSessionSummary(
        key = ThreadKey(serverId = serverId, threadId = threadId),
        agentRuntimeKind = if (serverId == "studio") "local-studio" else "codex",
        serverDisplayName = if (serverId == "studio") "Local Studio" else "Codex",
        serverHost = "$serverId.local",
        title = title,
        preview = title,
        cwd = cwd,
        model = "",
        modelProvider = "",
        parentThreadId = parentThreadId,
        forkedFromId = parentThreadId,
        agentNickname = null,
        agentRole = null,
        agentDisplayLabel = agentDisplayLabel,
        agentStatus = AppSubagentStatus.UNKNOWN,
        updatedAt = updatedAt,
        hasActiveTurn = false,
        isResumed = false,
        isSubagent = false,
        isFork = isFork,
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
