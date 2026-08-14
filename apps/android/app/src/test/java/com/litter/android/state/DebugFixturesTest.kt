package com.litter.android.state

import org.junit.Assert.*
import org.junit.Test
import uniffi.codex_mobile_client.*

/** W1 (perf-0b) pure-function coverage: Fable golden vectors V1–V5 (exact wire texts), full rejection
 * table + exact rejectionLine strings (null only for absent/valid), positional timings, both checkpoint
 * windows, arm-gated one-shot T0/T0_LONG latch + recursion guard, deterministic 300/1500 fixture with
 * the iOS six-case cycle + per-thread summaries, thread-0 burst vs thread-1 foreign routing, 512-ring. */
class DebugFixturesTest {
    private fun v(raw: String) = DebugFixtures.parseBurstInput(raw)!!
    @Test fun goldenVectorsV1ThroughV5() {
        assertEquals(listOf("Follow-up one B7.1-F1-9af3c2: reply with exactly ALPHA.", "Follow-up two B7.1-F2-9af3c2: reply with exactly BRAVO.", "Follow-up three B7.1-F3-9af3c2: reply with exactly CHARLIE."), DebugFixtures.followUpTexts(v("B7.1-PLAIN-9af3c2"))) // V1
        assertEquals(listOf("Follow-up one B12.2-F1-00ffee: reply with exactly ALPHA.", "Follow-up two B12.2-F2-00ffee: reply with exactly BRAVO-STEERED.", "Follow-up three B12.2-F3-00ffee: reply with exactly CHARLIE."), DebugFixtures.followUpTexts(v("B12.2-STEER-00ffee"))) // V2
        assertTrue(v("B901.1-STEER-0c0ffe").steer); assertFalse(v("B15.1-PLAIN-abc123").steer) // V3/V4: mode comes only from the input
        val d2a = DebugFixtures.BurstDriver(DebugFixtures.parseTimings(null), v("B12.2-STEER-00ffee"), true); val d2b = DebugFixtures.BurstDriver(DebugFixtures.parseTimings(null), v("B12.2-STEER-00ffee"), true) // V5: two fresh parses/drivers
        assertEquals(d2a.input.steer, d2b.input.steer); assertEquals(DebugFixtures.followUpTexts(d2a.input), DebugFixtures.followUpTexts(d2b.input))
    }
    @Test fun rejectionTableAndExactRejectLines() {
        listOf("B7.1-F2-9af3c2", "B7.1-9af3c2", "B7.1-plain-9af3c2", "B7.1-Steer-9af3c2", "B7.1-PLAIN-9AF3C2", "b7.1-PLAIN-9af3c2", "B07.1-PLAIN-9af3c2", "B7.0-PLAIN-9af3c2", "B7.1-PLAIN-9af3c", "B7.1-PLAIN-9af3c2d", "B7.1-PLAIN-9af3g2", "B7.1-PLAIN-STEER-9af3c2", " B7.1-PLAIN-9af3c2", "B7.1-PLAIN-9af3c2\t", "").forEach { raw ->
            assertNull(DebugFixtures.parseBurstInput(raw)); assertNotNull(DebugFixtures.rejectionLine(raw))
        }
        assertEquals("burst.driver reject reason=malformed-nonce value=\"B7.1-F2-9af3c2\"", DebugFixtures.rejectionLine("B7.1-F2-9af3c2"))
        assertEquals("burst.driver reject reason=malformed-nonce value=\"B7.1-PLAIN-STEER-9af3c2\"", DebugFixtures.rejectionLine("B7.1-PLAIN-STEER-9af3c2"))
        assertEquals("burst.driver reject reason=missing-nonce", DebugFixtures.rejectionLine(""))
        assertNull(DebugFixtures.rejectionLine(null)); assertNull(DebugFixtures.rejectionLine("B7.1-PLAIN-9af3c2"))
    }
    @Test fun parseTimingsAndCheckpointWindows() {
        assertEquals(listOf(200L, 400L, 700L), DebugFixtures.parseTimings(null)); assertEquals(listOf(10L, 2000L, 700L), DebugFixtures.parseTimings("1, 9999"))
        assertEquals(listOf(50L, 60L, 70L), DebugFixtures.parseTimings("50,60,70,80")); assertEquals(listOf(200L, 400L, 700L), DebugFixtures.parseTimings("abc"))
        assertEquals(listOf(200L, 60L, 70L), DebugFixtures.parseTimings("abc, 60, 70")); assertEquals(listOf(1 to 1_100L, 2 to 1_100L, 0 to 1_300L), DebugFixtures.burstPlan(listOf(300L, 100L, 100L), 1_000L)) // equal offsets ⇒ index order
        assertEquals(16_000L, DebugFixtures.checkpointDelayMs(listOf(200L, 400L, 700L), false))
        assertEquals(28_000L, DebugFixtures.checkpointDelayMs(listOf(200L, 400L), true))
    }
    @Test fun driverIsArmGatedOneShotOnBothAnchorsAndRecursionGuarded() {
        val d = DebugFixtures.BurstDriver(listOf(200L, 400L, 700L), v("B7.1-PLAIN-9af3c2"), true)
        assertNull(d.onStartTurnEntered(DebugFixtures.T0_PROMPT, 1_000L)); assertEquals(DebugFixtures.BurstDriver.Phase.IDLE, d.phase) // unarmed stays IDLE
        d.arm()
        assertEquals(listOf(0 to 1_200L, 1 to 1_400L, 2 to 1_700L), d.onStartTurnEntered(DebugFixtures.T0_PROMPT, 1_000L))
        assertNull(d.onStartTurnEntered(DebugFixtures.T0_LONG_PROMPT, 2_000L)); assertNull(d.onStartTurnEntered(DebugFixtures.followUpTexts(d.input)[0], 3_000L)) // one-shot; driver-fired follow-up cannot re-anchor
        val e = DebugFixtures.BurstDriver(listOf(200L), v("B12.2-STEER-00ffee"), false)
        e.arm(); assertEquals(listOf(0 to 5_200L), e.onStartTurnEntered(DebugFixtures.T0_LONG_PROMPT, 5_000L)); assertTrue(e.anchorIsLong); assertFalse(e.fixtureMode)
        val texts = DebugFixtures.followUpTexts(v("B12.2-STEER-00ffee")); assertTrue(e.isFollowUpText(texts[2])); assertFalse(e.isFollowUpText(texts[2] + " nope"))
    }
    @Test fun fixtureSnapshotIsDeterministicSixCaseCycleWithPerThreadSummaries() {
        val snap = DebugFixtures.makeSnapshot(300, 1500); assertEquals(snap, DebugFixtures.makeSnapshot(300, 1500))
        assertEquals(300, snap.threads.size); assertEquals(1500, snap.threads[0].hydratedConversationItems.size)
        val items = snap.threads[0].hydratedConversationItems
        assertTrue(items[0].content is HydratedConversationItemContent.User); assertTrue(items[1].content is HydratedConversationItemContent.Assistant)
        assertTrue(items[2].content is HydratedConversationItemContent.Reasoning); assertTrue(items[3].content is HydratedConversationItemContent.CommandExecution)
        assertTrue(items[4].content is HydratedConversationItemContent.McpToolCall); assertTrue(items[5].content is HydratedConversationItemContent.CommandExecution)
        val cmd = (items[3].content as HydratedConversationItemContent.CommandExecution).v1; assertEquals("/Projects/Workspace-3", cmd.cwd); assertEquals("fixture output 3", cmd.output); assertEquals(120L, cmd.durationMs)
        val tool = (items[4].content as HydratedConversationItemContent.McpToolCall).v1; assertEquals("fixtureTool", tool.tool); assertEquals("{}", tool.argumentsJson); assertEquals("Fixture tool summary 4.", tool.contentSummary)
        assertEquals("sleep 3", (items[5].content as HydratedConversationItemContent.CommandExecution).v1.command)
        assertEquals("fixture-thread-0", snap.threads[9].info.parentThreadId); assertEquals(1_700_000_000L - 9, snap.threads[9].info.updatedAt)
        assertEquals("Fixture thread 30", snap.sessionSummaries[30].title); assertEquals("/Projects/Workspace-1", snap.sessionSummaries[30].cwd)
        assertEquals("Fixture preview 0", snap.sessionSummaries[0].preview); assertEquals(snap.threads[0].key, DebugFixtures.fixtureThreadKey)
        assertFalse(snap.threads[0].hydratedConversationItems.any { it.id == "fixture-live-assistant-1" }); assertTrue(snap.threads[1].hydratedConversationItems.any { it.id == "fixture-live-assistant-1" })
    }
    @Test fun burstRoutesToThread0ItemWhileForeignStreamStaysOnThread1() {
        val texts = DebugFixtures.followUpTexts(v("B7.1-PLAIN-9af3c2")); val f1 = DebugFixtures.burstUpdates(0, DebugFixtures.fixtureThreadKey, texts)[0] as AppStoreUpdateRecord.ThreadMetadataChanged
        val f2 = DebugFixtures.burstUpdates(1, DebugFixtures.fixtureThreadKey, texts); assertEquals(1, f1.state.queuedFollowUps.size); assertEquals(2, (f2[0] as AppStoreUpdateRecord.ThreadMetadataChanged).state.queuedFollowUps.size)
        val delta = f2[1] as AppStoreUpdateRecord.ThreadStreamingDelta; assertEquals(DebugFixtures.fixtureThreadKey, delta.key)
        val t0 = DebugFixtures.makeSnapshot(2, 2).threads[0].hydratedConversationItems.map { it.id }; val t1 = DebugFixtures.makeSnapshot(2, 2).threads[1].hydratedConversationItems.map { it.id }
        assertTrue(t0.contains(delta.itemId)); assertFalse(t0.contains("fixture-live-assistant-1")); assertTrue(t1.contains("fixture-live-assistant-1"))
        assertTrue((DebugFixtures.burstDrainUpdate(DebugFixtures.fixtureThreadKey) as AppStoreUpdateRecord.ThreadMetadataChanged).state.queuedFollowUps.isEmpty())
    }
    @Test fun ledgerRingCapsAt512AndFlushClearsOnlyTheEmittedBatch() {
        DebugFixtures.flushLedger("drain") { }; repeat(600) { DebugFixtures.appendLedger("line$it") }
        val out = mutableListOf<String>(); DebugFixtures.flushLedger("test") { out += it }
        assertEquals(513, out.size); assertEquals("burst.ledger flush reason=test entries=512 dropped=88", out[0]); assertEquals("line88", out[1]); assertEquals("line599", out.last()) // A-1 chronology: oldest surviving → newest
        val again = mutableListOf<String>(); DebugFixtures.flushLedger("test2") { again += it }; assertTrue(again.isEmpty())
        DebugFixtures.appendLedger("kept"); DebugFixtures.flushLedger("boom") { throw java.lang.IllegalStateException() }
        val kept = mutableListOf<String>(); DebugFixtures.flushLedger("on-stop") { kept += it }; assertEquals(listOf("burst.ledger flush reason=on-stop entries=1 dropped=0", "kept"), kept)
    }
}
