package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AppLaunchModelSelectionTest {
    @Test
    fun updatingModelStateRetainsRuntimeWhenModelIsEmpty() {
        val state = AppLaunchStateSnapshot().updatingSelectedModel(
            model = null,
            agentRuntimeKind = "opencode",
        )

        assertEquals("opencode", state.selectedAgentRuntimeKind)
        assertEquals("", state.selectedModel)
    }

    @Test
    fun runtimeOnlySelectionPreservesExplicitRuntime() {
        val selection = appLaunchModelSelection(
            modelOverride = null,
            selectedModel = null,
            selectedAgentRuntimeKind = "opencode",
        )

        assertEquals("opencode", selection.agentRuntimeKind)
        assertNull(selection.model)
    }

    @Test
    fun selectionNormalizesModelWithoutChangingRuntime() {
        val selection = appLaunchModelSelection(
            modelOverride = "  local/model  ",
            selectedModel = null,
            selectedAgentRuntimeKind = "local-studio",
        )

        assertEquals("local-studio", selection.agentRuntimeKind)
        assertEquals("local/model", selection.model)
    }

    @Test
    fun whitespaceOnlyModelDoesNotDiscardRuntime() {
        val selection = appLaunchModelSelection(
            modelOverride = "  \n ",
            selectedModel = null,
            selectedAgentRuntimeKind = "opencode",
        )

        assertEquals("opencode", selection.agentRuntimeKind)
        assertNull(selection.model)
    }
}
