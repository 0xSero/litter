package com.litter.android.state

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import uniffi.codex_mobile_client.AppPetSummary
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.AppServerTransportState
import uniffi.codex_mobile_client.ThreadSummaryStatus
import java.io.File

enum class PetAvatarState(val row: Int) {
    IDLE(0),
    RUNNING_RIGHT(1),
    RUNNING_LEFT(2),
    WAVING(3),
    JUMPING(4),
    FAILED(5),
    WAITING(6),
    RUNNING(7),
    REVIEW(8),
}

data class CachedPetPackage(
    val serverId: String,
    val id: String,
    val displayName: String,
    val spritesheetBytes: ByteArray,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CachedPetPackage) return false
        return serverId == other.serverId &&
            id == other.id &&
            displayName == other.displayName &&
            spritesheetBytes.contentEquals(other.spritesheetBytes)
    }

    override fun hashCode(): Int {
        var result = serverId.hashCode()
        result = 31 * result + id.hashCode()
        result = 31 * result + displayName.hashCode()
        result = 31 * result + spritesheetBytes.contentHashCode()
        return result
    }
}

data class PetOverlayUiModel(
    val pet: CachedPetPackage,
    val state: PetAvatarState,
    val message: String?,
)

object PetOverlayController {
    private const val PREFS = "litter_pet_overlay"
    private const val KEY_VISIBLE = "visible"
    private const val KEY_OVERLAY_ENABLED = "overlay_enabled"
    private const val KEY_SERVER_ID = "server_id"
    private const val KEY_PET_ID = "pet_id"
    private const val KEY_PET_NAME = "pet_name"
    private const val KEY_DRAG_OFFSET_X = "drag_offset_x"
    private const val KEY_DRAG_OFFSET_Y = "drag_offset_y"
    private const val KEY_PET_SCALE = "pet_scale"
    private const val CACHE_DIR = "pets"

    const val MIN_PET_SCALE = 0.25f
    const val MAX_PET_SCALE = 5.0f
    const val DEFAULT_PET_SCALE = 1.0f

    var visible by mutableStateOf(false)
        private set
    var overlayEnabled by mutableStateOf(false)
        private set
    var selectedPet by mutableStateOf<CachedPetPackage?>(null)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    var dragOffsetX by mutableFloatStateOf(24f)
        private set
    var dragOffsetY by mutableFloatStateOf(96f)
        private set
    var isDragging by mutableStateOf(false)
        private set
    var petScale by mutableFloatStateOf(DEFAULT_PET_SCALE)
        private set
    var isPinching by mutableStateOf(false)
        private set
    private var pinchInitialScale: Float = DEFAULT_PET_SCALE
    private var dragDirection by mutableStateOf(PetAvatarState.RUNNING_RIGHT)
    private var initialized = false

    fun initialize(context: Context) {
        if (initialized) return
        initialized = true
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        visible = prefs.getBoolean(KEY_VISIBLE, false)
        overlayEnabled = prefs.getBoolean(KEY_OVERLAY_ENABLED, false)
        dragOffsetX = prefs.getFloat(KEY_DRAG_OFFSET_X, 24f)
        dragOffsetY = prefs.getFloat(KEY_DRAG_OFFSET_Y, 96f)
        petScale = prefs.getFloat(KEY_PET_SCALE, DEFAULT_PET_SCALE)
            .coerceIn(MIN_PET_SCALE, MAX_PET_SCALE)
        val serverId = prefs.getString(KEY_SERVER_ID, null)
        val petId = prefs.getString(KEY_PET_ID, null)
        val name = prefs.getString(KEY_PET_NAME, null)
        if (!serverId.isNullOrBlank() && !petId.isNullOrBlank() && !name.isNullOrBlank()) {
            val file = cacheFile(context, serverId, petId)
            if (file.exists()) {
                selectedPet = CachedPetPackage(
                    serverId = serverId,
                    id = petId,
                    displayName = name,
                    spritesheetBytes = file.readBytes(),
                )
            }
        }
    }

