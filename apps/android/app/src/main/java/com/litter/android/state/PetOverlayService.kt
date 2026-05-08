package com.litter.android.state

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.litter.android.MainActivity
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterAppTheme
import com.litter.android.ui.pets.PetAvatarBubble
import kotlinx.coroutines.launch
import kotlin.math.roundToInt
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.ThreadKey

class PetOverlayService : LifecycleService() {
    companion object {
        const val ACTION_SYNC = "com.litter.android.pet.ACTION_SYNC"
        const val ACTION_HIDE = "com.litter.android.pet.ACTION_HIDE"

        private const val CHANNEL_ID = "pet_overlay"
        private const val NOTIFICATION_ID = 9011
    }

    private lateinit var appModel: AppModel
    private lateinit var windowManager: WindowManager
    private lateinit var overlayOwner: OverlayViewTreeOwner

    private var overlayView: ComposeView? = null
    private var overlayLayoutParams: WindowManager.LayoutParams? = null
    private var latestSnapshot: AppSnapshotRecord? = null
    private val overlayUiModel = mutableStateOf<PetOverlayUiModel?>(null)
    private val menuVisible = mutableStateOf(false)
    private var dragStartWindowX: Float = 0f
    private var dragStartWindowY: Float = 0f

    override fun onCreate() {
        super.onCreate()
        PetOverlayController.initialize(applicationContext)
        appModel = AppModel.init(applicationContext)
        appModel.start()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        overlayOwner = OverlayViewTreeOwner()
        overlayOwner.attach()
        lifecycleScope.launch {
            appModel.snapshot.collect { snapshot ->
                latestSnapshot = snapshot
                refreshOverlay()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> {
                PetOverlayController.setVisible(this, false)
                stopSelf()
                return START_NOT_STICKY
            }
        }

        if (!PetOverlayController.shouldShowSystemOverlay(this)) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        refreshOverlay()
        return START_STICKY
    }

    override fun onDestroy() {
        hideOverlay()
        overlayOwner.dispose()
        appModel.stop()
        super.onDestroy()
    }

    private fun refreshOverlay() {
        if (!PetOverlayController.shouldShowSystemOverlay(this)) {
            hideOverlay()
            stopSelf()
            return
        }

        val uiModel = PetOverlayController.buildUiModel(latestSnapshot)
        overlayUiModel.value = uiModel
        if (uiModel == null) {
            menuVisible.value = false
            hideOverlay()
            return
        }

        if (overlayView == null) {
            showOverlay()
        } else {
            updateWindowPosition()
        }
    }

    private fun showOverlay() {
        if (overlayView != null) return

        val layoutParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = PetOverlayController.dragOffsetX.roundToInt()
            y = PetOverlayController.dragOffsetY.roundToInt()
        }

        val composeView = ComposeView(this).apply {
            setViewTreeLifecycleOwner(overlayOwner)
            setViewTreeViewModelStoreOwner(overlayOwner)
            setViewTreeSavedStateRegistryOwner(overlayOwner)
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
            setContent {
                LitterAppTheme {
                    overlayUiModel.value?.let { model ->
                        Column(
                            horizontalAlignment = Alignment.Start,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            if (menuVisible.value) {
                                PetActionMenu(
                                    onOpenLitter = {
                                        menuVisible.value = false
                                        openLitterHome()
                                    },
                                    onHidePet = {
                                        menuVisible.value = false
                                        PetOverlayController.setVisible(this@PetOverlayService, false)
                                        stopSelf()
                                    },
                                    onOpenPetSettings = {
                                        menuVisible.value = false
                                        openPetSettings()
                                    },
                                )
                            }
                            PetAvatarBubble(
                                pet = model.pet,
                                state = model.state,
                                message = model.message,
                                reducedMotion = animationsDisabled(),
                                onDragStart = {
                                    menuVisible.value = false
                                    dragStartWindowX = PetOverlayController.dragOffsetX
                                    dragStartWindowY = PetOverlayController.dragOffsetY
                                    PetOverlayController.startDrag()
                                    refreshOverlay()
                                },
                                onDragCancel = {
                                    PetOverlayController.endDrag()
                                    refreshOverlay()
                                },
                                onDragEnd = {
                                    PetOverlayController.endDrag()
                                    refreshOverlay()
                                },
                                onDrag = { dx, dy ->
                                    PetOverlayController.dragBy(this@PetOverlayService, dx, dy)
                                    updateWindowPosition()
                                    refreshOverlay()
                                },
                                onDragAbsolute = { totalDx, totalDy ->
                                    PetOverlayController.setPosition(
                                        this@PetOverlayService,
                                        dragStartWindowX + totalDx,
                                        dragStartWindowY + totalDy,
                                    )
                                    updateWindowPosition()
                                    refreshOverlay()
                                },
                                onPinchStart = {
                                    menuVisible.value = false
                                    PetOverlayController.startPinch()
                                },
                                onPinch = { factor ->
                                    PetOverlayController.pinchBy(factor)
                                },
                                onPinchEnd = {
                                    PetOverlayController.endPinch(this@PetOverlayService)
                                },
                                onClick = {
                                    if (menuVisible.value) {
                                        menuVisible.value = false
                                    } else {
                                        openActiveThreadOrHome()
                                    }
                                },
                                onLongClick = {
                                    menuVisible.value = !menuVisible.value
                                },
                            )
                        }
                    }
                }
            }
        }

        overlayLayoutParams = layoutParams
        overlayView = composeView
        windowManager.addView(composeView, layoutParams)
    }

