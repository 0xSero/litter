package com.litter.android.state

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import uniffi.codex_mobile_client.ThreadKey

class ThreadRevisionLedgerTest {
    private fun key(id: String) = ThreadKey(serverId = "srv", threadId = id)

    @Test
    fun `L1 bumpThread bumps only the target thread flow`() {
        val ledger = ThreadRevisionLedger()
        ledger.bumpThread(key("a"))
        assertEquals(1L, ledger.threadRevision(key("a")).value)
        assertEquals(0L, ledger.threadRevision(key("b")).value)
        assertEquals(0L, ledger.conversationGlobalRevision.value)
    }

    @Test
    fun `L2 bumpGlobal bumps only the global flow`() {
        val ledger = ThreadRevisionLedger()
        ledger.bumpThread(key("a"))
        ledger.bumpGlobal()
        assertEquals(1L, ledger.conversationGlobalRevision.value)
        assertEquals(1L, ledger.threadRevision(key("a")).value)
        assertEquals(0L, ledger.threadRevision(key("b")).value)
    }

    @Test
    fun `L3 threadRevision returns the same flow instance across calls and bumps`() {
        val ledger = ThreadRevisionLedger()
        val flow1 = ledger.threadRevision(key("a"))
        ledger.bumpThread(key("a"))
        assertSame(flow1, ledger.threadRevision(key("a")))
        assertEquals(1L, flow1.value)
    }

    @Test
    fun `L4 concurrency N coroutines times M bumps yields exactly N times M`() = runBlocking {
        val ledger = ThreadRevisionLedger()
        val a = key("a")
        val n = 50
        val m = 100
        coroutineScope { (1..n).map { async(Dispatchers.Default) { repeat(m) { ledger.bumpThread(a) } } }.awaitAll() }
        assertEquals((n * m).toLong(), ledger.threadRevision(a).value)
    }
}
