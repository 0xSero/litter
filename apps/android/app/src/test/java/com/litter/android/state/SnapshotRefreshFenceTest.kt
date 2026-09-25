package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SnapshotRefreshFenceTest {
    @Test
    fun overlappingRefreshCannotPublishAfterNewerRequest() {
        val fence = SnapshotRefreshFence()
        val older = fence.begin()!!
        val newer = fence.begin()!!
        assertEquals(SnapshotRefreshFence.Disposition.SUPERSEDED, fence.disposition(older))
        assertEquals(SnapshotRefreshFence.Disposition.APPLY, fence.disposition(newer))
    }

    @Test
    fun receivedEventInvalidatesCaptureBeforeProjectionPublication() {
        val fence = SnapshotRefreshFence()
        val capture = fence.begin()!!
        fence.invalidate()
        assertEquals(SnapshotRefreshFence.Disposition.RETRY, fence.disposition(capture))
        // A later local publication must reject the same capture as well.
        fence.invalidate()
        assertEquals(SnapshotRefreshFence.Disposition.RETRY, fence.disposition(capture))
    }

    @Test
    fun trailingCaptureAfterBurstCanPublish() {
        val fence = SnapshotRefreshFence()
        val stale = fence.begin()!!
        repeat(100) { fence.invalidate() }
        assertEquals(SnapshotRefreshFence.Disposition.RETRY, fence.disposition(stale))
        val trailing = fence.begin()!!
        assertEquals(SnapshotRefreshFence.Disposition.SUPERSEDED, fence.disposition(stale))
        assertEquals(SnapshotRefreshFence.Disposition.APPLY, fence.disposition(trailing))
    }

    @Test
    fun stopAndRestartNeverRevivesOldCaptureOrRetry() {
        val fence = SnapshotRefreshFence()
        val old = fence.begin()!!
        fence.stop()
        assertNull(fence.begin())
        assertEquals(SnapshotRefreshFence.Disposition.SUPERSEDED, fence.disposition(old))
        fence.start()
        assertEquals(SnapshotRefreshFence.Disposition.SUPERSEDED, fence.disposition(old))
        val current = fence.begin()!!
        assertEquals(SnapshotRefreshFence.Disposition.APPLY, fence.disposition(current))
    }
}
