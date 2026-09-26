package com.litter.android.ui.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedAssistantMessageData
import uniffi.codex_mobile_client.HydratedCommandActionData
import uniffi.codex_mobile_client.HydratedCommandActionKind
import uniffi.codex_mobile_client.HydratedCommandExecutionData
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HydratedUserMessageData

class TurnGroupingTest {
    @Test
    fun followUpDoesNotCollapsePreviouslyVisibleHistory() {
        val state = TranscriptPresentationState()
        val first = listOf(user("u1", "t1"), assistant("a1", "t1"))
        val firstRows = rows(first, state)
        val followUpRows = rows(first + user("u2", "t2"), state, streaming = true)
        assertTrue(firstRows.any { it.key == "item-a1" })
        assertTrue(followUpRows.any { it.key == "item-a1" })
        assertFalse(followUpRows.any { it is TranscriptRow.Collapsed })
    }

    @Test
    fun initialHistoryCanCollapseAndExplicitExpansionIsPreserved() {
        val state = TranscriptPresentationState()
        val history = listOf(user("u1", "t1"), assistant("a1", "t1"), user("u2", "t2"))
        assertTrue(rows(history, state).first() is TranscriptRow.Collapsed)
        val expanded = rows(history + user("u3", "t3"), state, expanded = setOf("turn-u1"))
        assertTrue(expanded.any { it.key == "item-a1" })
        assertTrue(expanded.any { it.key == "item-u2" })
        assertTrue(rows(history, state).first() is TranscriptRow.Collapsed)
    }

    @Test
    fun paginationKeepsExistingRowsAndCollapsesOnlyNewOlderHistory() {
        val state = TranscriptPresentationState()
        val visible = listOf(user("u2", "t2"), assistant("a2", "t2"))
        val originalKeys = rows(visible, state).map { it.key }
        val paginated = rows(listOf(user("u1", "t1")) + visible, state)
        assertTrue(paginated.first() is TranscriptRow.Collapsed)
        assertEquals(originalKeys, paginated.drop(1).map { it.key })
    }

    @Test
    fun lateTurnProvenanceDoesNotReplaceRowOrTurnIdentity() {
        val optimistic = listOf(user("u1", null))
        val hydrated = listOf(user("u1", "server-turn"))
        assertEquals(turns(optimistic).single().id, turns(hydrated).single().id)
    }

    @Test
    fun acknowledgedUserIdKeepsExpansionWhenAnotherTurnHasStarted() {
        val state = TranscriptPresentationState()
        rows(listOf(user("optimistic", "t1")), state)
        val acknowledged = rows(listOf(user("server-user", "t1"), user("follow-up", "t2")), state)
        assertTrue(acknowledged.any { it.key == "item-server-user" })
        assertFalse(acknowledged.any { it is TranscriptRow.Collapsed })
    }

    @Test
    fun acknowledgedUserIdPreservesExplicitlyExpandedHistory() {
        val state = TranscriptPresentationState()
        rows(listOf(user("old-user", "t1"), user("follow-up", "t2")), state)
        val acknowledged = rows(
            listOf(user("new-user", "t1"), user("follow-up", "t2")), state, expanded = setOf("turn-old-user"),
        )
        assertTrue(acknowledged.any { it.key == "item-new-user" })
    }

    @Test
    fun repeatedSourceTurnDoesNotShareCollapseDefaultsAcrossUserBoundaries() {
        val state = TranscriptPresentationState()
        val result = rows(listOf(user("first", "shared"), user("second", "shared")), state)
        assertTrue(result.first() is TranscriptRow.Collapsed)
        assertTrue(result.any { it.key == "item-second" })
    }

    @Test
    fun ambiguousPreviousSourceDoesNotTransferExpansionToReplacement() {
        val state = TranscriptPresentationState()
        rows(listOf(user("first", "shared"), user("second", "shared")), state)
        val result = rows(listOf(user("replacement", "shared"), user("follow-up", "new")), state)
        assertTrue(result.first() is TranscriptRow.Collapsed)
    }

    @Test
    fun liveTailDoesNotMergeDifferentAuthoritativeTurns() {
        val items = listOf(user("u1", "t1"), assistant("a1", "t1"), assistant("a2", "t2"))
        val turns = turns(items, streaming = true)
        assertEquals(listOf("t1", "t2"), turns.map { it.turnId })
        assertFalse(turns.first().isActiveTurn)
        assertTrue(turns.last().isActiveTurn)
    }

    @Test
    fun explorationGroupsDoNotMergeAcrossAuthoritativeTurns() {
        val result = turns(listOf(exploration("c1", "t1"), exploration("c2", "t2")))
        assertEquals(listOf("t1", "t2"), result.map { it.turnId })
    }

