package com.litter.android

import com.litter.android.state.SavedServer
import com.litter.android.state.SavedServerStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedServerTransportTest {
    @Test
    fun forgettingAlleycatServerReturnsOnlyUnreferencedNodeToken() {
        val primary = alleycatServer(id = "primary", nodeId = " NODE-A ")
        val duplicate = alleycatServer(id = "duplicate", nodeId = "node-a")
        val independent = alleycatServer(id = "independent", nodeId = "node-b")

        assertEquals(
            emptyList<String>(),
            SavedServerStore.orphanedAlleycatNodeIds(
                removing = primary.id,
                from = listOf(primary, duplicate, independent),
            ),
        )
        assertEquals(
            listOf("node-b"),
            SavedServerStore.orphanedAlleycatNodeIds(
                removing = independent.id,
                from = listOf(primary, duplicate, independent),
            ),
        )
    }

    @Test
    fun codexAndSshDiscoveryRequiresChoiceUntilPreferenceIsSet() {
        val server =
            SavedServer(
                id = "server-1",
                name = "Studio",
                hostname = "192.168.1.203",
                port = 8390,
                codexPorts = listOf(8390),
                sshPort = 22,
                hasCodexServer = true,
            )

        assertFalse(server.prefersSshConnection)
        assertTrue(server.requiresConnectionChoice)
        assertNull(server.directCodexPort)
    }

    @Test
    fun sshPreferenceForcesSshTransport() {
        val server =
            SavedServer(
                id = "server-2",
                name = "SSH Tunnel",
                hostname = "10.0.0.5",
                port = 8390,
                codexPorts = listOf(8390),
                sshPort = 22,
                hasCodexServer = true,
                preferredConnectionMode = "ssh",
            )

        assertTrue(server.prefersSshConnection)
        assertNull(server.directCodexPort)
        assertEquals(22, server.resolvedSshPort)
    }

    @Test
    fun legacyForwardingFlagMigratesToSshPreference() {
        val server =
            SavedServer(
                id = "server-3",
                name = "Old Saved Host",
                hostname = "192.168.1.203",
                port = 8390,
                codexPorts = listOf(8390),
                sshPort = 22,
                hasCodexServer = true,
                sshPortForwardingEnabled = true,
            )

        assertTrue(server.prefersSshConnection)
        assertNull(server.directCodexPort)
        assertEquals(22, server.resolvedSshPort)
    }

    @Test
    fun codexOnlyHostUsesDirectTransport() {
        val server =
            SavedServer(
                id = "server-4",
                name = "Codex",
                hostname = "10.0.0.4",
                port = 9234,
                codexPorts = listOf(9234),
                hasCodexServer = true,
            )

        assertFalse(server.prefersSshConnection)
        assertEquals(9234, server.directCodexPort)
    }

    private fun alleycatServer(id: String, nodeId: String) =
        SavedServer(
            id = id,
            name = id,
            hostname = nodeId,
            port = 0,
            alleycatNodeId = nodeId,
        )
}
