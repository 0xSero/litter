package com.litter.android.ui.discovery

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlleycatPairingModeTest {
    @Test
    fun localStudioModeIncludesOnlyLocalStudio() {
        assertTrue(AlleycatPairingMode.LocalStudio.includesAgent("local-studio"))
        assertFalse(AlleycatPairingMode.LocalStudio.includesAgent("codex"))
        assertFalse(AlleycatPairingMode.LocalStudio.includesAgent("pi"))
    }

    @Test
    fun kittyLitterModeIncludesEveryAgent() {
        assertTrue(AlleycatPairingMode.Kittylitter.includesAgent("local-studio"))
        assertTrue(AlleycatPairingMode.Kittylitter.includesAgent("codex"))
        assertTrue(AlleycatPairingMode.Kittylitter.includesAgent("pi"))
    }
}
