package com.litter.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.lifecycleScope
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.litter.android.state.AppLifecycleController
import com.litter.android.state.AppModel
import com.litter.android.state.OpenAIApiKeyStore
import com.litter.android.state.PetOverlayController
import com.litter.android.ui.AnimatedSplashScreen
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.ui.LitterApp
import com.litter.android.ui.LitterAppTheme
import com.litter.android.ui.WallpaperManager
import com.litter.android.util.LLog
import com.sigkitten.litter.android.BuildConfig
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.ThreadKey

class MainActivity : ComponentActivity() {
    companion object {
        const val EXTRA_NOTIFICATION_SERVER_ID = "litter.notification.serverId"
        const val EXTRA_NOTIFICATION_THREAD_ID = "litter.notification.threadId"
        const val EXTRA_OPEN_PET_SETTINGS = "litter.openPetSettings"
        const val NOTIFICATION_PERMISSION_REQUESTED_KEY = "notification_permission_requested"
    }

    private var appModel: AppModel? = null
    private val lifecycleController = AppLifecycleController()
    private var openPetSettingsRequest by mutableStateOf(0)
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            LLog.i(
                "MainActivity",
                if (granted) "Notification permission granted" else "Notification permission not granted",
            )
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must be called before super.onCreate to hand off the system splash
        // (Theme.App.Starting) to the Compose AnimatedSplashScreen without a
        // theme-background flash between them.
        installSplashScreen()
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        OpenAIApiKeyStore(applicationContext).applyToEnvironment()
        ExperimentalFeatures.initialize(applicationContext)
        PetOverlayController.initialize(applicationContext)

        try {
            appModel = AppModel.init(this)
            WallpaperManager.initialize(this)
            if (BuildConfig.DEBUG && appModel?.debugPerfBootstrap(intent) == true) {
                // W1 fixture/burst mode: the deterministic DEBUG fixture owns the
                // snapshot; the production Rust/store subscription is skipped.
            } else {
            appModel?.start()
            }
        } catch (e: Exception) {
            LLog.e("MainActivity", "AppModel.start() failed", e)
        }
        loadPushToken()

        var showSplash by mutableStateOf(true)
        var contentReady by mutableStateOf(false)
        var minTimeElapsed by mutableStateOf(false)

        setContent {
            LitterAppTheme {
                Box(Modifier.fillMaxSize()) {
                    val model = appModel
                    if (model != null) {
                        LitterApp(
                            appModel = model,
                            openPetSettingsRequest = openPetSettingsRequest,
                        )
                    } else {
                        Text(
                            text = "Litter couldn't finish starting.",
                            modifier = Modifier.padding(horizontal = 24.dp),
                        )
                    }

                    // Signal content ready when LitterApp composes
                    LaunchedEffect(model) {
                        if (model != null) {
                            contentReady = true
                        }
                    }

                    // Minimum display time
                    LaunchedEffect(Unit) {
                        delay(800)
                        minTimeElapsed = true
                    }

                    // Dismiss when both ready and min time elapsed (or hard max 3s)
                    LaunchedEffect(contentReady, minTimeElapsed) {
                        if (contentReady && minTimeElapsed) showSplash = false
                    }
                    LaunchedEffect(Unit) {
                        delay(3000)
                        showSplash = false
                    }

                    AnimatedVisibility(
                        visible = showSplash,
                        exit = fadeOut(),
                    ) {
                        AnimatedSplashScreen()
                    }

                    // A-10 beacon: 20 ms poll is disclosed Debug-venue measurement overhead.
                    if (BuildConfig.DEBUG && model != null) DebugBurstBeaconOverlay(model)
                }
            }
        }

