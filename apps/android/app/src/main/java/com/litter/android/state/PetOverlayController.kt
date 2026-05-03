package com.litter.android.state

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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

object PetOverlayController {
    private const val PREFS = "litter_pet_overlay"
    private const val KEY_VISIBLE = "visible"
    private const val KEY_SERVER_ID = "server_id"
    private const val KEY_PET_ID = "pet_id"
    private const val KEY_PET_NAME = "pet_name"
    private const val CACHE_DIR = "pets"

    var visible by mutableStateOf(false)
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
    private var dragDirection by mutableStateOf(PetAvatarState.RUNNING_RIGHT)
    private var initialized = false

    fun initialize(context: Context) {
        if (initialized) return
        initialized = true
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        visible = prefs.getBoolean(KEY_VISIBLE, false)
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
    }

    fun toggleVisible(context: Context) {
        setVisible(context, !visible)
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
        } catch (error: Throwable) {
            errorMessage = error.message ?: "Unable to load pet."
        } finally {
            isLoading = false
        }
    }

    fun startDrag() {
        isDragging = true
    }

    fun dragBy(dx: Float, dy: Float) {
        dragOffsetX += dx
        dragOffsetY += dy
        if (dx > 0.5f) dragDirection = PetAvatarState.RUNNING_RIGHT
        if (dx < -0.5f) dragDirection = PetAvatarState.RUNNING_LEFT
    }

    fun endDrag() {
        isDragging = false
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