    @Test
    fun missingProvenanceTailStaysWithLiveUserTurn() {
        val result = turns(listOf(user("u1", "t1"), assistant("a1", null)), streaming = true)
        assertEquals(1, result.size)
        assertEquals(listOf("u1", "a1"), result.single().items.map { it.id })
    }

    @Test
    fun longTurnUsesOneLazyRowPerMessageWithStableKeysDuringStreaming() {
        val items = listOf(user("u1", "t1")) + (1..500).map { assistant("a$it", "t1") }
        val state = TranscriptPresentationState()
        val before = rows(items, state, streaming = true)
        val after = rows(items.dropLast(1) + assistant("a500", "t1", "updated token"), state, streaming = true)
        assertEquals(501, before.count { it is TranscriptRow.Entry })
        assertEquals(before.map { it.key }, after.map { it.key })
        assertEquals(before.size, before.map { it.key }.distinct().size)
    }

    @Test
    fun streamingReusesCompletedTurnRowsAndRebuildsOnlyChangedTurn() {
        val state = TranscriptPresentationState()
        val history = listOf(user("u1", "t1"), assistant("a1", "t1"), user("u2", "t2"), assistant("a2", "t2"))
        val before = rows(history, state, streaming = true, expanded = setOf("turn-u1"))
        val after = rows(history.dropLast(1) + assistant("a2", "t2", "next token"), state, streaming = true, expanded = setOf("turn-u1"))
        assertSame(before.first { it.key == "item-a1" }, after.first { it.key == "item-a1" })
        assertNotSame(before.first { it.key == "item-a2" }, after.first { it.key == "item-a2" })
    }

    @Test
    fun finishedTurnCollapsesWorkChainButKeepsAnswerVisible() {
        val items = listOf(
            user("u1", "t1"), exploration("c1", "t1"), exploration("c2", "t1"), command("c3", "t1"), assistant("a1", "t1"),
        )
        val state = TranscriptPresentationState()
        val collapsed = rows(items, state)
        val chain = collapsed.filterIsInstance<TranscriptRow.Chain>().single()
        assertFalse(chain.expanded)
        assertTrue(collapsed.any { it.key == "item-a1" })
        assertTrue(collapsed.any { it.key == "item-u1" })
        assertFalse(collapsed.any { it.key == "item-c3" || it.key == "exploration-c1" })
        assertEquals("ran 1 command · searched 2 times", chain.chain.summary)

        val expanded = buildTranscriptRows(turns(items), state, emptySet(), mapOf(chain.expansionId to true))
        assertTrue(expanded.any { it.key == "item-c3" })
        // Visible rows keep their keys across toggles.
        assertEquals(collapsed.map { it.key }.toSet(), expanded.map { it.key }.toSet() - setOf("item-c3", "exploration-c1"))
    }

    @Test
    fun activeTurnShowsWorkChainExpanded() {
        val items = listOf(user("u1", "t1"), command("c1", "t1"))
        val chain = rows(items, TranscriptPresentationState(), streaming = true).filterIsInstance<TranscriptRow.Chain>().single()
        assertTrue(chain.expanded)
    }

    private fun command(id: String, turn: String) = item(
        id, turn, HydratedConversationItemContent.CommandExecution(
            HydratedCommandExecutionData(
                "make", "/tmp", AppOperationStatus.COMPLETED, null, 0, 1L, null, emptyList(),
            ),
        ),
    )

    private fun rows(
        items: List<HydratedConversationItem>,
        state: TranscriptPresentationState,
        streaming: Boolean = false,
        expanded: Set<String> = emptySet(),
    ) = buildTranscriptRows(turns(items, streaming), state, expanded)

    private fun turns(items: List<HydratedConversationItem>, streaming: Boolean = false) =
        buildTranscriptTurns(items, streaming, expandedRecentTurnCount = 1)

    private fun user(id: String, turn: String?) = item(
        id, turn, HydratedConversationItemContent.User(HydratedUserMessageData(id, emptyList())), true,
    )

    private fun assistant(id: String, turn: String?, text: String = id) = item(
        id, turn, HydratedConversationItemContent.Assistant(HydratedAssistantMessageData(text, null, null, null)),
    )

    private fun exploration(id: String, turn: String) = item(
        id, turn, HydratedConversationItemContent.CommandExecution(
            HydratedCommandExecutionData(
                "ls", "/tmp", AppOperationStatus.COMPLETED, null, 0, 1L, null,
                listOf(HydratedCommandActionData(HydratedCommandActionKind.LIST_FILES, "ls", null, "/tmp", null)),
            ),
        ),
    )

    private fun item(
        id: String,
        turn: String?,
        content: HydratedConversationItemContent,
        boundary: Boolean = false,
    ) = HydratedConversationItem(id, content, turn, null, null, boundary)
}