    fun setVisible(context: Context, next: Boolean) {
        visible = next
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_VISIBLE, next)
            .apply()
        syncOverlayService(context)
    }

    fun toggleVisible(context: Context) {
        setVisible(context, !visible)
    }

    fun setOverlayEnabled(context: Context, next: Boolean) {
        overlayEnabled = next
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_OVERLAY_ENABLED, next)
            .apply()
        syncOverlayService(context)
    }

    suspend fun selectPet(context: Context, appModel: AppModel, serverId: String, pet: AppPetSummary) {
        isLoading = true
        errorMessage = null
        try {
            val packageResult = appModel.client.loadPet(serverId, pet.id)
            val cached = CachedPetPackage(
                serverId = serverId,
                id = packageResult.summary.id,
                displayName = packageResult.summary.displayName,
                spritesheetBytes = packageResult.spritesheetBytes,
            )
            cacheFile(context, serverId, cached.id).apply {
                parentFile?.mkdirs()
                writeBytes(cached.spritesheetBytes)
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_SERVER_ID, serverId)
                .putString(KEY_PET_ID, cached.id)
                .putString(KEY_PET_NAME, cached.displayName)
                .putBoolean(KEY_VISIBLE, true)
                .apply()
            selectedPet = cached
            visible = true
            syncOverlayService(context)
        } catch (error: Throwable) {
            errorMessage = error.message ?: "Unable to load pet."
        } finally {
            isLoading = false
        }
    }

    fun startDrag() {
        isDragging = true
    }

    fun dragBy(context: Context? = null, dx: Float, dy: Float) {
        dragOffsetX += dx
        dragOffsetY += dy
        if (dx > 0.5f) dragDirection = PetAvatarState.RUNNING_RIGHT
        if (dx < -0.5f) dragDirection = PetAvatarState.RUNNING_LEFT
        if (context != null) {
            persistPosition(context)
        }
    }

    fun setPosition(context: Context? = null, x: Float, y: Float) {
        val dx = x - dragOffsetX
        dragOffsetX = x
        dragOffsetY = y
        if (dx > 0.5f) dragDirection = PetAvatarState.RUNNING_RIGHT
        if (dx < -0.5f) dragDirection = PetAvatarState.RUNNING_LEFT
        if (context != null) {
            persistPosition(context)
        }
    }

    fun endDrag() {
        isDragging = false
    }

    fun startPinch() {
        pinchInitialScale = petScale
        isPinching = true
    }

    fun pinchBy(factor: Float) {
        if (!factor.isFinite() || factor <= 0f) return
        petScale = (pinchInitialScale * factor).coerceIn(MIN_PET_SCALE, MAX_PET_SCALE)
    }

    fun endPinch(context: Context) {
        isPinching = false
        persistScale(context)
    }

    fun setScale(context: Context, value: Float) {
        petScale = value.coerceIn(MIN_PET_SCALE, MAX_PET_SCALE)
        persistScale(context)
    }

    fun canDrawOverlays(context: Context): Boolean = Settings.canDrawOverlays(context)

    fun requestOverlayPermission(context: Context) {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    fun shouldShowSystemOverlay(context: Context): Boolean =
        visible && overlayEnabled && selectedPet != null && canDrawOverlays(context)

    fun shouldShowInAppOverlay(context: Context): Boolean =
        visible && selectedPet != null && !shouldShowSystemOverlay(context)

    fun buildUiModel(snapshot: AppSnapshotRecord?): PetOverlayUiModel? {
        val pet = selectedPet ?: return null
        if (!visible) return null
        return PetOverlayUiModel(
            pet = pet,
            state = avatarState(snapshot),
            message = avatarMessage(snapshot),
        )
    }

    fun syncOverlayService(context: Context) {
        val appContext = context.applicationContext
        val intent = Intent(appContext, PetOverlayService::class.java).apply {
            action = PetOverlayService.ACTION_SYNC
        }
        if (shouldShowSystemOverlay(appContext)) {
            ContextCompat.startForegroundService(appContext, intent)
        } else {
            appContext.stopService(intent)
        }
    }

    private fun persistPosition(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putFloat(KEY_DRAG_OFFSET_X, dragOffsetX)
            .putFloat(KEY_DRAG_OFFSET_Y, dragOffsetY)
            .apply()
    }

    private fun persistScale(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putFloat(KEY_PET_SCALE, petScale)
            .apply()
    }

    fun avatarState(snapshot: AppSnapshotRecord?): PetAvatarState {
        if (isLoading) return PetAvatarState.WAITING
        if (isDragging) return dragDirection
        if (snapshot == null) return PetAvatarState.IDLE
        if (snapshot.pendingApprovals.isNotEmpty() || snapshot.pendingUserInputs.isNotEmpty()) {
            return PetAvatarState.REVIEW
        }
        val activeKey = snapshot.activeThread
        val activeThread = activeKey?.let { key ->
            snapshot.threads.firstOrNull { it.key == key }
        }
        if (activeThread?.info?.status == ThreadSummaryStatus.SYSTEM_ERROR) {
            return PetAvatarState.FAILED
        }
        if (activeThread?.hasActiveTurn == true) {
            return PetAvatarState.RUNNING
        }
        if (snapshot.threads.any { it.info.status == ThreadSummaryStatus.SYSTEM_ERROR }) {
            return PetAvatarState.FAILED
        }
        val connected = snapshot.servers.any { it.transportState == AppServerTransportState.CONNECTED }
        return if (connected) PetAvatarState.IDLE else PetAvatarState.WAITING
    }

    fun avatarMessage(snapshot: AppSnapshotRecord?): String? {
        if (isLoading) return "Fetching pet..."
        if (isDragging) return null
        if (snapshot == null) return null
        if (snapshot.pendingApprovals.isNotEmpty()) return "Review needed"
        if (snapshot.pendingUserInputs.isNotEmpty()) return "Input needed"
        val activeKey = snapshot.activeThread
        val activeThread = activeKey?.let { key ->
            snapshot.threads.firstOrNull { it.key == key }
        }
        if (activeThread?.info?.status == ThreadSummaryStatus.SYSTEM_ERROR) return "Run failed"
        if (activeThread?.hasActiveTurn == true) return "Working..."
        if (snapshot.threads.any { it.info.status == ThreadSummaryStatus.SYSTEM_ERROR }) return "Thread failed"
        val connected = snapshot.servers.any { it.transportState == AppServerTransportState.CONNECTED }
        return if (connected) null else "Waiting for server"
    }

    private fun cacheFile(context: Context, serverId: String, petId: String): File {
        val safeServer = serverId.replace(Regex("[^A-Za-z0-9_.-]"), "_")
        val safePet = petId.replace(Regex("[^A-Za-z0-9_.-]"), "_")
        return File(File(context.filesDir, CACHE_DIR), "${safeServer}_${safePet}.webp")
    }
}