    private fun hideOverlay() {
        overlayView?.let { view ->
            runCatching { windowManager.removeView(view) }
        }
        overlayView = null
        overlayLayoutParams = null
    }

    private fun updateWindowPosition() {
        val view = overlayView ?: return
        val params = overlayLayoutParams ?: return
        params.x = PetOverlayController.dragOffsetX.roundToInt()
        params.y = PetOverlayController.dragOffsetY.roundToInt()
        runCatching { windowManager.updateViewLayout(view, params) }
    }

    private fun buildNotification(): Notification {
        ensureChannel()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("Pet awake")
            .setContentText("Your Codex pet is floating over other apps.")
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(openAppPendingIntent())
            .addAction(
                0,
                "Hide Pet",
                PendingIntent.getService(
                    this,
                    0,
                    Intent(this, PetOverlayService::class.java).apply { action = ACTION_HIDE },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()
    }

    private fun openAppPendingIntent(): PendingIntent =
        PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun openActiveThreadOrHome() {
        val activeThread: ThreadKey? = latestSnapshot?.activeThread
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (activeThread != null) {
                putExtra(MainActivity.EXTRA_NOTIFICATION_SERVER_ID, activeThread.serverId)
                putExtra(MainActivity.EXTRA_NOTIFICATION_THREAD_ID, activeThread.threadId)
            }
        }
        startActivity(intent)
    }

    private fun openLitterHome() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        startActivity(intent)
    }

    private fun openPetSettings() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_OPEN_PET_SETTINGS, true)
        }
        startActivity(intent)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Pet Overlay",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun animationsDisabled(): Boolean {
        val scale = runCatching {
            Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE)
        }.getOrDefault(1f)
        return scale == 0f
    }

    private inner class OverlayViewTreeOwner : SavedStateRegistryOwner, ViewModelStoreOwner, LifecycleOwner {
        private val lifecycleRegistry = LifecycleRegistry(this)
        private val savedStateController = SavedStateRegistryController.create(this)
        override val viewModelStore: ViewModelStore = ViewModelStore()
        override val lifecycle: Lifecycle
            get() = lifecycleRegistry
        override val savedStateRegistry: SavedStateRegistry
            get() = savedStateController.savedStateRegistry

        fun attach() {
            lifecycleRegistry.currentState = Lifecycle.State.INITIALIZED
            savedStateController.performAttach()
            savedStateController.performRestore(null)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
        }

        fun dispose() {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
            viewModelStore.clear()
        }
    }
}

@Composable
private fun PetActionMenu(
    onOpenLitter: () -> Unit,
    onHidePet: () -> Unit,
    onOpenPetSettings: () -> Unit,
) {
    Column(
        modifier = Modifier
            .offset(x = 12.dp)
            .background(
                color = LitterTheme.surface.copy(alpha = 0.96f),
                shape = RoundedCornerShape(12.dp),
            )
            .border(
                width = 1.dp,
                color = LitterTheme.border.copy(alpha = 0.92f),
                shape = RoundedCornerShape(12.dp),
            )
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PetActionMenuItem(label = "Open Litter", onClick = onOpenLitter)
        PetActionMenuItem(label = "Hide Pet", onClick = onHidePet)
        PetActionMenuItem(label = "Pet Settings", onClick = onOpenPetSettings)
    }
}

@Composable
private fun PetActionMenuItem(
    label: String,
    onClick: () -> Unit,
) {
    androidx.compose.material3.Text(
        text = label,
        color = LitterTheme.textPrimary,
        fontFamily = LitterTheme.monoFont,
        modifier = Modifier.clickable(onClick = onClick),
    )
}
