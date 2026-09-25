package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import uniffi.codex_mobile_client.HydratedAssistantMessageData
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.ThreadStreamingDeltaChunk
import uniffi.codex_mobile_client.ThreadStreamingDeltaKind

class StreamingItemRevisionTest {
    @Test
    fun snapshotCanCoverOnlyPrefixOfCoalescedBatch() {
        val captured = assistant("A🐈", 20u)
        val result = applyStreamingItemChunks(captured, ThreadStreamingDeltaKind.ASSISTANT_TEXT, listOf(
            ThreadStreamingDeltaChunk(20u, "🐈"),
            ThreadStreamingDeltaChunk(21u, "🐈"),
        ))!!
        assertEquals("A🐈🐈", text(result))
        assertEquals(21uL, result.capturedItemsRevision)
    }

    @Test
    fun fullyCoveredBatchDoesNotRepublishOrDuplicateText() {
        val captured = assistant("AB", 20u)
        val result = applyStreamingItemChunks(captured, ThreadStreamingDeltaKind.ASSISTANT_TEXT,
            listOf(ThreadStreamingDeltaChunk(20u, "B")))
        assertSame(captured, result)
    }

    @Test
    fun repeatedTextAtNewRevisionsIsNotContentDeduplicated() {
        val result = applyStreamingItemChunks(assistant("ha", 10u), ThreadStreamingDeltaKind.ASSISTANT_TEXT,
            listOf(ThreadStreamingDeltaChunk(11u, "ha"), ThreadStreamingDeltaChunk(12u, "ha")))!!
        assertEquals("hahaha", text(result))
    }

    @Test
    fun oneItemsRevisionDoesNotSuppressAnotherItemsDelta() {
        val newer = assistant("One", 30u)
        val older = assistant("Two", 10u).copy(id = "other")
        assertSame(newer, applyStreamingItemChunks(newer, ThreadStreamingDeltaKind.ASSISTANT_TEXT,
            listOf(ThreadStreamingDeltaChunk(20u, "old"))))
        val updated = applyStreamingItemChunks(older, ThreadStreamingDeltaKind.ASSISTANT_TEXT,
            listOf(ThreadStreamingDeltaChunk(20u, "+")))!!
        assertEquals("Two+", text(updated))
    }

    @Test
    fun newerThreadProjectionCanCorrectStreamingTextToShorterContent() {
        val old = assistant("AB", 20u)
        val correction = assistant("A", 30u)
        val projected = mergeCapturedThreadItems(listOf(correction), 30u, listOf(old), 20u).single()
        val result = preserveStreamingItem(old, projected)
        assertEquals("A", text(result))
        assertEquals(30uL, result.capturedItemsRevision)
    }

    @Test
    fun olderThreadProjectionCannotResurrectRemovedItem() {
        val current = assistant("A", 20u)
        val removed = assistant("Removed", 10u).copy(id = "removed")
        val result = mergeCapturedThreadItems(listOf(assistant("Old A", 10u), removed), 10u,
            listOf(current), 20u)
        assertEquals(listOf(current), result)
    }

    @Test
    fun authoritativeEmptyCaptureFencesOldReplayButAcceptsNewContent() {
        val old = assistant("A", 10u)
        val cleared = mergeCapturedThreadItems(emptyList(), 20u, listOf(old), 10u)
        assertEquals(emptyList<HydratedConversationItem>(), cleared)
        assertEquals(emptyList<HydratedConversationItem>(),
            mergeCapturedThreadItems(listOf(old), 10u, cleared, 20u))
        val newer = assistant("New", 30u)
        assertEquals(listOf(newer), mergeCapturedThreadItems(listOf(newer), 30u, cleared, 20u))
        // Legacy unversioned empty projections still preserve hydrated history.
        assertEquals(listOf(old), mergeCapturedThreadItems(emptyList(), 0u, listOf(old), 10u))
    }

    @Test
    fun delayedSnapshotPreservesPositionOfNewerMiddleItem() {
        val first = assistant("A", 20u)
        val middle = assistant("B", 30u).copy(id = "middle")
        val last = assistant("C", 20u).copy(id = "last")
        val result = mergeCapturedThreadItems(
            listOf(first, last), 25u,
            listOf(first, middle, last), 20u)
        assertEquals(listOf(first, middle, last), result)
    }

    @Test
    fun olderWholeSnapshotCannotReorderCapturedItems() {
        val first = assistant("A", 20u)
        val last = assistant("C", 20u).copy(id = "last")
        assertEquals(listOf(last, first),
            mergeCapturedThreadItems(listOf(first, last), 10u, listOf(last, first), 20u))
    }

    private fun assistant(text: String, revision: ULong) = HydratedConversationItem(
        id = "assistant",
        content = HydratedConversationItemContent.Assistant(HydratedAssistantMessageData(text, null, null, null)),
        sourceTurnId = null, sourceTurnIndex = null, timestamp = null,
        isFromUserTurnBoundary = false, capturedItemsRevision = revision,
    )

    private fun text(item: HydratedConversationItem) =
        (item.content as HydratedConversationItemContent.Assistant).v1.text
}
