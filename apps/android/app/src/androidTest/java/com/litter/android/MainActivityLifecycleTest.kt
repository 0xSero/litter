package com.litter.android

import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.litter.android.state.AppModel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityLifecycleTest {
    @Test
    fun recreationKeepsProcessModelAndReturnsToMainThread() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var previousActivity: MainActivity
            lateinit var processModel: AppModel
            scenario.onActivity {
                previousActivity = it
                processModel = AppModel.shared
            }
            // Bind the real native endpoint before teardown, without pairing
            // with a host or sending a model request. Wait off the UI thread.
            runBlocking { assertNotNull(processModel.client.ensureAlleycatEndpoint()) }

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
                Log.i("MainActivityLifecycleTest", "recreate[$iteration] to main callback: ${SystemClock.elapsedRealtime() - startedAt} ms")
            }
            assertEquals(3, mainThreadCallbacks)
        }
    }
}
