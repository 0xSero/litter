package com.litter.android.ui.common

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AppAgentCapabilities
import uniffi.codex_mobile_client.AppAgentMetadata
import uniffi.codex_mobile_client.ModelInfo
import uniffi.codex_mobile_client.ReasoningEffort

class ModelSelectorCompatibilityTest {
    @After
    fun resetMetadataProvider() {
        AgentRuntimeMetadataProvider.lookup = null
        AgentRuntimeMetadataProvider.all = null
    }

    @Test
    fun `mode filtering consumes runtime visible modes`() {
        AgentRuntimeMetadataProvider.lookup = { runtime ->
            if (runtime == "amp") ampMetadata() else null
        }

        assertTrue(model("low").isVisibleModelOption())
        assertTrue(model("amp/medium").isVisibleModelOption())
        assertTrue(model("high").isVisibleModelOption())
        assertTrue(model("ultra").isVisibleModelOption())
        assertFalse(model("smart").isVisibleModelOption())
        assertEquals("medium", model("amp/medium").modelPickerDisplayName())
    }

    @Test
    fun `reasoning effort lock is capability driven`() {
        AgentRuntimeMetadataProvider.lookup = { runtime ->
            AppAgentMetadata(
                name = runtime,
                displayName = runtime,
                presentation = null,
                capabilities = capabilities(
                    visibleModes = null,
                    locksReasoningEffortAfterActivity = runtime == "custom-agent",
                ),
            )
        }

        assertTrue("custom-agent".locksReasoningEffortAfterActivity)
        assertFalse("amp".locksReasoningEffortAfterActivity)
    }

    private fun ampMetadata() = AppAgentMetadata(
        name = "amp",
        displayName = "Amp",
        presentation = null,
        capabilities = capabilities(
            visibleModes = listOf("low", "medium", "high", "ultra"),
            locksReasoningEffortAfterActivity = false,
        ),
    )

    private fun capabilities(
        visibleModes: List<String>?,
        locksReasoningEffortAfterActivity: Boolean,
    ) = AppAgentCapabilities(
        locksReasoningEffortAfterActivity = locksReasoningEffortAfterActivity,
        visibleModes = visibleModes,
        supportsSshBridge = false,
        usesDirectCodexPort = false,
        supportsThreadPermissionOverrides = false,
        reportsEffectiveThreadPermissions = false,
    )

    private fun model(id: String) = ModelInfo(
        id = id,
        model = id,
        displayName = id,
        description = "",
        hidden = false,
        supportedReasoningEfforts = emptyList(),
        defaultReasoningEffort = ReasoningEffort.NONE,
        inputModalities = emptyList(),
        isDefault = id == "medium",
        agentRuntimeKind = "amp",
    )
}
