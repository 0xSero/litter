package com.litter.android

import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.litter.android.state.AppModel
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.codex_mobile_client.AlleycatBridge
import uniffi.codex_mobile_client.AppAlleycatPairPayload

@RunWith(AndroidJUnit4::class)
class MainActivityLifecycleTest {
    @Test
    fun recreationKeepsProcessModelAndReturnsToMainThread() {
        var payloadFile: File? = null
        var endpointKey: ByteArray? = null
        try {
            val payloadPath = InstrumentationRegistry.getArguments().getString("alleycatPairPayloadFile")
            val payload = payloadPath?.let { path ->
                val cacheDir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
                val fixture = File(cacheDir, "lifecycle-auth/pair.json")
                // Own cleanup before parsing the supplied path, including failures.
                payloadFile = fixture
                sanitized("read private pairing fixture") {
                    val file = File(path).canonicalFile
                    assertTrue("Use the test-owned lifecycle-auth/pair.json file", fixture.canonicalFile == file)
                    val stat = Os.stat(file.path)
                    assertTrue("Pairing fixture must be a private app-owned regular file",
                        OsConstants.S_ISREG(stat.st_mode) && (stat.st_mode and 0x1ff) == 0x180 && stat.st_uid == Process.myUid())
                    assertTrue("Pairing fixture is unexpectedly large", file.length() in 1L..16_384L)
                    AlleycatBridge().use { it.parsePairPayload(file.readText()) }
                }
            }
            Log.i(TAG, if (payload == null) "Mode: endpoint identity only" else "Mode: authenticated host RPC")
            lateinit var previousActivity: MainActivity
            lateinit var processModel: AppModel
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity {
                    previousActivity = it
                    processModel = AppModel.shared
                }
                // Bind the process endpoint off the UI thread. Optional host RPCs
                // use that same endpoint, without saving a server or changing its key.
                endpointKey = sanitized("bind process endpoint") {
                    runBlocking { processModel.client.ensureAlleycatEndpoint() }
                }
                assertNotNull(endpointKey)
                assertLiveness(processModel, endpointKey!!, payload, "before recreation")

                var mainThreadCallbacks = 0
                repeat(3) { iteration ->
                    val startedAt = SystemClock.elapsedRealtime()
                    scenario.recreate()
                    scenario.onActivity { activity ->
                        assertSame(Looper.getMainLooper(), Looper.myLooper())
                        assertNotSame(previousActivity, activity)
                        assertSame(processModel, AppModel.shared)
                        previousActivity = activity
                        mainThreadCallbacks += 1
                    }
                    Log.i(TAG, "recreate[$iteration] to main callback: ${SystemClock.elapsedRealtime() - startedAt} ms")
                    assertLiveness(processModel, endpointKey!!, payload, "after recreation $iteration")
                }
                assertEquals(3, mainThreadCallbacks)
            }
            ActivityScenario.launch(MainActivity::class.java).use { relaunched ->
                relaunched.onActivity { activity ->
                    assertSame(Looper.getMainLooper(), Looper.myLooper())
                    assertNotSame(previousActivity, activity)
                    assertSame(processModel, AppModel.shared)
                }
                assertLiveness(processModel, endpointKey!!, payload, "after close and relaunch")
            }
        } finally {
            endpointKey?.fill(0)
            payloadFile?.let { file ->
                assertTrue("Failed to delete private pairing fixture", file.delete() || !file.exists())
                file.parentFile?.delete() // Only succeeds when the test directory is empty.
            }
        }
    }

    private fun assertLiveness(model: AppModel, expectedKey: ByteArray, payload: AppAlleycatPairPayload?, stage: String) {
        assertNotSame("RPC must not block the UI thread", Looper.getMainLooper(), Looper.myLooper())
        sanitized(stage) {
            runBlocking {
                val key = model.client.ensureAlleycatEndpoint()
                try {
                    // assertArrayEquals would print secret bytes on failure.
                    assertTrue("Process endpoint identity changed", key != null && expectedKey.contentEquals(key))
                } finally {
                    key?.fill(0)
                }
                if (payload != null) {
                    val startedAt = SystemClock.elapsedRealtime()
                    model.serverBridge.listAlleycatAgents(payload, waitForRegistration = false)
                    Log.i(TAG, "$stage: authenticated inventory RPC passed in ${SystemClock.elapsedRealtime() - startedAt} ms")
                }
            }
        }
    }

    private fun <T> sanitized(stage: String, block: () -> T): T = try {
        block()
    } catch (error: Exception) {
        // Do not attach an exception cause/message that might contain a payload.
        throw AssertionError("$stage failed (${error.javaClass.simpleName}); credentials omitted")
    }

    private companion object {
        const val TAG = "MainActivityLifecycleTest"
    }
}
