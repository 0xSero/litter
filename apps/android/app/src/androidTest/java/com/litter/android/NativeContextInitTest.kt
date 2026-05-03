package com.litter.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.litter.android.core.bridge.UniffiInit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.codex_mobile_client.AppAlleycatPairPayload
import uniffi.codex_mobile_client.ClientException
import uniffi.codex_mobile_client.ServerBridge

@RunWith(AndroidJUnit4::class)
class NativeContextInitTest {
    @Test
    fun irohSeesInitializedAndroidContext() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val result = UniffiInit.debugNativeContextProbe(context)
        assertEquals("ok", result)
    }

    @Test
    fun listAlleycatAgentsDoesNotPanicWhenAndroidContextIsInitialized() {
        kotlinx.coroutines.runBlocking {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            UniffiInit.ensure(context)

            val params = AppAlleycatPairPayload(
                v = 1u,
                nodeId = "not-a-valid-node-id",
                token = "test-token",
                relay = null,
                hostName = "test-host",
            )

            try {
                ServerBridge().use { bridge ->
                    bridge.listAlleycatAgents(params)
                }
            } catch (error: ClientException) {
                assertFalse(
                    error.message.orEmpty(),
                    error.message.orEmpty().contains("android context was not initialized"),
                )
            }
        }
    }
}