        handleNotificationIntent(intent)
        consumeOverlayNavigationIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        val model = appModel ?: return
        lifecycleScope.launch {
            lifecycleController.onResume(this@MainActivity, model)
            PetOverlayController.syncOverlayService(this@MainActivity)
        }
    }

    override fun onPause() {
        super.onPause()
        val model = appModel ?: return
        lifecycleController.onPause(this, model)
    }

    override fun onStop() {
        super.onStop()
        // W1 LEDGER_FLUSH_LAW backstop: DEBUG lifecycle flush persists the post-settle tail.
        if (BuildConfig.DEBUG) appModel?.debugFlushPerfLedger("on-stop")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
        consumeOverlayNavigationIntent(intent)
    }

    override fun onDestroy() {
        // Best-effort graceful shutdown of the iroh endpoint before the
        // Activity is fully destroyed. `runBlocking` keeps the close
        // handshake bounded so we don't ANR if the network stack is
        // unresponsive; `withTimeoutOrNull` caps it.
        appModel?.let { model ->
            kotlinx.coroutines.runBlocking {
                kotlinx.coroutines.withTimeoutOrNull(2_500) {
                    model.client.shutdownAlleycatEndpoint()
                }
            }
        }
        appModel?.stop()
        super.onDestroy()
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val threadKey = consumeNotificationThreadKey(intent) ?: return
        val model = appModel ?: return
        lifecycleScope.launch {
            model.activateThread(threadKey)

            val resolvedKey = model.ensureThreadLoaded(threadKey) ?: threadKey
            model.activateThread(resolvedKey)
            model.refreshThreadSnapshot(resolvedKey)
        }
    }

    private fun consumeNotificationThreadKey(intent: Intent?): ThreadKey? {
        intent ?: return null
        val serverId = intent.getStringExtra(EXTRA_NOTIFICATION_SERVER_ID)?.trim().orEmpty()
        val threadId = intent.getStringExtra(EXTRA_NOTIFICATION_THREAD_ID)?.trim().orEmpty()
        if (serverId.isEmpty() || threadId.isEmpty()) {
            return null
        }

        intent.removeExtra(EXTRA_NOTIFICATION_SERVER_ID)
        intent.removeExtra(EXTRA_NOTIFICATION_THREAD_ID)
        return ThreadKey(serverId = serverId, threadId = threadId)
    }

    private fun consumeOverlayNavigationIntent(intent: Intent?) {
        intent ?: return
        if (intent.getBooleanExtra(EXTRA_OPEN_PET_SETTINGS, false)) {
            openPetSettingsRequest += 1
            intent.removeExtra(EXTRA_OPEN_PET_SETTINGS)
        }
    }

    private fun loadPushToken() {
        val cachedToken = getSharedPreferences("litter_push", MODE_PRIVATE)
            .getString("fcm_token", null)
            ?.takeIf { it.isNotBlank() }
        if (cachedToken != null) {
            lifecycleController.setDevicePushToken(cachedToken)
        }
        val messaging = try {
            if (FirebaseApp.getApps(applicationContext).isEmpty()) {
                FirebaseApp.initializeApp(applicationContext)
            }
            FirebaseMessaging.getInstance()
        } catch (e: IllegalStateException) {
            LLog.i("MainActivity", "Firebase is not configured; skipping FCM token fetch: ${e.message}")
            return
        }
        requestNotificationPermissionIfNeeded()

        messaging.token
            .addOnSuccessListener { token ->
                if (token.isNotBlank()) {
                    getSharedPreferences("litter_push", MODE_PRIVATE)
                        .edit()
                        .putString("fcm_token", token)
                        .apply()
                    lifecycleController.setDevicePushToken(token)
                }
            }
            .addOnFailureListener { error ->
                LLog.e("MainActivity", "Failed to fetch FCM token", error)
            }
    }

    private fun requestNotificationPermissionIfNeeded() {
        val preferences = getSharedPreferences("litter_push", MODE_PRIVATE)
        if (!shouldRequestNotificationPermission(
                sdkInt = Build.VERSION.SDK_INT,
                isGranted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED,
                wasAlreadyRequested = preferences.getBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, false),
            )
        ) {
            return
        }

        // Persist before launching so a system-dialog dismissal cannot produce a
        // permission prompt on every future app launch.
        preferences.edit().putBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, true).apply()
        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

}

// W1: single reflective bridge into the debug source set (src/debug); absent and inert in release builds.
private fun AppModel.debugPerfBootstrap(intent: Intent): Boolean = runCatching {
    Class.forName("com.litter.android.state.DebugFixtures")
        .getDeclaredMethod("bootstrap", Intent::class.java, AppModel::class.java)
        .invoke(null, intent, this) as? Boolean ?: false
}.getOrDefault(false)

// W1 A-10 burst beacon: DEBUG-only 20 ms poll; layout-only, hit-test transparent.
@Composable
private fun DebugBurstBeaconOverlay(appModel: AppModel) {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(appModel) { while (true) { delay(20); visible = appModel.debugBeaconVisible } }
    if (visible) Text(text = "◼◼", color = Color.White, fontSize = 30.sp, modifier = Modifier.padding(6.dp).background(Color.Black))
}

internal fun shouldRequestNotificationPermission(
    sdkInt: Int,
    isGranted: Boolean,
    wasAlreadyRequested: Boolean,
): Boolean =
    sdkInt >= Build.VERSION_CODES.TIRAMISU && !isGranted && !wasAlreadyRequested
